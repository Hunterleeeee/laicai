"""Tests for core types and tool definitions."""

from harness.core.types import (
    Chunk,
    Role,
    Session,
    ToolDef,
    ToolParam,
    ToolResult,
    Turn,
    TokenEvent,
    ThoughtEvent,
    ToolCallEvent,
    NoteEvent,
)


def test_turn_creation():
    t = Turn(role=Role.USER, content="hello")
    assert t.role == Role.USER
    assert t.content == "hello"
    assert t.timestamp is not None


def test_session_defaults():
    s = Session(id="s1")
    assert s.turns == []
    assert s.id == "s1"


def test_tool_def_openai_schema():
    td = ToolDef(
        name="search",
        description="Search the vault",
        parameters=[
            ToolParam(name="query", description="Search query"),
            ToolParam(name="top_k", type="integer", description="Max results", required=False),
        ],
    )
    schema = td.to_openai_schema()
    assert schema["type"] == "function"
    fn = schema["function"]
    assert fn["name"] == "search"
    assert "query" in fn["parameters"]["properties"]
    assert "query" in fn["parameters"]["required"]
    assert "top_k" not in fn["parameters"]["required"]


def test_tool_param_enum():
    tp = ToolParam(name="mode", enum=["fast", "precise"])
    assert tp.enum == ["fast", "precise"]


def test_chunk_defaults():
    c = Chunk(source="test.md", content="hello")
    assert c.score == 0.0
    assert c.meta == {}


def test_events():
    tok = TokenEvent(text="hi")
    assert tok.kind == "token"
    assert tok.done is False

    th = ThoughtEvent(text="thinking")
    assert th.kind == "thought"

    tc = ToolCallEvent(tool_call_id="x", name="search", arguments={"q": "hi"})
    assert tc.kind == "tool_call"

    ne = NoteEvent(path="notes/test.md")
    assert ne.kind == "note_saved"


def test_tool_result():
    r = ToolResult(tool_call_id="1", name="search", content="found it")
    assert r.success is True
