"""DEPRECATED: This module is superseded by harness.agent.loop.Agent.

The Orchestrator class is retained for backward compatibility with existing
CLI commands. New code should use Agent + SimpleToolRegistry instead.
"""
from __future__ import annotations

import warnings
warnings.warn(
    "harness.orchestrator.engine is deprecated. Use harness.agent.loop.Agent instead.",
    DeprecationWarning,
    stacklevel=2,
)

from dataclasses import dataclass
import logging
from pathlib import Path
import re

from harness.agent import Planner
from harness.config import HarnessConfig, ModelConfig
from harness.intent import IntentRouter
from harness.memory import MemoryManager
from harness.models import LocalModelRuntime
from harness.orchestrator.artifact_manager import ArtifactManager
from harness.orchestrator.pipeline import PromptExecution, RetrievedContext
from harness.retrieval import RetrievalService
from harness.session import ExecutionStage, SessionArtifact, SessionState, SessionTurnResult
from harness.skills import SkillAuthor, SkillLoader, SkillRunRequest, SkillRunner
from harness.storage import StateStore
from harness.tools import WebFetcher
from harness.vault import VaultAdapter


@dataclass
class OrchestratorContext:
    config: HarnessConfig
    store: StateStore
    vault: VaultAdapter
    skills: SkillLoader
    web: WebFetcher
    planner: Planner
    model: LocalModelRuntime
    artifacts: ArtifactManager | None = None
    memory: MemoryManager | None = None
    retrieval: RetrievalService | None = None


