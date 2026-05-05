from __future__ import annotations

import re

from harness.memory.models import MemoryCandidate


PREFERENCE_PATTERNS = (
    re.compile(r"(?:我喜欢|我偏好|以后都用|默认用)(.+)"),
)
DECISION_PATTERNS = (
    re.compile(r"(?:我们决定|决定|定为)(.+)"),
)
PROCEDURE_PATTERNS = (
    re.compile(r"(?:以后遇到这种情况|下次|标准做法是)(.+)"),
)
PROJECT_PATTERNS = (
    re.compile(r"(?:这个项目|当前项目|项目现在)(.+)"),
)


def extract_memory_candidates(text: str, *, source_ref: str = "") -> list[MemoryCandidate]:
    content = text.strip()
    if not content:
        return []

    candidates: list[MemoryCandidate] = []
    candidates.extend(_match_patterns(PREFERENCE_PATTERNS, content, kind="user_preference", scope="user", source_ref=source_ref))
    candidates.extend(_match_patterns(DECISION_PATTERNS, content, kind="decision", scope="project", source_ref=source_ref))
    candidates.extend(_match_patterns(PROCEDURE_PATTERNS, content, kind="procedure", scope="user", source_ref=source_ref))
    candidates.extend(_match_patterns(PROJECT_PATTERNS, content, kind="project_memory", scope="project", source_ref=source_ref))
    return candidates


def _match_patterns(
    patterns: tuple[re.Pattern[str], ...],
    text: str,
    *,
    kind: str,
    scope: str,
    source_ref: str,
) -> list[MemoryCandidate]:
    items: list[MemoryCandidate] = []
    for pattern in patterns:
        match = pattern.search(text)
        if match is None:
            continue
        detail = match.group(1).strip(" ：:，,。")
        if not detail:
            continue
        title = detail[:60]
        items.append(
            MemoryCandidate(
                kind=kind,
                scope=scope,
                title=title,
                summary=detail[:120],
                content=detail,
                confidence=0.7,
                source_ref=source_ref,
                tags=[kind, scope],
            )
        )
    return items
