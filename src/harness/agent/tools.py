"""Tool registry: register callables as tools the LLM can invoke."""

from __future__ import annotations

import inspect
import logging
import uuid
from typing import Any, Callable, Awaitable

from harness.core.types import ToolDef, ToolParam, ToolResult

logger = logging.getLogger(__name__)

# Type alias for a tool handler
ToolHandler = Callable[..., Awaitable[str]]


class SimpleToolRegistry:
    """Lightweight tool registry — register async functions, the agent calls them."""

    def __init__(self) -> None:
        self._tools: dict[str, tuple[ToolDef, ToolHandler]] = {}

    def register(
        self,
        name: str,
        description: str,
        handler: ToolHandler,
        parameters: list[ToolParam] | None = None,
    ) -> None:
        """Register a tool by name."""
        if parameters is None:
            parameters = _infer_params(handler)
        td = ToolDef(name=name, description=description, parameters=parameters)
        self._tools[name] = (td, handler)
        logger.debug("Registered tool: %s", name)

    def tool(
        self,
        name: str | None = None,
        description: str = "",
        parameters: list[ToolParam] | None = None,
    ) -> Callable[[ToolHandler], ToolHandler]:
        """Decorator form of register."""
        def decorator(fn: ToolHandler) -> ToolHandler:
            tool_name = name or fn.__name__
            tool_desc = description or (fn.__doc__ or "").strip().split("\n")[0]
            self.register(tool_name, tool_desc, fn, parameters)
            return fn
        return decorator

    def list_tools(self) -> list[ToolDef]:
        return [td for td, _ in self._tools.values()]

    async def call(self, name: str, arguments: dict[str, Any]) -> ToolResult:
        call_id = uuid.uuid4().hex[:8]
        entry = self._tools.get(name)
        if entry is None:
            return ToolResult(
                tool_call_id=call_id,
                name=name,
                content=f"Unknown tool: {name}",
                success=False,
            )
        _, handler = entry
        try:
            result = await handler(**arguments)
            return ToolResult(
                tool_call_id=call_id,
                name=name,
                content=str(result),
                success=True,
            )
        except Exception as exc:
            logger.exception("Tool %s failed", name)
            return ToolResult(
                tool_call_id=call_id,
                name=name,
                content=f"Error: {exc}",
                success=False,
            )


def _infer_params(fn: ToolHandler) -> list[ToolParam]:
    """Infer ToolParam list from function signature."""
    params: list[ToolParam] = []
    sig = inspect.signature(fn)
    for pname, p in sig.parameters.items():
        if pname in ("self", "cls"):
            continue
        ptype = "string"
        ann = p.annotation
        if ann is int:
            ptype = "integer"
        elif ann is float:
            ptype = "number"
        elif ann is bool:
            ptype = "boolean"
        required = p.default is inspect.Parameter.empty
        params.append(ToolParam(name=pname, type=ptype, required=required))
    return params
