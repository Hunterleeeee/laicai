from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class RetrievedContext:
    query: str
    matches: list[object] = field(default_factory=list)
    text: str = ""

    @property
    def sources(self) -> list[str]:
        return [str(getattr(item, "path", "")) for item in self.matches]


@dataclass
class PromptExecution:
    output: str
    ok: bool
    model_status: str