class Orchestrator:
    def __init__(self, context: OrchestratorContext, router: IntentRouter | None = None) -> None:
        self.context = context
        self.router = router or IntentRouter()
        self.retrieval = context.retrieval or RetrievalService(context.vault.root, context.store)
        self._logger = logging.getLogger(self.__class__.__name__)

    def start_session(self, title: str = "Learning Session") -> SessionState:
        default_model = self._default_local_config()
        record = self.context.store.create_session(
            title=title,
            model_mode="auto",
            current_provider=default_model.provider,
            current_model=default_model.model,
        )
        return SessionState(
            id=record.id,
            title=record.title,
            status=record.status,
            current_intent=record.current_intent,
            model_mode=record.model_mode,
            current_provider=record.current_provider,
            current_model=record.current_model,
        )

    def handle_message(self, session: SessionState, message: str) -> SessionTurnResult:
        routed = self.router.route(message)
        self.context.store.record_turn(session.id, "user", message, routed.name)
        self.context.store.update_session(session.id, current_intent=routed.name)
        route_stage = self._stage("route", "ok", routed.name)

        if routed.name == "create_skill":
            result = self._create_skill(session, message)
        elif routed.name == "publish_skill":
            result = self._publish_skill(session, message)
        elif routed.name == "run_skill":
            result = self._run_skill(session, message)
        elif routed.name == "switch_model_api":
            result = self._switch_model_api(session, message)
        elif routed.name == "switch_model_local":
            result = self._switch_model_local(session)
        elif routed.name == "switch_model_auto":
            result = self._switch_model_auto(session)
        elif routed.name == "research_url":
            result = self._research_url(session, message, routed.url)
        elif routed.name == "generate_quiz":
            result = self._generate_quiz(session, message)
        elif routed.name == "grade_quiz":
            result = self._grade_quiz(session, message)
        elif routed.name == "generate_flashcards":
            result = self._generate_flashcards(session, message)
        elif routed.name == "build_study_plan":
            result = self._build_study_plan(session, message)
        elif routed.name == "daily_review":
            result = self._daily_review(session, message)
        elif routed.name == "review":
            result = self._review(session, message)
        else:
            result = self._ask(session, message)

        result.stages.insert(0, route_stage)
        self.context.store.record_turn(session.id, "assistant", result.output, result.intent)
        return result

    def _result(
        self,
        *,
        session: SessionState,
        intent: str,
        status: str,
        output: str,
        model_status: str | None = None,
        sources: list[str] | None = None,
        saved_path: str | None = None,
        browser_connection: str | None = None,
        browser_mode: str | None = None,
        browser_error: str | None = None,
        artifacts: list[SessionArtifact] | None = None,
        next_actions: list[str] | None = None,
        stages: list[ExecutionStage] | None = None,
    ) -> SessionTurnResult:
        normalized_sources = sources or []
        normalized_artifacts = artifacts or []
        actions = next_actions if next_actions is not None else self._default_next_actions(intent=intent, status=status, artifacts=normalized_artifacts)
        if self.context.artifacts is not None and normalized_artifacts:
            self.context.artifacts.persist(
                session_id=session.id,
                turn_id=None,
                artifacts=normalized_artifacts,
                output=output,
                metadata={"intent": intent, "status": status, "saved_path": saved_path or ""},
            )
        return SessionTurnResult(
            session_id=session.id,
            intent=intent,
            status=status,
            output=output,
            model_status=model_status,
            sources=normalized_sources,
            saved_path=saved_path,
            browser_connection=browser_connection,
            browser_mode=browser_mode,
            browser_error=browser_error,
            artifacts=normalized_artifacts,
            next_actions=actions,
            stages=stages or [],
        )

    def _ask(self, session: SessionState, goal: str) -> SessionTurnResult:
        retrieved = self._retrieve_context(goal)
        stages = [self._stage("retrieve", "ok" if retrieved.matches else "empty", goal)]
        prompt = (
            "You are answering with help from a local Obsidian vault.\n\n"
            f"User goal:\n{goal}\n\n"
            f"Relevant vault context:\n{retrieved.text or 'No relevant notes found.'}\n\n"
            "Write a practical answer and mention when the vault context is weak."
        )
        execution = self._execute_prompt(
            session=session,
            intent="ask",
            prompt=prompt,
            max_tokens=self.context.config.runtime.resolved_max_output_tokens(),
        )
        stages.append(self._stage("act", "ok" if execution.ok else "failed", execution.model_status))
        output = execution.output
        model_status = execution.model_status
        artifacts: list[SessionArtifact] = []
        saved_path: str | None = None
        effective_ok = execution.ok

        if not effective_ok and retrieved.matches:
            output = self._build_source_fallback_answer(goal=goal, sources=retrieved.matches)
            model_status = f"{model_status} -> source fallback"
            effective_ok = True
            stages.append(self._stage("fallback", "ok", "source_fallback"))

        should_save = any(token in goal for token in ("保存", "落库", "写入", "save")) and effective_ok and bool(output.strip())
        if should_save:
            try:
                note = self.context.vault.create_note(
                    title=f"Answer - {goal[:60]}",
                    body=output,
                    frontmatter={"tags": ["answer", "agent"], "goal": goal},
                )
                self.context.store.record_note(title=note.title, path=note.path, kind="answer")
                saved_path = str(note.path)
                artifacts.append(SessionArtifact(kind="note", title=note.title, path=str(note.path)))
                stages.append(self._stage("save", "ok", saved_path))
            except OSError:
                output += "\n\n注意：这次结果生成成功了，但写入 Obsidian 时失败了。"
                stages.append(self._stage("save", "failed", "vault_write_failed"))

        if self.context.memory is not None:
            memory_result = self.context.memory.capture_from_text(goal, source_ref=f"session:{session.id}:ask")
            if memory_result.created:
                artifacts.extend(
                    SessionArtifact(kind="memory_note", title=item.title)
                    for item in memory_result.created
                )
                stages.append(self._stage("memory", "ok", str(len(memory_result.created))))
        return self._result(
            session=session,
            intent="ask",
            status="ok" if effective_ok else "failed",
            output=output,
            model_status=model_status,
            sources=retrieved.sources,
            saved_path=saved_path,
            artifacts=artifacts,
            stages=stages,
        )

    def _research_url(self, session: SessionState, message: str, url: str | None) -> SessionTurnResult:
        if not url:
            return self._ask(session, message)
        goal = re.sub(r"https?://\S+", "", message).strip() or "总结这个网站"
        save = any(token in message for token in ("保存", "落库", "写入", "save"))
        skill = self.context.skills.get("website-research")
        runtime = self._runtime_for_intent(session, "research_url")
        runner = SkillRunner(vault=self.context.vault, web=self.context.web, model=runtime, runtime=self.context.config.runtime)
        result = runner.run(skill, SkillRunRequest(goal=goal, url=url, save=save))
        output = result.output
        artifacts: list[SessionArtifact] = []
        stages = [
            self._stage("retrieve", "ok", url),
            self._stage("browse", "ok" if not result.fetched_error else "failed", result.fetched_connection or result.fetched_mode or "browser"),
            self._stage("act", "ok" if result.ok else "failed", self._format_model_status(session, runtime)),
        ]
        if result.saved_path:
            self.context.store.record_note(
                title=goal[:80] or "website-research",
                path=Path(result.saved_path),
                kind="research",
            )
            artifacts.append(SessionArtifact(kind="note", title=goal[:80] or "website-research", path=result.saved_path))
            stages.append(self._stage("save", "ok", result.saved_path))
        if self.context.memory is not None:
            memory_result = self.context.memory.capture_project_update(goal, source_ref=f"session:{session.id}:research_url")
            if memory_result.created:
                artifacts.extend(SessionArtifact(kind="memory_note", title=item.title) for item in memory_result.created)
                stages.append(self._stage("memory", "ok", str(len(memory_result.created))))
        return self._result(
            session=session,
            intent="research_url",
            status="ok" if result.ok else "failed",
            output=output,
            model_status=self._format_model_status(session, runtime),
            sources=[result.fetched_url or url],
            saved_path=result.saved_path,
            browser_connection=result.fetched_connection,
            browser_mode=result.fetched_mode,
            browser_error=result.fetched_error,
            artifacts=artifacts,
            stages=stages,
        )

    def _create_skill(self, session: SessionState, message: str) -> SessionTurnResult:
        author = SkillAuthor()
        request = message
        for prefix in ("做一个skill", "做个skill", "创建skill", "新建skill", "create skill", "make skill", "做一个 skill", "做个 skill", "创建 skill", "新建 skill"):
            request = request.replace(prefix, "").strip(" ，,。")
        skills_root = self.context.config.skills.dirs[0]
        draft = author.create_draft(request=request or message, root_dir=skills_root)
        skill_dir = self.context.config.skills.dirs[0] / draft.name
        author.write_skill(skill_dir, draft)
        output = (
            f"已创建 skill 草案：{draft.name}\n"
            f"位置：{skill_dir}\n"
            f"说明：{draft.description}\n"
            "默认采用草案名，避免覆盖已有 skill。\n"
            "步骤：\n"
            + "\n".join(f"- {step['kind']}" for step in draft.manifest["steps"])
        )
        return self._result(
            session=session,
            intent="create_skill",
            status="ok",
            output=output,
            model_status=self._format_model_status(session),
            saved_path=str(skill_dir),
            artifacts=[SessionArtifact(kind="skill_draft", title=draft.name, path=str(skill_dir))],
            next_actions=["说“发布草案”把它转成正式 skill", "直接继续修改这个 skill 的用途或步骤"],
            stages=[
                self._stage("retrieve", "ok", "skill_request"),
                self._stage("act", "ok", "draft_skill"),
                self._stage("save", "ok", str(skill_dir)),
            ],
        )

    def _publish_skill(self, session: SessionState, message: str) -> SessionTurnResult:
        skills_root = self.context.config.skills.dirs[0]
        drafts = sorted(path for path in skills_root.iterdir() if path.is_dir() and path.name.startswith("draft-"))
        if not drafts:
            return self._result(
                session=session,
                intent="publish_skill",
                status="failed",
                output="当前没有可发布的 skill 草案。",
                model_status=self.context.model.status(),
            )

        explicit = re.search(r"(?:叫|命名为|name)\s*[:：]?\s*([A-Za-z0-9_-]{3,40})", message, flags=re.IGNORECASE)
        target_name = explicit.group(1) if explicit else None
        draft_dir = drafts[-1]
        author = SkillAuthor()
        published_dir = author.publish_draft(draft_dir=draft_dir, root_dir=skills_root, published_name=target_name)
        output = (
            f"已发布 skill：{published_dir.name}\n"
            f"来源草案：{draft_dir.name}\n"
            f"位置：{published_dir}"
        )
        return self._result(
            session=session,
            intent="publish_skill",
            status="ok",
            output=output,
            model_status=self._format_model_status(session),
            saved_path=str(published_dir),
            artifacts=[SessionArtifact(kind="skill", title=published_dir.name, path=str(published_dir))],
            next_actions=[f"直接说“用 skill {published_dir.name} ...” 来试跑", "继续补这个 skill 的输入、保存规则或步骤"],
            stages=[
                self._stage("retrieve", "ok", draft_dir.name),
                self._stage("act", "ok", "publish_skill"),
                self._stage("save", "ok", str(published_dir)),
            ],
        )

    def _run_skill(self, session: SessionState, message: str) -> SessionTurnResult:
        skill = self._resolve_skill_from_message(message)
        if skill is None:
            return self._result(
                session=session,
                intent="run_skill",
                status="failed",
                output="没有识别到要运行的 skill。你可以说：`用 skill website-research 总结这个网站 https://example.com`",
                model_status=self._format_model_status(session),
            )

        goal = message
        for prefix in ("用 skill", "运行 skill", "run skill", "use skill", "用技能", "运行技能"):
            goal = re.sub(prefix, "", goal, flags=re.IGNORECASE).strip()
        goal = goal.replace(skill.name, "", 1).strip(" ：:，,。") or f"运行 {skill.name}"
        url_match = re.search(r"https?://\S+", message)
        url = url_match.group(0) if url_match else None
        save = any(token in message for token in ("保存", "落库", "写入", "save"))

        runtime = self._runtime_for_intent(session, "run_skill")
        runner = SkillRunner(
            vault=self.context.vault,
            web=self.context.web,
            model=runtime,
            runtime=self.context.config.runtime,
        )
        result = runner.run(skill, SkillRunRequest(goal=goal, url=url, save=save))
        artifacts: list[SessionArtifact] = []
        stages = [
            self._stage("retrieve", "ok", goal),
            self._stage("act", "ok" if result.ok else "failed", self._format_model_status(session, runtime)),
        ]
        if result.fetched_url or result.fetched_error or result.fetched_connection or result.fetched_mode:
            stages.insert(
                1,
                self._stage("browse", "ok" if not result.fetched_error else "failed", result.fetched_connection or result.fetched_mode or "browser"),
            )
        if result.saved_path:
            self.context.store.record_note(
                title=skill.render_title(goal),
                path=Path(result.saved_path),
                kind="skill-output",
            )
            artifacts.append(SessionArtifact(kind="note", title=skill.render_title(goal), path=result.saved_path))
            stages.append(self._stage("save", "ok", result.saved_path))
        return self._result(
            session=session,
            intent="run_skill",
            status="ok" if result.ok else "failed",
            output=result.output,
            model_status=self._format_model_status(session, runtime),
            sources=[result.fetched_url] if result.fetched_url else [],
            saved_path=result.saved_path,
            browser_connection=result.fetched_connection,
            browser_mode=result.fetched_mode,
            browser_error=result.fetched_error,
            artifacts=artifacts,
            stages=stages,
        )

    def _switch_model_api(self, session: SessionState, message: str) -> SessionTurnResult:
        endpoint = "https://api.openai.com/v1"
        model_name = "gpt-4.1-mini"
        model_match = re.search(r"(gpt-[A-Za-z0-9.\-]+|o[134][A-Za-z0-9.\-]*)", message, flags=re.IGNORECASE)
        if model_match:
            model_name = model_match.group(1)
        endpoint_match = re.search(r"https?://\S+", message)
        if endpoint_match:
            endpoint = endpoint_match.group(0)
        self._activate_model(
            session=session,
            config=ModelConfig(
                provider="openai-compatible",
                endpoint=endpoint,
                model=model_name,
                api_key="",
                api_key_env="OPENAI_API_KEY",
            ),
            model_mode="manual",
        )
        warning = ""
        if not self.context.model.resolved_api_key():
            warning = "\n警告：当前没有读到 OPENAI_API_KEY，真正调用时很可能会失败。"
        output = (
            "已在当前会话切换到手动 API 模型。\n"
            f"Endpoint: {endpoint}\n"
            f"Model: {model_name}"
            f"{warning}"
        )
        return self._result(
            session=session,
            intent="switch_model_api",
            status="ok",
            output=output,
            model_status=self.context.model.status(),
            next_actions=["直接继续当前任务", "说“恢复自动模式”回到自动路由"],
            stages=[self._stage("act", "ok", "switch_model_api")],
        )

    def _switch_model_local(self, session: SessionState) -> SessionTurnResult:
        self._activate_model(
            session=session,
            config=self._default_local_config(),
            model_mode="manual",
        )
        output = "已在当前会话切回手动本地模型。"
        return self._result(
            session=session,
            intent="switch_model_local",
            status="ok",
            output=output,
            model_status=self._format_model_status(session),
            next_actions=["直接继续当前任务", "说“恢复自动模式”回到自动路由"],
            stages=[self._stage("act", "ok", "switch_model_local")],
        )

    def _switch_model_auto(self, session: SessionState) -> SessionTurnResult:
        session.model_mode = "auto"
        default_runtime = self._runtime_from_config(self._default_local_config())
        session.current_provider = default_runtime.config.provider
        session.current_model = default_runtime._model_name
        self.context.store.update_session(
            session.id,
            model_mode=session.model_mode,
            current_provider=session.current_provider,
            current_model=session.current_model,
        )
        output = (
            "已恢复自动模型策略。\n"
            "当前规则：普通问答优先本地；网页研究、skill 运行、复盘优先 API；API 不可用时自动回落本地。"
        )
        return self._result(
            session=session,
            intent="switch_model_auto",
            status="ok",
            output=output,
            model_status=self._format_model_status(session),
            next_actions=["直接继续提问或运行 skill", "如果结果太弱，再手动切到 API 模型"],
            stages=[self._stage("act", "ok", "switch_model_auto")],
        )

    def _review(self, session: SessionState, message: str) -> SessionTurnResult:
        plan = self.context.planner.plan(message)
        prompt = (
            "你是一个学习平台里的复盘助手。\n\n"
            f"用户请求：{message}\n\n"
            "已有复盘草案：\n"
            + "\n".join(f"- {step}" for step in plan.steps)
            + "\n\n请整理成简洁的今日复盘，包含：学了什么、卡住点、下一步建议。"
        )
        execution = self._execute_prompt(
            session=session,
            intent="review",
            prompt=prompt,
            max_tokens=min(180, self.context.config.runtime.resolved_max_output_tokens()),
            fallback_output="学习复盘草案：\n" + "\n".join(f"- {step}" for step in plan.steps),
        )
        return self._result(
            session=session,
            intent="review",
            status="ok",
            output=execution.output,
            model_status=execution.model_status,
            stages=[self._stage("act", "ok" if execution.ok else "failed", execution.model_status)],
        )

    def _daily_review(self, session: SessionState, message: str) -> SessionTurnResult:
        query = self._strip_prefixes(
            message,
            prefixes=("今日复盘草案", "daily review", "每日复盘", "今天复盘"),
            fallback="根据最近学习内容生成今日复盘草案",
        )
        retrieved = self._retrieve_context(query)
        prompt = (
            "你是学习平台里的每日复盘助手。\n\n"
            f"用户请求：{query}\n\n"
            f"最近学习线索：\n{retrieved.text or 'No relevant notes found.'}\n\n"
            "请输出今日复盘草案，包含：今天推进、卡住点、要复习的点、明天第一步。"
        )
        return self._run_learning_task(
            session=session,
            request_text=message,
            intent="daily_review",
            query=query,
            prompt=prompt,
            fallback_output=self._build_daily_review_fallback(query, retrieved.matches),
            retrieved=retrieved,
            save_title=f"Daily Review - {query[:60]}",
            save_folder="07 Reviews",
            note_kind="daily-review",
            artifact_kind="daily_review",
            tags=["daily-review", "review"],
            extra_frontmatter={"goal": query},
            max_tokens=min(220, self.context.config.runtime.resolved_max_output_tokens()),
        )

    def _generate_quiz(self, session: SessionState, message: str) -> SessionTurnResult:
        query = self._strip_prefixes(
            message,
            prefixes=("根据最近笔记出题", "出题", "做题", "测验", "quiz", "题目", "考我"),
            fallback="根据最近学习内容出题",
        )
        retrieved = self._retrieve_context(query)
        prompt = (
            "你是学习平台里的出题助手。\n\n"
            f"用户目标：{query}\n\n"
            f"参考知识：\n{retrieved.text or 'No relevant notes found.'}\n\n"
            "请生成 5 道题，包含：题目、简短答案、为什么重要。优先中文。"
        )
        return self._run_learning_task(
            session=session,
            request_text=message,
            intent="generate_quiz",
            query=query,
            prompt=prompt,
            fallback_output=self._build_quiz_fallback(query, retrieved.matches),
            retrieved=retrieved,
            save_title=f"Quiz - {query[:60]}",
            save_folder="07 Reviews",
            note_kind="quiz",
            artifact_kind="quiz",
            tags=["quiz", "review"],
            extra_frontmatter={"goal": query},
            max_tokens=min(220, self.context.config.runtime.resolved_max_output_tokens()),
            postprocess=self._append_quiz_template,
        )

    def _grade_quiz(self, session: SessionState, message: str) -> SessionTurnResult:
        query = self._strip_prefixes(
            message,
            prefixes=("批改这些答案", "判题", "批改", "评分", "grade quiz", "check answer"),
            fallback="请批改这组答案",
        )
        retrieved = self._retrieve_context(query)
        prompt = (
            "你是学习平台里的判题助手。\n\n"
            f"用户答案：\n{query}\n\n"
            f"参考知识：\n{retrieved.text or 'No relevant notes found.'}\n\n"
            "请输出：总体评价、逐题反馈、最该复习的 3 个点。"
        )
        return self._run_learning_task(
            session=session,
            request_text=message,
            intent="grade_quiz",
            query=query,
            prompt=prompt,
            fallback_output=self._build_grade_fallback(query, retrieved.matches),
            retrieved=retrieved,
            save_title="Quiz Review",
            save_folder="07 Reviews",
            note_kind="quiz-review",
            artifact_kind="quiz_review",
            tags=["quiz-review", "review"],
            extra_frontmatter={"goal": query[:120]},
            max_tokens=min(220, self.context.config.runtime.resolved_max_output_tokens()),
        )

    def _generate_flashcards(self, session: SessionState, message: str) -> SessionTurnResult:
        query = self._strip_prefixes(
            message,
            prefixes=("根据最近笔记做闪卡", "生成闪卡", "做闪卡", "闪卡", "flashcard", "卡片", "记忆卡"),
            fallback="根据最近学习内容生成闪卡",
        )
        retrieved = self._retrieve_context(query)
        prompt = (
            "你是学习平台里的闪卡助手。\n\n"
            f"用户目标：{query}\n\n"
            f"参考知识：\n{retrieved.text or 'No relevant notes found.'}\n\n"
            "请生成 6 张闪卡，每张包含：正面、背面、标签。优先中文，适合 Obsidian Markdown。"
        )
        return self._run_learning_task(
            session=session,
            request_text=message,
            intent="generate_flashcards",
            query=query,
            prompt=prompt,
            fallback_output=self._build_flashcard_fallback(query, retrieved.matches),
            retrieved=retrieved,
            save_title=f"Flashcards - {query[:60]}",
            save_folder="08 Flashcards",
            note_kind="flashcards",
            artifact_kind="flashcards",
            tags=["flashcards", "review"],
            extra_frontmatter={"goal": query},
            max_tokens=min(220, self.context.config.runtime.resolved_max_output_tokens()),
            postprocess=self._append_flashcard_format_hint,
        )

    def _build_study_plan(self, session: SessionState, message: str) -> SessionTurnResult:
        query = self._strip_prefixes(
            message,
            prefixes=("给我一个", "做一个", "学习计划", "学习路径", "怎么学", "study plan", "learning plan", "路线图"),
            fallback="为这个主题生成学习计划",
        )
        retrieved = self._retrieve_context(query)
        prompt = (
            "你是学习平台里的学习路径助手。\n\n"
            f"学习主题：{query}\n\n"
            f"已有知识：\n{retrieved.text or 'No relevant notes found.'}\n\n"
            "请给出一个 7 天学习计划，包含：目标、每天任务、产出物、复盘建议。优先中文。"
        )
        daily_review_block = self._build_daily_review_template(query)
        return self._run_learning_task(
            session=session,
            request_text=message,
            intent="build_study_plan",
            query=query,
            prompt=prompt,
            fallback_output=self._build_study_plan_fallback(query, retrieved.matches),
            retrieved=retrieved,
            save_title=f"Study Plan - {query[:60]}",
            save_folder="03 Topics",
            note_kind="study-plan",
            artifact_kind="study_plan",
            tags=["study-plan", "topic"],
            extra_frontmatter={"goal": query},
            max_tokens=min(260, self.context.config.runtime.resolved_max_output_tokens()),
            postprocess=lambda output: output + "\n\n---\n\n每日复盘草案：\n" + daily_review_block,
            extra_artifacts=self._maybe_save_daily_review_draft(message, query, daily_review_block),
        )

    def _activate_model(self, session: SessionState, config: ModelConfig, model_mode: str = "manual") -> None:
        self.context.config.model = config
        self.context.model = LocalModelRuntime(config, self.context.config.runtime)
        session.model_mode = model_mode
        session.current_provider = config.provider
        session.current_model = self.context.model._model_name
        self.context.store.update_session(
            session.id,
            model_mode=session.model_mode,
            current_provider=session.current_provider,
            current_model=session.current_model,
        )

    def _runtime_for_intent(self, session: SessionState, intent: str) -> LocalModelRuntime:
        if session.model_mode == "manual":
            runtime = self.context.model
        elif intent in {"research_url", "run_skill", "review", "daily_review", "generate_quiz", "generate_flashcards", "build_study_plan"} and self._api_available():
            runtime = self._runtime_from_config(self._default_api_config())
        else:
            runtime = self._runtime_from_config(self._default_local_config())
        session.current_provider = runtime.config.provider
        session.current_model = runtime._model_name
        self.context.store.update_session(
            session.id,
            model_mode=session.model_mode,
            current_provider=session.current_provider,
            current_model=session.current_model,
        )
        return runtime

    def _runtime_from_config(self, config: ModelConfig) -> LocalModelRuntime:
        return LocalModelRuntime(config, self.context.config.runtime)

    def _default_local_config(self) -> ModelConfig:
        return ModelConfig(
            provider="local-openai-compatible",
            endpoint="http://127.0.0.1:11434/v1",
            model="auto",
            api_key="ollama",
            api_key_env=None,
        )

    def _default_api_config(self) -> ModelConfig:
        return ModelConfig(
            provider="openai-compatible",
            endpoint="https://api.openai.com/v1",
            model="gpt-4.1-mini",
            api_key="",
            api_key_env="OPENAI_API_KEY",
        )

    def _api_available(self) -> bool:
        runtime = self._runtime_from_config(self._default_api_config())
        return bool(runtime.resolved_api_key())

    def _format_model_status(self, session: SessionState, runtime: LocalModelRuntime | None = None) -> str:
        if runtime is None and session.model_mode == "auto":
            provider = session.current_provider or self._default_local_config().provider
            model_name = session.current_model or self._runtime_from_config(self._default_local_config())._model_name
            return f"auto -> {provider} ({model_name})"
        active_runtime = runtime or self.context.model
        mode_label = "manual" if session.model_mode == "manual" else "auto"
        return f"{mode_label} -> {active_runtime.status()}"

    def _retrieve_context(self, query: str) -> RetrievedContext:
        result = self.retrieval.search(query, limit=self.context.config.runtime.resolved_vault_context_limit())
        return RetrievedContext(
            query=query,
            matches=result.hits,
            text=self._render_matches(result.hits, self.context.config.runtime.resolved_vault_context_chars()),
        )

    def _execute_prompt(
        self,
        *,
        session: SessionState,
        intent: str,
        prompt: str,
        max_tokens: int,
        fallback_output: str | None = None,
    ) -> PromptExecution:
        runtime = self._runtime_for_intent(session, intent)
        response = runtime.complete(prompt, max_tokens=max_tokens)
        raw_output = response.content.strip()
        ok = response.ok and bool(raw_output)
        output = raw_output if ok else (fallback_output or raw_output or "Local model returned an empty response.")
        model_status = self._format_model_status(session, runtime)
        if not ok and runtime.config.provider == "openai-compatible":
            fallback_model = self._runtime_from_config(self._default_local_config())
            fallback_response = fallback_model.complete(prompt, max_tokens=max_tokens)
            if fallback_response.ok and fallback_response.content.strip():
                return PromptExecution(
                    output="API 模型失败，已自动回退到本地模型。\n\n" + fallback_response.content.strip(),
                    ok=True,
                    model_status=f"{self._format_model_status(session, runtime)} -> fallback {fallback_model.status()}",
                )
            model_status = f"{self._format_model_status(session, runtime)} -> attempted fallback {fallback_model.status()}"
        return PromptExecution(output=output, ok=ok or fallback_output is not None, model_status=model_status)

    def _run_learning_task(
        self,
        *,
        session: SessionState,
        request_text: str,
        intent: str,
        query: str,
        prompt: str,
        fallback_output: str,
        retrieved: RetrievedContext,
        save_title: str,
        save_folder: str,
        note_kind: str,
        artifact_kind: str,
        tags: list[str],
        extra_frontmatter: dict[str, str],
        max_tokens: int,
        postprocess=None,
        extra_artifacts: list[SessionArtifact] | None = None,
    ) -> SessionTurnResult:
        execution = self._execute_prompt(
            session=session,
            intent=intent,
            prompt=prompt,
            max_tokens=max_tokens,
            fallback_output=fallback_output,
        )
        output = postprocess(execution.output) if postprocess else execution.output
        saved_path, artifacts, warning = self._maybe_save_learning_artifact(
            request_text=request_text,
            title=save_title,
            body=output,
            folder=save_folder,
            note_kind=note_kind,
            artifact_kind=artifact_kind,
            tags=tags,
            extra_frontmatter=extra_frontmatter,
        )
        stages = [
            self._stage("retrieve", "ok" if retrieved.matches else "empty", query),
            self._stage("act", "ok" if execution.ok else "failed", execution.model_status),
        ]
        merged_artifacts = artifacts + (extra_artifacts or [])
        if warning:
            output += "\n\n" + warning
            stages.append(self._stage("save", "failed", "vault_write_failed"))
        elif saved_path or extra_artifacts:
            stages.append(self._stage("save", "ok", saved_path or "extra_artifacts"))
        if self.context.memory is not None:
            memory_result = self.context.memory.capture_project_update(query, source_ref=f"session:{session.id}:{intent}")
            if memory_result.created:
                merged_artifacts.extend(SessionArtifact(kind="memory_note", title=item.title) for item in memory_result.created)
                stages.append(self._stage("memory", "ok", str(len(memory_result.created))))
        return self._result(
            session=session,
            intent=intent,
            status="ok",
            output=output,
            model_status=execution.model_status,
            sources=retrieved.sources,
            saved_path=saved_path,
            artifacts=merged_artifacts,
            stages=stages,
        )

    def _render_matches(self, matches, max_chars: int) -> str:
        return "\n\n".join(f"{item.path}:\n{item.preview}" for item in matches)[:max_chars]

    def _append_quiz_template(self, output: str) -> str:
        return output + "\n\n答题模板：\n1. \n2. \n3. \n4. \n5. \n\n答完后你可以直接说：`批改这些答案：...`"

    def _append_flashcard_format_hint(self, output: str) -> str:
        return output + "\n\n建议格式：\n- Front: ...\n  Back: ...\n  Tags: ..."

    def _stage(self, name: str, status: str, detail: str = "") -> ExecutionStage:
        return ExecutionStage(name=name, status=status, detail=detail)

    def _strip_prefixes(self, message: str, prefixes: tuple[str, ...], fallback: str) -> str:
        cleaned = message
        for prefix in prefixes:
            cleaned = re.sub(prefix, "", cleaned, flags=re.IGNORECASE).strip(" ：:，,。")
        cleaned = re.sub(r"(并)?(保存|落库|写入|save)\b", "", cleaned, flags=re.IGNORECASE).strip(" ：:，,。")
        cleaned = re.sub(r"^(请|帮我|给我|来财)\s*", "", cleaned).strip(" ：:，,。")
        return cleaned or fallback

    def _maybe_save_learning_artifact(
        self,
        request_text: str,
        title: str,
        body: str,
        folder: str,
        note_kind: str,
        artifact_kind: str,
        tags: list[str],
        extra_frontmatter: dict[str, str],
    ) -> tuple[str | None, list[SessionArtifact], str | None]:
        if not any(token in request_text for token in ("保存", "落库", "写入", "save")):
            return None, [], None
        try:
            note = self.context.vault.create_note(
                title=title,
                body=body,
                folder=folder,
                frontmatter={"tags": tags, **extra_frontmatter},
            )
            self.context.store.record_note(title=note.title, path=note.path, kind=note_kind)
            return str(note.path), [SessionArtifact(kind=artifact_kind, title=note.title, path=str(note.path))], None
        except OSError as exc:
            warning = f"注意：内容已经生成，但写入知识库失败了。原因：{exc}"
            return None, [], warning

    def _build_quiz_fallback(self, query: str, matches) -> str:
        lines = [
            "模型这次没有稳定返回题目，我先按已有笔记给你一个最低可用小测。",
            "",
            f"主题：{query}",
        ]
        for index, item in enumerate(matches[:3], start=1):
            lines.extend(
                [
                    "",
                    f"{index}. 题目：这份笔记主要讲了什么？",
                    f"参考：{item.path}",
                    f"提示：{item.preview[:180]}",
                ]
            )
        lines.extend(["", "建议：你可以让我基于这些题再继续生成标准答案或闪卡。"])
        return "\n".join(lines)

    def _build_flashcard_fallback(self, query: str, matches) -> str:
        lines = [
            "模型这次没有稳定返回闪卡，我先根据已有笔记给你一个最低可用版本。",
            "",
            f"主题：{query}",
        ]
        for index, item in enumerate(matches[:4], start=1):
            lines.extend(
                [
                    "",
                    f"- Front: {item.path.name} 主要讲什么？",
                    f"  Back: {item.preview[:200]}",
                    "  Tags: review, local",
                ]
            )
        lines.extend(["", "建议：如果你愿意，我下一步可以把这些闪卡整理得更像 Anki/Obsidian 格式。"])
        return "\n".join(lines)

    def _build_study_plan_fallback(self, query: str, matches) -> str:
        lines = [
            "模型这次没有稳定返回学习计划，我先给你一个最低可用的 7 天草案。",
            "",
            f"主题：{query}",
            "",
            "Day 1: 先读最相关的现有笔记，整理 5 个核心概念。",
            "Day 2: 针对最重要的概念写一份自己的解释。",
            "Day 3: 让来财基于这些笔记出题并自测。",
            "Day 4: 生成一组闪卡，开始第一轮复习。",
            "Day 5: 结合网页或新资料补充薄弱点。",
            "Day 6: 做一次主题总结，写出你还不懂的地方。",
            "Day 7: 复盘这一周，沉淀成 topic note。",
        ]
        if matches:
            lines.extend(["", "建议先从这些资料开始："])
            for item in matches[:3]:
                lines.append(f"- {item.path}")
        return "\n".join(lines)

    def _build_grade_fallback(self, query: str, matches) -> str:
        lines = [
            "模型这次没有稳定返回判题结果，我先给你一个最低可用反馈。",
            "",
            f"你的答案：{query[:300]}",
            "",
            "建议反馈：",
            "- 先检查答案是否覆盖了核心概念。",
            "- 看看有没有引用到具体例子或步骤。",
            "- 把最没把握的 1-2 个点单独拿出来再问一次。",
        ]
        if matches:
            lines.extend(["", "可对照这些资料继续修正："])
            for item in matches[:3]:
                lines.append(f"- {item.path}")
        return "\n".join(lines)

    def _build_daily_review_fallback(self, query: str, matches) -> str:
        lines = [
            "模型这次没有稳定返回今日复盘，我先给你一个最低可用草案。",
            "",
            f"主题：{query}",
            "",
            "今天推进：",
            "- 我完成了哪些阅读、总结或练习？",
            "",
            "卡住点：",
            "- 哪个概念还是说不清？",
            "",
            "要复习的点：",
            "- 哪些内容明天需要再看一遍？",
            "",
            "明天第一步：",
            "- 明天打开后最先做的一件小事是什么？",
        ]
        if matches:
            lines.extend(["", "参考资料："])
            for item in matches[:2]:
                lines.append(f"- {item.path}")
        return "\n".join(lines)

    def _build_daily_review_template(self, query: str) -> str:
        return (
            f"主题：{query}\n\n"
            "今天推进：\n- \n\n"
            "卡住点：\n- \n\n"
            "要复习的点：\n- \n\n"
            "明天第一步：\n- "
        )

    def _maybe_save_daily_review_draft(self, request_text: str, query: str, body: str) -> list[SessionArtifact]:
        if not any(token in request_text for token in ("保存", "落库", "写入", "save")):
            return []
        try:
            note = self.context.vault.create_note(
                title=f"Daily Review Draft - {query[:60]}",
                body=body,
                folder="07 Reviews",
                frontmatter={"tags": ["daily-review", "draft"], "goal": query},
            )
            self.context.store.record_note(title=note.title, path=note.path, kind="daily-review-draft")
            return [SessionArtifact(kind="daily_review", title=note.title, path=str(note.path))]
        except OSError:
            return []

    def _default_next_actions(self, intent: str, status: str, artifacts: list[SessionArtifact]) -> list[str]:
        if status != "ok":
            return ["换个说法再试一次", "如果结果涉及长任务，可以切到 API 或恢复自动模式"]
        if intent == "generate_quiz":
            return ["直接答题，然后说“批改这些答案：...”", "让来财把这组题改成闪卡"]
        if intent == "grade_quiz":
            return ["针对最弱的点继续追问", "让来财基于错题再出一轮题"]
        if intent == "generate_flashcards":
            return ["让来财把这些闪卡改成更适合 Anki 的格式", "挑一张卡继续追问"]
        if intent == "build_study_plan":
            return ["让来财把 Day 1 展开成具体任务", "直接说“今日复盘草案并保存”"]
        if intent == "daily_review":
            return ["根据复盘再出题或做闪卡", "补一句“并保存”沉淀下来"]
        if intent in {"create_skill", "publish_skill", "switch_model_api", "switch_model_local", "switch_model_auto"}:
            return []
        if artifacts:
            return ["继续追问这次结果里的某个点", "让来财把这次结果整理成 skill 或复盘"]
        return ["如果你希望沉淀下来，可以补一句“并保存”", "如果结果太弱，可以说“切到 API 模型”或“恢复自动模式”"]

    def _build_source_fallback_answer(self, goal: str, sources) -> str:
        lines = [
            "模型这次没有稳定返回结果，我先根据已检索到的笔记给你一个最低可用总结。",
            "",
            f"问题：{goal}",
            "",
            "相关片段：",
        ]
        for item in sources[:3]:
            lines.append(f"- {item.path}: {item.preview}")
        lines.append("")
        lines.append("建议：如果你想要更完整的答案，可以稍后重试，或切换到更稳定的 API 模型。")
        return "\n".join(lines)

    def _resolve_skill_from_message(self, message: str):
        lowered = message.lower()
        skills = self.context.skills.list_skills()
        for skill in sorted(skills, key=lambda item: len(item.name), reverse=True):
            if skill.name.lower() in lowered:
                return skill
        return None
