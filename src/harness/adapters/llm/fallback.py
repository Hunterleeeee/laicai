"""FallbackLLM: tries multiple LLM backends in order, falls back on failure."""

from __future__ import annotations

import logging
from typing import Any, AsyncIterator

from harness.core.types import ToolDef, Turn

logger = logging.getLogger(__name__)


class FallbackLLM:
    """Wraps multiple LLM backends; tries each in order until one succeeds.

    Usage:
        llm = FallbackLLM([ollama_llm, cloud_llm])
        turn = await llm.complete(messages)
    """

    def __init__(self, backends: list[Any]) -> None:
        if not backends:
            raise ValueError("At least one LLM backend is required")
        self.backends = backends
        self._active_index = 0

    @property
    def model(self) -> str:
        return self.backends[self._active_index].model

    @model.setter
    def model(self, value: str) -> None:
        self.backends[self._active_index].model = value

    @property
    def base_url(self) -> str:
        return self.backends[self._active_index].base_url

    async def complete(
        self,
        messages: list[Turn],
        *,
        tools: list[ToolDef] | None = None,
        temperature: float = 0.7,
        max_tokens: int = 4096,
    ) -> Turn:
        last_error: Exception | None = None
        for i, backend in enumerate(self.backends):
            try:
                result = await backend.complete(
                    messages, tools=tools, temperature=temperature, max_tokens=max_tokens,
                )
                if i != self._active_index:
                    logger.info("Fell back from backend %d to %d (%s)", self._active_index, i, backend.model)
                    self._active_index = i
                return result
            except Exception as exc:
                logger.warning("Backend %d (%s) failed: %s", i, getattr(backend, 'model', '?'), exc)
                last_error = exc
                continue
        raise RuntimeError(f"All {len(self.backends)} LLM backends failed. Last error: {last_error}")

    async def stream(
        self,
        messages: list[Turn],
        *,
        tools: list[ToolDef] | None = None,
        temperature: float = 0.7,
        max_tokens: int = 4096,
    ) -> AsyncIterator[str]:
        last_error: Exception | None = None
        for i, backend in enumerate(self.backends):
            try:
                async for token in backend.stream(
                    messages, tools=tools, temperature=temperature, max_tokens=max_tokens,
                ):
                    yield token
                if i != self._active_index:
                    self._active_index = i
                return
            except Exception as exc:
                logger.warning("Stream backend %d failed: %s", i, exc)
                last_error = exc
                continue
        raise RuntimeError(f"All backends failed for streaming. Last error: {last_error}")

    async def close(self) -> None:
        for backend in self.backends:
            try:
                await backend.close()
            except Exception:
                pass
