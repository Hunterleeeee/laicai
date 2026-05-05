"""DEPRECATED: Intent routing is now handled by LLM tool-calling in harness.agent.loop.Agent."""
from __future__ import annotations

from dataclasses import dataclass
import re


@dataclass
class RoutedIntent:
    name: str
    confidence: float
    url: str | None = None


class IntentRouter:
    def route(self, message: str) -> RoutedIntent:
        text = message.strip()
        lowered = text.lower()
        url = self._extract_url(text)
        skill_tokens = ("做一个skill", "做个skill", "创建skill", "新建skill", "create skill", "make skill", "做一个 skill", "做个 skill", "创建 skill", "新建 skill")
        publish_tokens = ("发布 skill", "发布skill", "publish skill", "publish draft", "把草案发布", "把 draft 发布", "发布草案")
        run_skill_tokens = ("用 skill", "运行 skill", "run skill", "use skill", "用技能", "运行技能")

        if any(token in lowered for token in skill_tokens):
            return RoutedIntent(name="create_skill", confidence=0.95, url=url)
        if any(token in lowered for token in publish_tokens):
            return RoutedIntent(name="publish_skill", confidence=0.92, url=url)
        if any(token in lowered for token in run_skill_tokens):
            return RoutedIntent(name="run_skill", confidence=0.9, url=url)
        if any(token in lowered for token in ("恢复自动", "切回自动", "自动模式", "自动选择模型", "use auto", "switch auto")):
            return RoutedIntent(name="switch_model_auto", confidence=0.9, url=url)
        if ("api" in lowered and any(token in lowered for token in ("切", "switch", "use", "换", "调用"))) or "openai" in lowered:
            return RoutedIntent(name="switch_model_api", confidence=0.9, url=url)
        if any(token in lowered for token in ("切回本地", "切到本地", "用本地模型", "use local", "switch local")):
            return RoutedIntent(name="switch_model_local", confidence=0.9, url=url)
        if any(token in lowered for token in ("判题", "批改", "评分", "grade quiz", "check answer")):
            return RoutedIntent(name="grade_quiz", confidence=0.88, url=url)
        if any(token in lowered for token in ("出题", "做题", "测验", "quiz", "题目", "考我")):
            return RoutedIntent(name="generate_quiz", confidence=0.88, url=url)
        if any(token in lowered for token in ("闪卡", "flashcard", "卡片", "记忆卡")):
            return RoutedIntent(name="generate_flashcards", confidence=0.88, url=url)
        if any(token in lowered for token in ("学习计划", "学习路径", "怎么学", "study plan", "learning plan", "路线图")):
            return RoutedIntent(name="build_study_plan", confidence=0.85, url=url)
        if url:
            return RoutedIntent(name="research_url", confidence=0.85, url=url)
        if any(token in lowered for token in ("今日复盘草案", "daily review", "每日复盘", "今天复盘")):
            return RoutedIntent(name="daily_review", confidence=0.82, url=url)
        if any(token in lowered for token in ("复盘", "review", "总结今天", "今天学了什么")):
            return RoutedIntent(name="review", confidence=0.7, url=url)
        return RoutedIntent(name="ask", confidence=0.6, url=url)

    def _extract_url(self, text: str) -> str | None:
        match = re.search(r"https?://\S+", text)
        return match.group(0) if match else None
