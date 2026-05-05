"""Self-evolution: session-aware learning & memory persistence.

Phase 1 — session summary generation + Obsidian vault storage.
Future phases: cross-session retrieval, insight extraction, skill refinement.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from harness.config import VaultConfig
from harness.core.types import Role, Session, Turn
from harness.vault import VaultAdapter

# ── Data types ────────────────────────────────────────────────


@dataclass
class SessionSummary:
    session_id: str
    created_at: datetime
    turn_count: int
    summary: str
    note_path: Path | None = None
    saved: bool = False


# ── Formatting helpers ────────────────────────────────────────


def _format_session(session: Session, max_chars: int = 6000) -> str:
    """Render session turns into a compact text block for the LLM."""
    lines: list[str] = [
        f"Session ID: {session.id}",
        f"Started: {session.created_at.isoformat()}",
        f"Total turns: {len(session.turns)}",
        "",
    ]
    remaining = max_chars
    for i, turn in enumerate(session.turns, 1):
        role_label = {
            Role.USER: "User",
            Role.ASSISTANT: "Assistant",
            Role.SYSTEM: "System",
            Role.TOOL: f"Tool ({turn.name or 'unnamed'})",
        }.get(turn.role, turn.role.value)

        block = f"[{i}] {role_label}:\n{turn.content[:500]}\n"
        if len(block) > remaining:
            lines.append(f"... (truncated, {len(session.turns) - i + 1} turns omitted)")
            break
        lines.append(block)
        remaining -= len(block)
    return "\n".join(lines)


def _build_summary_prompt(conversation_text: str) -> str:
    return (
        "Summarise the following conversation in concise Chinese. "
        "Focus on:\n"
        "1. What the user asked for (the main goal).\n"
        "2. What was done or decided.\n"
        "3. Key outcomes, open questions, or follow-up items.\n\n"
        "Return a Markdown note body (no YAML frontmatter, no top-level heading). "
        "Use sections: ## 目标 / ## 过程 / ## 结果 / ## 待跟进.\n\n"
        f"{conversation_text}"
    )


# ── Core API ──────────────────────────────────────────────────


async def generate_session_summary(
    *,
    llm,
    session: Session,
    vault_root: Path,
    save: bool = True,
    memory_subdir: str = "06 Memory",
) -> SessionSummary:
    """Generate a structured summary of *session* and persist it to the vault.

    Args:
        llm: Any object that exposes ``await llm.complete(turns, temperature=…, max_tokens=…) -> Turn``.
        session: The completed conversation session.
        vault_root: Root path of the Obsidian vault.
        save: If True, immediately write the note into the vault.
        memory_subdir: Sub-directory inside the vault for memory notes.
    """
    conversation_text = _format_session(session)
    prompt = _build_summary_prompt(conversation_text)

    try:
        result_turn = await llm.complete(
            [
                Turn(
                    role=Role.SYSTEM,
                    content=(
                        "You are a concise session summariser for a local AI agent. "
                        "Write in Chinese. Output Markdown body only."
                    ),
                ),
                Turn(role=Role.USER, content=prompt),
            ],
            temperature=0.2,
            max_tokens=800,
        )
        summary = (result_turn.content or "").strip()
    except Exception:
        summary = f"## 目标\n会话 {session.id[:8]} 总结生成失败。\n\n## 过程\nLLM 调用异常。\n\n## 结果\n无。\n"

    date_prefix = session.created_at.strftime("%Y-%m-%d")
    title = f"会话总结 {date_prefix} {session.id[:8]}"

    frontmatter = {
        "type": "session-summary",
        "session_id": session.id,
        "created_at": session.created_at.isoformat(),
        "turn_count": len(session.turns),
        "tags": ["session-summary", "self-evolution"],
    }

    note_path: Path | None = None
    if save:
        vault = VaultAdapter(VaultConfig(path=vault_root))
        note = vault.upsert_topic_note(
            title=title,
            body=summary,
            frontmatter=frontmatter,
        )
        note_path = note.path

    return SessionSummary(
        session_id=session.id,
        created_at=session.created_at,
        turn_count=len(session.turns),
        summary=summary,
        note_path=note_path,
        saved=save,
    )
