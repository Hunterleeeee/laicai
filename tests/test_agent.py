"""Tests for Agent loop with a mock LLM."""

import pytest

from harness.agent.loop import Agent
from harness.agent.tools import SimpleToolRegistry
from harness.core.types import Role, TokenEvent, Turn


class MockLLM:
    """Minimal mock LLM that returns a fixed response."""

    def __init__(self, response: str = "I'm a mock assistant."):
        self.response = response
        self.model = "mock"
        self.base_url = "http://mock"

    async def complete(self, messages, *, tools=None, temperature=0.7, max_tokens=4096):
        return Turn(role=Role.ASSISTANT, content=self.response)

    async def stream(self, messages, *, tools=None, temperature=0.7, max_tokens=4096):
        for word in self.response.split():
            yield word + " "

    async def close(self):
        pass


@pytest.fixture
def mock_agent():
    llm = MockLLM()
    registry = SimpleToolRegistry()
    return Agent(llm, registry)


@pytest.mark.asyncio
async def test_agent_basic_chat(mock_agent: Agent):
    events = []
    async for event in mock_agent.chat("Hello"):
        events.append(event)

    # should have token events + a done event
    token_events = [e for e in events if isinstance(e, TokenEvent)]
    assert len(token_events) > 0
    # last token event should be done
    assert token_events[-1].done is True

    # session should have user + assistant turns
    assert len(mock_agent.session.turns) == 2
    assert mock_agent.session.turns[0].role == Role.USER
    assert mock_agent.session.turns[1].role == Role.ASSISTANT


@pytest.mark.asyncio
async def test_agent_complete_oneshot(mock_agent: Agent):
    result = await mock_agent.complete_oneshot("Hi")
    assert "mock" in result.lower() or "assistant" in result.lower()


@pytest.mark.asyncio
async def test_agent_reset(mock_agent: Agent):
    await mock_agent.complete_oneshot("First message")
    assert len(mock_agent.session.turns) == 2

    mock_agent.reset("new-session")
    assert mock_agent.session.id == "new-session"
    assert len(mock_agent.session.turns) == 0


@pytest.mark.asyncio
async def test_agent_with_tool():
    """Agent with a tool, but the mock LLM doesn't call it."""
    llm = MockLLM("Here's my answer without using tools.")
    registry = SimpleToolRegistry()

    @registry.tool(name="dummy")
    async def dummy(x: str) -> str:
        """A dummy tool."""
        return x

    agent = Agent(llm, registry)
    result = await agent.complete_oneshot("test")
    assert "answer" in result.lower() or "tools" in result.lower()
