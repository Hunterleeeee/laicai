from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class SessionState:
    id: int
    title: str
    status: str = "active"
    current_intent: str | None = None
    model_mode: str = "auto"
    current_provider: str | None = None
    current_model: str | None = None
    artifacts: list[str] = field(default_factory=list)


@dataclass
class SessionArtifact:
    kind: str
    title: str
    path: str | None = None


@dataclass
class ExecutionStage:
    name: str
    status: str
    detail: str = ""


@dataclass
class SessionTurnResult:
    session_id: int
    intent: str
    status: str
    output: str
    model_status: str | None = None
    sources: list[str] = field(default_factory=list)
    saved_path: str | None = None
    browser_connection: str | None = None
    browser_mode: str | None = None
    browser_error: str | None = None
    artifacts: list[SessionArtifact] = field(default_factory=list)
    next_actions: list[str] = field(default_factory=list)
    stages: list[ExecutionStage] = field(default_factory=list)
