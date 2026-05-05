"""End-to-end integration tests: user message → LLM → tool calls → response."""

import json
import pytest
from pathlib import Path

from harness.agent.loop import Agent, _estimate_tokens, _trim_messages, _summarize_dropped, _normalize_turns_for_llm
from harness.agent.tools import SimpleToolRegistry
from harness.agent.builtin_tools import register_builtins
from harness.adapters.storage import SQLiteSessionStore
from harness.core.types import Role, TokenEvent, ToolCallEvent, ThoughtEvent, Turn


# ── Mock LLM that simulates tool calling ───────────────────────

class ToolCallingMockLLM:
    """Mock LLM that calls vault_search on first turn, then gives a final answer."""

    def __init__(self):
        self.model = "mock-tool-caller"
        self.base_url = "http://mock"
        self._call_count = 0

    async def complete(self, messages, *, tools=None, temperature=0.7, max_tokens=4096):
        self._call_count += 1
        # first call: ask to search vault
        if self._call_count == 1 and tools:
            tool_calls = [{"id": "tc1", "name": "vault_search", "arguments": {"query": "python"}}]
            return Turn(
                role=Role.ASSISTANT,
                content=json.dumps(tool_calls),
                name="__tool_calls__",
            )
        # second call: give final answer with tool results in context
        return Turn(role=Role.ASSISTANT, content="Based on your notes, Python is a great language.")

    async def stream(self, messages, *, tools=None, temperature=0.7, max_tokens=4096):
        # trigger fallback to complete() by yielding nothing then raising
        raise NotImplementedError("stream not available")
        yield  # make this an async generator

    async def close(self):
        pass


# ── Tests ──────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_full_tool_call_flow(tmp_path: Path):
    """Simulate: user asks → LLM calls vault_search → tool returns → LLM answers."""
    # setup vault with a note
    note = tmp_path / "python-intro.md"
    note.write_text("# Python\nPython is a versatile programming language.\n")

    llm = ToolCallingMockLLM()
    registry = SimpleToolRegistry()
    register_builtins(registry, vault_root=tmp_path, web_enabled=False, learning_enabled=False)
    agent = Agent(llm, registry)

    events = []
    async for event in agent.chat("Tell me about Python"):
        events.append(event)

    # should have tool call events + thought events + token events
    tool_events = [e for e in events if isinstance(e, ToolCallEvent)]
    thought_events = [e for e in events if isinstance(e, ThoughtEvent)]
    token_events = [e for e in events if isinstance(e, TokenEvent)]

    assert len(tool_events) >= 1
    assert tool_events[0].name == "vault_search"
    assert len(thought_events) >= 1
    assert any("vault_search" in e.text for e in thought_events)
    assert len(token_events) >= 1

    # session should have: user, tool_call, tool_result, assistant
    assert len(agent.session.turns) >= 4
    assert agent.session.turns[0].role == Role.USER
    assert agent.session.turns[1].role == Role.ASSISTANT
    assert agent.session.turns[1].name == "__tool_calls__"
    assert json.loads(agent.session.turns[1].content)[0]["id"] == "tc1"
    assert agent.session.turns[2].role == Role.TOOL


@pytest.mark.asyncio
async def test_session_persistence(tmp_path: Path):
    """Test save/load session round-trip."""
    db_path = tmp_path / "test.db"
    store = SQLiteSessionStore(db_path)

    llm = ToolCallingMockLLM()
    registry = SimpleToolRegistry()
    agent = Agent(llm, registry)
    agent.reset("test-session-1")

    # have a conversation
    async for _ in agent.chat("Hello"):
        pass

    # save
    store.save_session(agent.session)

    # load
    loaded = store.load_session("test-session-1")
    assert loaded is not None
    assert loaded.id == "test-session-1"
    assert len(loaded.turns) == len(agent.session.turns)
    assert loaded.turns[0].content == "Hello"

    # list sessions
    sessions = store.list_sessions()
    assert len(sessions) == 1
    assert sessions[0].id == "test-session-1"
    assert sessions[0].metadata["title"] == "Hello"
    assert sessions[0].metadata["turn_count"] == len(agent.session.turns)
    assert sessions[0].metadata["preview"]

    # delete
    assert store.delete_session("test-session-1") is True
    assert store.load_session("test-session-1") is None


