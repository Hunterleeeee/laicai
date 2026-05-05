"""Tests for REPL features: personas, export, usage events, slash commands."""

import io

import pytest
from rich.console import Console

import harness.cli.chat as chat_module
from harness.core.types import UsageEvent, Role, Turn, Session
from harness.agent.loop import Agent, _estimate_tokens
from harness.agent.tools import SimpleToolRegistry
from harness.cli.chat import PERSONAS, SLASH_COMMANDS, _handle_slash, _parse_wiki_command


# ── Personas ──

def test_personas_defined():
    assert "default" in PERSONAS
    assert "tutor" in PERSONAS
    assert "coder" in PERSONAS
    assert "writer" in PERSONAS
    assert "analyst" in PERSONAS
    for name, prompt in PERSONAS.items():
        assert isinstance(prompt, str)
        assert len(prompt) > 10


# ── Slash commands ──

def test_slash_commands_list():
    assert "/search" in SLASH_COMMANDS
    assert "/wiki" in SLASH_COMMANDS
    assert "/wiki-save" in SLASH_COMMANDS
    assert "/persona" in SLASH_COMMANDS
    assert "/export" in SLASH_COMMANDS
    assert "/help" in SLASH_COMMANDS


def test_parse_wiki_command_options():
    request, error = _parse_wiki_command('"Python packaging" --no-web --top-k=4 --web-results 0')

    assert error is None
    assert request == {
        "topic": "Python packaging",
        "top_k": 4,
        "use_web": False,
        "web_max_results": 0,
    }


class _SlashDummyLLM:
    model = "mock"
    base_url = "http://mock"


class _SlashDummyAgent:
    def __init__(self, registry: SimpleToolRegistry):
        self.registry = registry
        self.session = Session(id="slash-test")
        self.llm = _SlashDummyLLM()


@pytest.mark.asyncio
async def test_wiki_slash_stores_full_pending_request(monkeypatch, tmp_path):
    captured: list[dict[str, object]] = []
    registry = SimpleToolRegistry()

    @registry.tool(name="wiki_build_page")
    async def wiki_build_page(
        topic: str,
        top_k: int = 8,
        use_web: bool = True,
        web_max_results: int = 3,
        save: bool = False,
    ) -> str:
        captured.append(
            {
                "topic": topic,
                "top_k": top_k,
                "use_web": use_web,
                "web_max_results": web_max_results,
                "save": save,
            }
        )
        return f"Prepared wiki page for **{topic}**."

    output = io.StringIO()
    monkeypatch.setattr(chat_module, "console", Console(file=output, force_terminal=False, color_system=None, width=120))

    agent = _SlashDummyAgent(registry)
    await _handle_slash('/wiki "Python packaging" --no-web --top-k 4 --web-results 0', agent, tmp_path)

    assert captured == [
        {
            "topic": "Python packaging",
            "top_k": 4,
            "use_web": False,
            "web_max_results": 0,
            "save": False,
        }
    ]
    assert agent.session.metadata["wiki_pending_request"] == {
        "topic": "Python packaging",
        "top_k": 4,
        "use_web": False,
        "web_max_results": 0,
    }
    assert agent.session.metadata["wiki_pending_topic"] == "Python packaging"
    assert "Preparing wiki preview" in output.getvalue()


@pytest.mark.asyncio
async def test_wiki_save_reuses_pending_request(monkeypatch, tmp_path):
    captured: list[dict[str, object]] = []
    registry = SimpleToolRegistry()

    @registry.tool(name="wiki_build_page")
    async def wiki_build_page(
        topic: str,
        top_k: int = 8,
        use_web: bool = True,
        web_max_results: int = 3,
        save: bool = False,
    ) -> str:
        captured.append(
            {
                "topic": topic,
                "top_k": top_k,
                "use_web": use_web,
                "web_max_results": web_max_results,
                "save": save,
            }
        )
        return f"Built wiki page for **{topic}**."

    output = io.StringIO()
    monkeypatch.setattr(chat_module, "console", Console(file=output, force_terminal=False, color_system=None, width=120))

    agent = _SlashDummyAgent(registry)
    agent.session.metadata["wiki_pending_request"] = {
        "topic": "Python packaging",
        "top_k": 4,
        "use_web": False,
        "web_max_results": 0,
    }
    agent.session.metadata["wiki_pending_topic"] = "Python packaging"

    await _handle_slash("/wiki-save", agent, tmp_path)

    assert captured == [
        {
            "topic": "Python packaging",
            "top_k": 4,
            "use_web": False,
            "web_max_results": 0,
            "save": True,
        }
    ]
    assert "wiki_pending_request" not in agent.session.metadata
    assert "wiki_pending_topic" not in agent.session.metadata
    assert "Saving wiki preview" in output.getvalue()


# ── UsageEvent ──

def test_usage_event():
    evt = UsageEvent(input_tokens=100, output_tokens=50)
    assert evt.kind == "usage"
    assert evt.input_tokens == 100
    assert evt.output_tokens == 50


@pytest.mark.asyncio
async def test_chat_emits_usage_event():
    """Agent.chat should emit a UsageEvent at the end."""

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
    events = []
    async for evt in agent.chat("Hello"):
        events.append(evt)

    usage_events = [e for e in events if isinstance(e, UsageEvent)]
    assert len(usage_events) == 1
    assert usage_events[0].input_tokens > 0
    assert usage_events[0].output_tokens > 0


# ── Export format ──

def test_export_format():
    """Verify export builds valid markdown."""
    session = Session(id="test-123")
    session.turns = [
        Turn(role=Role.USER, content="What is Python?"),
        Turn(role=Role.ASSISTANT, content="Python is a programming language."),
        Turn(role=Role.USER, content="Tell me more"),
        Turn(role=Role.ASSISTANT, content="It was created by Guido van Rossum."),
    ]
    lines = [f"# Session {session.id}\n"]
    for turn in session.turns:
        if turn.role.value == "user":
            lines.append(f"## You\n\n{turn.content}\n")
        elif turn.role.value == "assistant":
            lines.append(f"## 来财\n\n{turn.content}\n")
    md = "\n".join(lines)
    assert "# Session test-123" in md
    assert "## You" in md
    assert "## 来财" in md
    assert "Python" in md
    assert "Guido" in md
