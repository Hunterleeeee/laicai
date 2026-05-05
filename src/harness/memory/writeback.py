from __future__ import annotations

from harness.memory.models import MemoryCandidate
from harness.vault import VaultAdapter


def write_memory_note(vault: VaultAdapter, candidate: MemoryCandidate) -> str | None:
    try:
        note = vault.create_note(
            title=f"Memory - {candidate.title}",
            body=_render_memory_body(candidate),
            folder=vault.config.memory_dir,
            frontmatter={
                "type": "memory",
                "memory_kind": candidate.kind,
                "scope": candidate.scope,
                "source_ref": candidate.source_ref,
                "tags": ["memory", candidate.kind, candidate.scope, *candidate.tags],
            },
        )
    except OSError:
        return None
    return str(note.path)


def _render_memory_body(candidate: MemoryCandidate) -> str:
    return (
        f"## Summary\n{candidate.summary}\n\n"
        f"## Detail\n{candidate.content}\n\n"
        f"## Source\n- type: {candidate.source_type}\n- ref: {candidate.source_ref or 'unknown'}\n"
    )
