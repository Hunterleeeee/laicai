from __future__ import annotations

from dataclasses import dataclass
from typing import Callable


@dataclass
class ToolProposal:
    name: str
    confidence: float  # 0.0 - 1.0
    reason: str


@dataclass
class TaskPlan:
    goal: str
    steps: list[str]
    tools: list[ToolProposal]
    reasoning: str


class Planner:
    """Dynamically analyze a goal and propose a tool chain."""

    # Keyword -> (tool_name, confidence_boost, reason_template)
    _TOOL_PATTERNS: list[tuple[tuple[str, ...], str, float, str]] = [
        (("http", "https", "网站", "网页", "url", "抓取", "fetch", "浏览"), "web_fetch", 0.9, "Goal references a URL or web content"),
        (("笔记", "obsidian", "vault", "知识库", "笔记库", "note"), "vault_context", 0.85, "Goal references local knowledge base"),
        (("skill", "技能", "workflow", "工作流", "自动化", "自动"), "skill", 0.8, "Goal references a reusable skill or workflow"),
        (("出题", "quiz", "测验", "考我", "flashcard", "闪卡", "学习计划", "study plan", "复盘", "review"), "learning_task", 0.85, "Goal is a learning/review task"),
        (("保存", "落库", "写入", "save", "write", "记录"), "save_note", 0.7, "Goal explicitly asks to persist output"),
        (("搜索", "检索", "查找", "search", "find", "query"), "vault_context", 0.75, "Goal asks to search existing knowledge"),
        (("pdf", "文档", "mineru", "ingest", "导入", "import"), "ingest", 0.8, "Goal references document ingestion"),
    ]

    def __init__(self, tool_registry: dict[str, Callable] | None = None) -> None:
        self.tool_registry = tool_registry or {}

    def plan(self, goal: str, available_tools: list[str] | None = None) -> TaskPlan:
        tools = self._propose_tools(goal, available_tools)
        steps = self._build_steps(goal, tools)
        reasoning = self._build_reasoning(goal, tools)
        return TaskPlan(goal=goal, steps=steps, tools=tools, reasoning=reasoning)

    def _propose_tools(self, goal: str, available_tools: list[str] | None = None) -> list[ToolProposal]:
        lowered = goal.lower()
        proposals: list[ToolProposal] = []
        for keywords, tool_name, base_conf, reason in self._TOOL_PATTERNS:
            if any(kw in lowered for kw in keywords):
                # If available_tools is given, require the tool or a fallback to exist
                if available_tools is not None and tool_name not in available_tools and tool_name != "learning_task":
                    continue
                proposals.append(ToolProposal(name=tool_name, confidence=base_conf, reason=reason))
        # Deduplicate by name, keeping highest confidence
        seen: dict[str, ToolProposal] = {}
        for p in proposals:
            if p.name not in seen or p.confidence > seen[p.name].confidence:
                seen[p.name] = p
        return sorted(seen.values(), key=lambda x: x.confidence, reverse=True)

    def _build_steps(self, goal: str, tools: list[ToolProposal]) -> list[str]:
        steps: list[str] = []
        steps.append("Clarify the target output and constraints.")

        tool_names = {t.name for t in tools}
        if "vault_context" in tool_names or "search" in goal.lower():
            steps.append("Retrieve the most relevant local notes, skills, or source files.")
        if "web_fetch" in tool_names:
            steps.append("Fetch external web content if URLs are present or needed.")
        if "ingest" in tool_names:
            steps.append("Import and chunk any referenced documents into the knowledge pipeline.")
        if "skill" in tool_names:
            steps.append("Load and run the most appropriate skill for the task.")
        if "learning_task" in tool_names:
            steps.append("Structure the output as a learning artifact (quiz, flashcard, or plan).")

        steps.append("Use the model to synthesize the answer or artifact.")

        if "save_note" in tool_names:
            steps.append("Persist the result into the Obsidian vault.")
        else:
            steps.append("Summarize the result and decide whether to continue, verify, or save to memory.")
        return steps

    def _build_reasoning(self, goal: str, tools: list[ToolProposal]) -> str:
        if not tools:
            return "No strong tool signals detected; defaulting to direct ask."
        lines = [f"Detected intent signals in goal: '{goal[:80]}...'"]
        for t in tools:
            lines.append(f"- {t.name} (confidence={t.confidence:.2f}): {t.reason}")
        return "\n".join(lines)

