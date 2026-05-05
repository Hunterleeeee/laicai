"""Tests for tool registry."""

import pytest

from harness.agent.tools import SimpleToolRegistry
from harness.core.types import ToolParam


@pytest.fixture
def registry():
    return SimpleToolRegistry()


def test_register_and_list(registry: SimpleToolRegistry):
    async def dummy(query: str) -> str:
        return f"found: {query}"

    registry.register("search", "Search stuff", dummy)
    tools = registry.list_tools()
    assert len(tools) == 1
    assert tools[0].name == "search"


def test_decorator_registration(registry: SimpleToolRegistry):
    @registry.tool(name="greet", description="Say hello")
    async def greet(name: str) -> str:
        return f"Hello, {name}!"

    tools = registry.list_tools()
    assert any(t.name == "greet" for t in tools)


@pytest.mark.asyncio
async def test_call_tool(registry: SimpleToolRegistry):
    @registry.tool(name="echo")
    async def echo(text: str) -> str:
        """Echo the input."""
        return text

    result = await registry.call("echo", {"text": "hello"})
    assert result.success is True
    assert result.content == "hello"


@pytest.mark.asyncio
async def test_call_unknown_tool(registry: SimpleToolRegistry):
    result = await registry.call("nonexistent", {})
    assert result.success is False
    assert "Unknown tool" in result.content


@pytest.mark.asyncio
async def test_call_tool_error(registry: SimpleToolRegistry):
    @registry.tool(name="fail")
    async def fail() -> str:
        """Always fails."""
        raise ValueError("boom")

    result = await registry.call("fail", {})
    assert result.success is False
    assert "boom" in result.content


def test_infer_params(registry: SimpleToolRegistry):
    async def my_tool(query: str, count: int = 5, verbose: bool = False) -> str:
        return "ok"

    registry.register("my_tool", "test", my_tool)
    tool = registry.list_tools()[0]
    names = [p.name for p in tool.parameters]
    assert "query" in names
    assert "count" in names
    assert "verbose" in names
    # query is required, count and verbose are not
    query_p = next(p for p in tool.parameters if p.name == "query")
    count_p = next(p for p in tool.parameters if p.name == "count")
    assert query_p.required is True
    assert count_p.required is False
