from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class MemoryCandidate:
    kind: str
    scope: str
    title: str
    summary: str
    content: str
    confidence: float = 0.5
    source_type: str = "session"
    source_ref: str = ""
    project: str = ""
    tags: list[str] = field(default_factory=list)


@dataclass
class MemoryItem:
    kind: str
    scope: str
    title: str
    summary: str
    content: str
    confidence: float
    source_type: str
    source_ref: str
    project: str
    tags: list[str] = field(default_factory=list)
    updated_at: str = ""


@dataclass
class MemoryWriteResult:
    created: list[MemoryItem] = field(default_factory=list)
    skipped: list[MemoryCandidate] = field(default_factory=list)
