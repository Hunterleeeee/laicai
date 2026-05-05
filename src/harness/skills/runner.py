from __future__ import annotations

from dataclasses import dataclass, field

from harness.config import RuntimeConfig
from harness.models import LocalModelRuntime
from harness.rag import VaultIndex
from harness.skills.loader import Skill, SkillStep
from harness.tools import WebFetcher
from harness.vault import VaultAdapter


@dataclass
class SkillRunRequest:
    goal: str
    url: str | None = None
    vault_query: str | None = None
    save: bool = False


@dataclass
class SkillWebFetchResult:
    url: str = ""
    text: str = ""
    mode: str | None = None
    connection: str | None = None
    error: str | None = None


@dataclass
class SkillRunResult:
    prompt: str
    output: str
    ok: bool
    fetched_url: str | None
    fetched_mode: str | None = None
    fetched_connection: str | None = None
    fetched_error: str | None = None
    saved_path: str | None = None
    trace: list[str] = field(default_factory=list)


class SkillRunner:
    def __init__(
        self,
        vault: VaultAdapter,
        web: WebFetcher,
        model: LocalModelRuntime,
        runtime: RuntimeConfig,
    ) -> None:
        self.vault = vault
        self.web = web
        self.model = model
        self.runtime = runtime
        self.index = VaultIndex(vault.root)

    def run(self, skill: Skill, request: SkillRunRequest) -> SkillRunResult:
        vault_context = ""
        web_result = SkillWebFetchResult()
        prompt = ""
        output = ""
        saved_path: str | None = None
        ok = True
        trace: list[str] = []

        for step in skill.steps:
            if step.kind == "vault_context":
                vault_context = self._build_vault_context(skill=skill, request=request, step=step)
                trace.append(f"vault_context:{'hit' if vault_context and vault_context != 'No relevant vault notes found.' else 'empty'}")
                continue

            if step.kind == "web_fetch":
                web_result = self._fetch_web_content(request=request, step=step)
                if web_result.error:
                    trace.append(f"web_fetch:error:{web_result.connection or 'browser'}")
                else:
                    target = web_result.url or "skipped"
                    mode = web_result.connection or web_result.mode or "unknown"
                    trace.append(f"web_fetch:{mode}:{target}")
                continue

            if step.kind == "prompt":
                prompt = skill.render(
                    goal=request.goal,
                    extra_context=vault_context,
                    fetched_url=web_result.url,
                    fetched_text=web_result.text,
                )
                model_response = self.model.complete(
                    prompt,
                    max_tokens=step.max_tokens or self.runtime.resolved_max_output_tokens(),
                )
                output = model_response.content or "Local model returned an empty response."
                ok = model_response.ok
                if not ok:
                    output = self._build_skill_fallback_output(
                        skill=skill,
                        request=request,
                        fetched_url=web_result.url,
                        fetched_text=web_result.text,
                        vault_context=vault_context,
                    )
                    ok = True
                    trace.append("prompt:fallback")
                trace.append(f"prompt:{'ok' if ok else 'failed'}")
                continue

            if step.kind == "save_note":
                saved_path = self._save_note(skill=skill, request=request, output=output, fetched_url=web_result.url, ok=ok, step=step)
                trace.append(f"save_note:{saved_path or 'skipped'}")
                continue

            trace.append(f"{step.kind}:unsupported")

        if not prompt:
            prompt = skill.render(
                goal=request.goal,
                extra_context=vault_context,
                fetched_url=web_result.url,
                fetched_text=web_result.text,
            )
        if not output:
            output = "Skill completed without producing output."

        return SkillRunResult(
            prompt=prompt,
            output=output,
            ok=ok,
            fetched_url=web_result.url or None,
            fetched_mode=web_result.mode,
            fetched_connection=web_result.connection,
            fetched_error=web_result.error,
            saved_path=saved_path,
            trace=trace,
        )

    def _build_skill_fallback_output(
        self,
        skill: Skill,
        request: SkillRunRequest,
        fetched_url: str,
        fetched_text: str,
        vault_context: str,
    ) -> str:
        lines = [
            f"`{skill.name}` 这次没有拿到稳定模型输出，我先给你一个最低可用结果。",
            "",
            f"目标：{request.goal}",
        ]
        if fetched_url:
            lines.extend(["", f"网页来源：{fetched_url}"])
        if fetched_text:
            lines.extend(["", "网页片段：", fetched_text[:400]])
        if vault_context and vault_context != "No relevant vault notes found.":
            lines.extend(["", "知识库片段：", vault_context[:400]])
        lines.extend(["", "建议：稍后重试，或切换到更稳定的 API 模型继续运行这个 skill。"])
        return "\n".join(lines)

    def _build_vault_context(self, skill: Skill, request: SkillRunRequest, step: SkillStep) -> str:
        if not skill.vault_context.enabled and step.kind == "vault_context":
            return ""

        query_from = step.query_from or skill.vault_context.query_from
        if query_from == "manual":
            query = (request.vault_query or "").strip()
        else:
            query = (request.vault_query or request.goal).strip()

        if not query:
            return ""

        requested_limit = step.limit or skill.vault_context.limit
        limit = min(requested_limit, self.runtime.resolved_vault_context_limit())
        matches = self.index.search(query=query, limit=limit)
        if not matches:
            return "No relevant vault notes found."

        chunks: list[str] = []
        for item in matches:
            chunks.append(f"{item.path}:\n{item.preview}")
        max_chars = step.chars or self.runtime.resolved_vault_context_chars()
        return "\n\n".join(chunks)[:max_chars]

    def _fetch_web_content(self, request: SkillRunRequest, step: SkillStep) -> SkillWebFetchResult:
        if step.url_from == "manual":
            target_url = (request.url or "").strip()
        else:
            target_url = (request.url or "").strip()
        if not target_url:
            return SkillWebFetchResult()
        try:
            page = self.web.fetch(
                target_url,
                use_browser=True,
                text_limit=step.chars or self.runtime.resolved_web_text_chars(),
            )
        except RuntimeError as exc:
            return SkillWebFetchResult(
                url=target_url,
                text=f"Failed to fetch {target_url}: {exc}",
                mode="browser",
                connection="error",
                error=str(exc),
            )
        return SkillWebFetchResult(
            url=page.url,
            text=page.text,
            mode=page.mode,
            connection=page.connection,
        )

    def _save_note(
        self,
        skill: Skill,
        request: SkillRunRequest,
        output: str,
        fetched_url: str,
        ok: bool,
        step: SkillStep,
    ) -> str | None:
        should_save = (request.save or step.save_by_default or skill.output.save_by_default) and ok and bool(output.strip()) and output != "Local model returned an empty response."
        if not should_save:
            return None
        try:
            note = self.vault.create_note(
                title=skill.render_title(request.goal),
                body=output,
                folder=step.folder or skill.output.folder,
                frontmatter={
                    "skill": skill.name,
                    "goal": request.goal,
                    "source_url": fetched_url or "",
                    "tags": ["skill", skill.name],
                },
            )
        except OSError:
            return None
        return str(note.path)
