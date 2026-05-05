"""Protocols (structural interfaces) for pluggable adapters.

Any class that satisfies the method signatures can be used —
no inheritance required.
"""

from __future__ import annotations

from typing import Any, AsyncIterator, Protocol, runtime_checkable

from harness.core.types import Chunk, Session, ToolDef, ToolResult, Turn


# ── LLM Backend ────────────────────────────────────────────────

@runtime_checkable
class LLMBackend(Protocol):
    """Async LLM completion with optional tool definitions."""

    async def complete(
        self,
        messages: list[Turn],
        *,
        tools: list[ToolDef] | None = None,
        temperature: float = 0.7,
        max_tokens: int = 4096,
    ) -> Turn:
        """Single-shot completion. Returns the assistant turn."""
        ...

    async def stream(
        self,
        messages: list[Turn],
        *,
        tools: list[ToolDef] | None = None,
        temperature: float = 0.7,
        max_tokens: int = 4096,
    ) -> AsyncIterator[str]:
        """Yield text tokens as they arrive."""
        ...


# ── Retriever ──────────────────────────────────────────────────

@runtime_checkable
class Retriever(Protocol):
    """Searches a knowledge base and returns scored chunks."""

    async def search(self, query: str, top_k: int = 5) -> list[Chunk]:
        ...


# ── Storage ────────────────────────────────────────────────────

@runtime_checkable
class Storage(Protocol):
    """Persists sessions and turns."""

    async def save_session(self, session: Session) -> None:
        ...

    async def load_session(self, session_id: str) -> Session | None:
        ...

    async def list_sessions(self, limit: int = 20) -> list[Session]:
        ...


# ── Tool Registry ──────────────────────────────────────────────

@runtime_checkable
class ToolRegistry(Protocol):
    """Discovers and invokes tools by name."""

    def list_tools(self) -> list[ToolDef]:
        ...

    async def call(self, name: str, arguments: dict[str, Any]) -> ToolResult:
        ...