def test_context_window_trimming():
    """Verify _trim_messages keeps recent turns within budget."""
    system = Turn(role=Role.SYSTEM, content="You are helpful.")
    turns = [Turn(role=Role.USER, content=f"Message {i}" * 100) for i in range(20)]
    all_msgs = [system] + turns

    trimmed = _trim_messages(all_msgs, max_tokens=500)
    # should keep system + summary + some recent turns, not all 20
    assert trimmed[0].role == Role.SYSTEM
    assert len(trimmed) < len(all_msgs)
    # last turn should be the most recent
    assert trimmed[-1].content == turns[-1].content
    # should have a summary of dropped turns (second system message)
    system_msgs = [t for t in trimmed if t.role == Role.SYSTEM]
    assert len(system_msgs) == 2  # original + summary
    assert "Earlier conversation summary" in system_msgs[1].content


def test_summarize_dropped():
    dropped = [
        Turn(role=Role.USER, content="What is Python?"),
        Turn(role=Role.ASSISTANT, content="Python is a programming language."),
        Turn(role=Role.USER, content="How about JavaScript?"),
    ]
    summary = _summarize_dropped(dropped)
    assert "User discussed" in summary
    assert "Python" in summary


def test_no_summary_when_nothing_dropped():
    system = Turn(role=Role.SYSTEM, content="Hi")
    user = Turn(role=Role.USER, content="Short msg")
    trimmed = _trim_messages([system, user], max_tokens=10000)
    # no drops → no summary injection
    system_msgs = [t for t in trimmed if t.role == Role.SYSTEM]
    assert len(system_msgs) == 1


def test_token_estimation():
    assert _estimate_tokens("hello") >= 1
    assert _estimate_tokens("a" * 300) == 100
    assert _estimate_tokens("你好世界") >= 1


def test_session_store_creates_parent_directories(tmp_path: Path):
    db_path = tmp_path / "nested" / "sessions.db"
    store = SQLiteSessionStore(db_path)
    assert db_path.exists()
    assert store.db_path == str(db_path)


def test_session_store_derives_title_and_preview(tmp_path: Path):
    db_path = tmp_path / "sessions.db"
    store = SQLiteSessionStore(db_path)
    session = Agent(ToolCallingMockLLM(), SimpleToolRegistry()).session
    session.id = "derived-meta"
    session.turns = [
        Turn(role=Role.USER, content="How do I organize Python notes in Obsidian?"),
        Turn(role=Role.ASSISTANT, content="Use topic pages, backlinks, and a summary section."),
    ]

    store.save_session(session)
    loaded = store.load_session("derived-meta")

    assert loaded is not None
    assert loaded.metadata["title"] == "How do I organize Python notes in Obsidian?"
    assert loaded.metadata["preview"] == "Use topic pages, backlinks, and a summary section."
    assert loaded.metadata["turn_count"] == 2


def test_normalize_turns_for_llm_upgrades_legacy_tool_placeholders():
    turns = [
        Turn(role=Role.USER, content="hello"),
        Turn(role=Role.ASSISTANT, content='[tool_call: vault_search({"query": "python"})]'),
        Turn(role=Role.TOOL, content="result", name="vault_search", tool_call_id="call_legacy_1"),
    ]

    normalized = _normalize_turns_for_llm(turns)

    assert len(normalized) == 3
    assert normalized[1].role == Role.ASSISTANT
    assert normalized[1].name == "__tool_calls__"
    assert json.loads(normalized[1].content)[0]["id"] == "call_legacy_1"
    assert normalized[2].role == Role.TOOL
    assert normalized[2].tool_call_id == "call_legacy_1"


@pytest.mark.asyncio
async def test_multi_turn_context_preserved(tmp_path: Path):
    """Multiple turns are preserved in session."""

    class EchoLLM:
        model = "echo"
        base_url = "http://echo"
        async def complete(self, messages, **kw):
            last_user = [m for m in messages if m.role == Role.USER][-1]
            return Turn(role=Role.ASSISTANT, content=f"Echo: {last_user.content}")
        async def stream(self, messages, **kw):
            turn = await self.complete(messages)
            yield turn.content
        async def close(self): pass

    agent = Agent(EchoLLM(), SimpleToolRegistry())

    r1 = await agent.complete_oneshot("First")
    assert "First" in r1
    r2 = await agent.complete_oneshot("Second")
    assert "Second" in r2

    # session should have 4 turns: user, assistant, user, assistant
    assert len(agent.session.turns) == 4
