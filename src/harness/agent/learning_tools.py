"""Pre-built learning tools: quiz, flashcard, study plan, review, daily review.

These are registered as agent tools so the LLM can invoke them
directly when the user asks for learning-related tasks.
Each tool generates a prompt, sends it to the LLM, and returns the result.
"""

from __future__ import annotations

from pathlib import Path

from harness.agent.tools import SimpleToolRegistry
from harness.core.types import ToolParam


def register_learning_tools(
    registry: SimpleToolRegistry,
    *,
    vault_root: Path | None = None,
) -> None:
    """Register all learning scenario tools."""

    @registry.tool(
        name="generate_quiz",
        description="Generate a quiz from vault notes on a given topic. Returns quiz questions in markdown.",
        parameters=[
            ToolParam(name="topic", description="Topic or subject to quiz on"),
            ToolParam(name="num_questions", type="integer", description="Number of questions", required=False),
            ToolParam(name="difficulty", description="easy, medium, or hard", required=False, enum=["easy", "medium", "hard"]),
        ],
    )
    async def generate_quiz(topic: str, num_questions: int = 5, difficulty: str = "medium") -> str:
        context = ""
        if vault_root:
            context = _search_vault(vault_root, topic)

        prompt = f"""Generate a {difficulty} quiz with {num_questions} questions about: {topic}

Format each question as:
## Q1: [question]
- A) [option]
- B) [option]
- C) [option]
- D) [option]
**Answer:** [letter]
"""
        if context:
            prompt += f"\n\nUse this context from notes:\n{context[:3000]}"
        return prompt

    @registry.tool(
        name="generate_flashcards",
        description="Generate flashcards from vault notes on a given topic. Returns front/back pairs.",
        parameters=[
            ToolParam(name="topic", description="Topic for flashcards"),
            ToolParam(name="count", type="integer", description="Number of cards", required=False),
        ],
    )
    async def generate_flashcards(topic: str, count: int = 10) -> str:
        context = ""
        if vault_root:
            context = _search_vault(vault_root, topic)

        prompt = f"""Generate {count} flashcards about: {topic}

Format each card as:
### Card N
**Front:** [question or term]
**Back:** [answer or definition]
"""
        if context:
            prompt += f"\n\nUse this context from notes:\n{context[:3000]}"
        return prompt

    @registry.tool(
        name="create_study_plan",
        description="Create a structured study plan for a topic with daily tasks.",
        parameters=[
            ToolParam(name="topic", description="Subject to study"),
            ToolParam(name="days", type="integer", description="Number of days for the plan", required=False),
            ToolParam(name="level", description="beginner, intermediate, or advanced", required=False, enum=["beginner", "intermediate", "advanced"]),
        ],
    )
    async def create_study_plan(topic: str, days: int = 7, level: str = "intermediate") -> str:
        context = ""
        if vault_root:
            context = _search_vault(vault_root, topic)

        prompt = f"""Create a {days}-day study plan for a {level} learner on: {topic}

Format:
## Day N: [focus area]
- [ ] Task 1
- [ ] Task 2
- Resources: [links or notes]
"""
        if context:
            prompt += f"\n\nExisting knowledge from notes:\n{context[:2000]}"
        return prompt

    @registry.tool(
        name="review_notes",
        description="Review and summarize notes on a topic, highlighting key points and gaps.",
        parameters=[
            ToolParam(name="topic", description="Topic to review"),
        ],
    )
    async def review_notes(topic: str) -> str:
        if not vault_root:
            return "No vault configured. Cannot review notes."

        context = _search_vault(vault_root, topic)
        if not context:
            return f"No notes found on: {topic}"

        return f"""Review the following notes and provide:
1. **Key Concepts** — main ideas covered
2. **Knowledge Gaps** — topics mentioned but not explained
3. **Connections** — links between concepts
4. **Study Suggestions** — what to focus on next

Notes:
{context[:4000]}"""

    @registry.tool(
        name="daily_review",
        description="Generate a daily review prompt based on recently modified vault notes.",
        parameters=[
            ToolParam(name="max_notes", type="integer", description="Max recent notes to include", required=False),
        ],
    )
    async def daily_review(max_notes: int = 5) -> str:
        if not vault_root:
            return "No vault configured."

        # find recently modified notes
        md_files = sorted(
            vault_root.rglob("*.md"),
            key=lambda f: f.stat().st_mtime,
            reverse=True,
        )[:max_notes]

        if not md_files:
            return "No notes found for daily review."

        summaries = []
        for f in md_files:
            text = f.read_text(encoding="utf-8", errors="replace")[:500]
            rel = f.relative_to(vault_root)
            summaries.append(f"### {rel}\n{text}...")

        notes_text = "\n\n".join(summaries)
        return f"""Daily review — summarize what you learned from these recent notes and suggest one action item for each:

{notes_text}"""


def _search_vault(vault_root: Path, query: str) -> str:
    """Quick vault search helper using existing VaultIndex."""
    try:
        from harness.rag.index import VaultIndex
        index = VaultIndex(vault_root)
        hits = index.search(query, top_k=3)
        return "\n---\n".join(f"[{h.path}]\n{h.preview[:500]}" for h in hits)
    except Exception:
        return ""
