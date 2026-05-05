"""Interactive REPL: `laicai` or `laicai chat` enters this loop.

Features:
  - Rich Markdown rendering for assistant output (code, tables, lists)
  - prompt_toolkit for multiline input (Alt+Enter to send, or single-line Enter)
  - Ctrl+C interrupts current generation without exiting
  - Spinner + timing for tool calls
  - Session persistence with /history and /resume
"""

from __future__ import annotations

import asyncio
import shlex
import sys
import time
import uuid
from pathlib import Path

from prompt_toolkit import PromptSession
from prompt_toolkit.completion import WordCompleter
from prompt_toolkit.formatted_text import HTML
from prompt_toolkit.key_binding import KeyBindings
from rich.console import Console
from rich.markdown import Markdown
from rich.panel import Panel

from harness.adapters.bootstrap import create_llm_from_config, resolve_vault_root
from harness.adapters.storage import SQLiteSessionStore
from harness.agent.builtin_tools import register_builtins
from harness.agent.loop import Agent
from harness.agent.tools import SimpleToolRegistry
from harness.config import load_config, session_store_db_path
from harness.core.types import ThoughtEvent, TokenEvent, ToolCallEvent, NoteEvent, UsageEvent

# ── Personas ──────────────────────────────────────────────────

PERSONAS: dict[str, str] = {
    "default": "You are 来财 (Laicai), a helpful local-first AI assistant.",
    "tutor": "You are a patient academic tutor. Explain concepts step by step, use examples, and check understanding.",
    "coder": "You are an expert programmer. Write clean, well-tested code. Explain your reasoning concisely.",
    "writer": "You are a skilled writer. Help draft, edit, and improve prose. Focus on clarity and style.",
    "analyst": "You are a sharp data analyst. Break down problems, find patterns, and present insights clearly.",
}

console = Console()


# ── Banner ─────────────────────────────────────────────────────

# ── Slash command list (for completer) ────────────────────────

SLASH_COMMANDS = [
    "/search", "/wiki", "/wiki-save", "/save", "/model", "/history", "/resume",
    "/clear", "/quit", "/exit", "/persona", "/export", "/help",
]


def _compact_text(text: str, limit: int) -> str:
    collapsed = " ".join(text.split())
    if len(collapsed) <= limit:
        return collapsed
    return collapsed[: limit - 1].rstrip() + "…"


def _latest_user_title(agent: Agent) -> str | None:
    for turn in reversed(agent.session.turns):
        if turn.role.value == "user" and turn.content.strip():
            return _compact_text(turn.content, 60)
    return None


def _last_assistant_title(agent: Agent) -> str | None:
    for turn in reversed(agent.session.turns):
        if turn.role.value == "assistant" and turn.content.strip() and not turn.content.startswith("[tool_call"):
            return _compact_text(turn.content, 60)
    return None


def _wiki_usage() -> str:
    return "Usage: /wiki <topic> [--web|--no-web] [--top-k N] [--web-results N]"


def _parse_wiki_int_option(name: str, raw_value: str, *, minimum: int) -> int:
    try:
        value = int(raw_value)
    except ValueError as exc:
        raise ValueError(f"{name} must be an integer.") from exc
    if value < minimum:
        raise ValueError(f"{name} must be >= {minimum}.")
    return value


def _parse_wiki_command(arg: str) -> tuple[dict[str, object] | None, str | None]:
    try:
        tokens = shlex.split(arg)
    except ValueError as exc:
        return None, f"Invalid /wiki arguments: {exc}. {_wiki_usage()}"

    if not tokens:
        return None, _wiki_usage()

    topic_parts: list[str] = []
    top_k = 8
    use_web = True
    web_max_results = 3
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token == "--web":
            use_web = True
        elif token == "--no-web":
            use_web = False
        elif token == "--top-k":
            index += 1
            if index >= len(tokens):
                return None, f"Missing value for --top-k. {_wiki_usage()}"
            try:
                top_k = _parse_wiki_int_option("top_k", tokens[index], minimum=1)
            except ValueError as exc:
                return None, f"{exc} {_wiki_usage()}"
        elif token.startswith("--top-k="):
            try:
                top_k = _parse_wiki_int_option("top_k", token.split("=", 1)[1], minimum=1)
            except ValueError as exc:
                return None, f"{exc} {_wiki_usage()}"
        elif token == "--web-results":
            index += 1
            if index >= len(tokens):
                return None, f"Missing value for --web-results. {_wiki_usage()}"
            try:
                web_max_results = _parse_wiki_int_option("web_max_results", tokens[index], minimum=0)
            except ValueError as exc:
                return None, f"{exc} {_wiki_usage()}"
        elif token.startswith("--web-results="):
            try:
                web_max_results = _parse_wiki_int_option("web_max_results", token.split("=", 1)[1], minimum=0)
            except ValueError as exc:
                return None, f"{exc} {_wiki_usage()}"
        elif token.startswith("--"):
            return None, f"Unknown /wiki option: {token}. {_wiki_usage()}"
        else:
            topic_parts.append(token)
        index += 1

    topic = " ".join(topic_parts).strip()
    if not topic:
        return None, _wiki_usage()

    return {
        "topic": topic,
        "top_k": top_k,
        "use_web": use_web,
        "web_max_results": web_max_results,
    }, None


def _wiki_request_summary(request: dict[str, object]) -> str:
    summary = f'topic="{request["topic"]}", top_k={request["top_k"]}, web={"on" if request["use_web"] else "off"}'
    if request["use_web"]:
        summary += f", web_results={request['web_max_results']}"
    return summary


def _pending_wiki_request(agent: Agent) -> dict[str, object] | None:
    pending = agent.session.metadata.get("wiki_pending_request")
    if isinstance(pending, dict):
        topic = str(pending.get("topic", "")).strip()
        if not topic:
            return None
        return {
            "topic": topic,
            "top_k": int(pending.get("top_k", 8)),
            "use_web": bool(pending.get("use_web", True)),
            "web_max_results": int(pending.get("web_max_results", 3)),
        }
    pending_topic = agent.session.metadata.get("wiki_pending_topic")
    if isinstance(pending_topic, str) and pending_topic.strip():
        return {
            "topic": pending_topic.strip(),
            "top_k": 8,
            "use_web": True,
            "web_max_results": 3,
        }
    return None


def _print_banner() -> None:
    console.print(Panel.fit(
        "[bold]来财 (Laicai)[/bold] — local-first AI assistant\n\n"
        "Type your message and press [cyan]Enter[/cyan] to send.\n"
        "[cyan]Alt+Enter[/cyan] to add a line. [cyan]Tab[/cyan] to complete commands.\n\n"
        "[dim]Commands:[/dim]\n"
        "  [cyan]/search <query>[/cyan]  search vault\n"
        "  [cyan]/wiki <topic> [opts][/cyan] preview Obsidian wiki page\n"
        "  [dim]                         opts: --no-web --top-k N --web-results N[/dim]\n"
        "  [cyan]/wiki-save[/cyan]       confirm and write the last wiki preview\n"
        "  [cyan]/save[/cyan]           save last response\n"
        "  [cyan]/model <name>[/cyan]   switch model\n"
        "  [cyan]/persona <name>[/cyan] switch persona (tutor/coder/writer/analyst)\n"
        "  [cyan]/export[/cyan]         export conversation as markdown\n"
        "  [cyan]/history[/cyan]        list sessions\n"
        "  [cyan]/resume <id>[/cyan]    resume session\n"
        "  [cyan]/clear[/cyan]          new conversation\n"
        "  [cyan]/help[/cyan]           show this help\n"
        "  [cyan]/quit[/cyan]           exit",
        border_style="cyan",
    ))


# ── Slash commands ─────────────────────────────────────────────

async def _handle_slash(
    cmd: str,
    agent: Agent,
    vault_root: Path | None,
    store: SQLiteSessionStore | None = None,
) -> bool:
    """Handle a slash command. Returns True to signal exit."""
    parts = cmd.strip().split(maxsplit=1)
    command = parts[0].lower()
    arg = parts[1] if len(parts) > 1 else ""

    if command in ("/quit", "/exit", "/q"):
        console.print("[dim]Bye![/dim]")
        return True

    if command == "/clear":
        if store:
            store.save_session(agent.session)
        agent.reset(uuid.uuid4().hex[:12])
        console.print(f"[dim]New session: {agent.session.id}[/dim]")
        return False

    if command == "/history":
        if not store:
            console.print("[dim]No session store.[/dim]")
            return False
        sessions = store.list_sessions(limit=10)
        if not sessions:
            console.print("[dim]No saved sessions.[/dim]")
        else:
            for idx, s in enumerate(sessions, start=1):
                title = s.metadata.get("title") or f"Session {s.id}"
                preview = s.metadata.get("preview") or ""
                turn_count = s.metadata.get("turn_count", 0)
                line = f"[{idx}] {title}"
                meta = f"{s.id} · {s.created_at:%Y-%m-%d %H:%M} · {turn_count} turns"
                console.print(f"  [bold]{line}[/bold]")
                console.print(f"  [dim]{meta}[/dim]")
                if preview:
                    console.print(f"  [dim]{preview}[/dim]")
        return False

    if command == "/resume":
        if not store or not arg:
            console.print("[dim]Usage: /resume <session-id|history-index>[/dim]")
            return False
        session_id = arg
        if arg.isdigit():
            sessions = store.list_sessions(limit=10)
            selection = int(arg)
            if selection < 1 or selection > len(sessions):
                console.print(f"[dim]History index out of range: {arg}[/dim]")
                return False
            session_id = sessions[selection - 1].id
        loaded = store.load_session(session_id)
        if not loaded:
            console.print(f"[dim]Not found: {arg}[/dim]")
            return False
        agent.session = loaded
        title = loaded.metadata.get("title") or session_id
        console.print(f"[dim]Resumed {title} ({len(loaded.turns)} turns)[/dim]")
        return False

    if command == "/model":
        if not arg:
            console.print(f"[dim]Model: {agent.llm.model}[/dim]")
        else:
            agent.llm.model = arg
            console.print(f"[dim]Switched to: {arg}[/dim]")
        return False

    if command == "/search":
        if not arg:
            console.print("[dim]Usage: /search <query>[/dim]")
            return False
        if vault_root:
            result = await agent.registry.call("vault_search", {"query": arg})
            console.print(Markdown(result.content))
        else:
            console.print("[dim]No vault configured.[/dim]")
        return False

    if command == "/wiki":
        if not vault_root:
            console.print("[dim]No vault configured.[/dim]")
            return False
        request, error = _parse_wiki_command(arg)
        if error:
            console.print(f"[dim]{error}[/dim]")
            return False
        console.print(f"[dim]Preparing wiki preview ({_wiki_request_summary(request)})[/dim]")
        result = await agent.registry.call("wiki_build_page", {**request, "save": False})
        if result.success:
            agent.session.metadata["wiki_pending_request"] = request
            agent.session.metadata["wiki_pending_topic"] = str(request["topic"])
        console.print(Markdown(result.content))
        return False

    if command == "/wiki-save":
        request = _pending_wiki_request(agent)
        if request is None:
            console.print("[dim]No pending wiki preview. Run /wiki <topic> first.[/dim]")
            return False
        if not vault_root:
            console.print("[dim]No vault configured.[/dim]")
            return False
        console.print(f"[dim]Saving wiki preview ({_wiki_request_summary(request)})[/dim]")
        result = await agent.registry.call("wiki_build_page", {**request, "save": True})
        if result.success:
            agent.session.metadata.pop("wiki_pending_request", None)
            agent.session.metadata.pop("wiki_pending_topic", None)
        console.print(Markdown(result.content))
        return False

    if command == "/save":
        for turn in reversed(agent.session.turns):
            if turn.role.value == "assistant" and not turn.content.startswith("[tool_call"):
                title = _latest_user_title(agent) or _last_assistant_title(agent) or "Laicai Note"
                result = await agent.registry.call("save_note", {
                    "title": title,
                    "content": turn.content,
                })
                console.print(f"[dim]{result.content}[/dim]")
                return False
        console.print("[dim]No response to save.[/dim]")
        return False

    if command == "/persona":
        if not arg:
            names = ", ".join(PERSONAS.keys())
            console.print(f"[dim]Available: {names}[/dim]")
            console.print(f"[dim]Current: {agent.session.metadata.get('persona', 'default')}[/dim]")
        elif arg in PERSONAS:
            agent.system_prompt = PERSONAS[arg]
            agent.session.metadata["persona"] = arg
            console.print(f"[dim]Persona → {arg}[/dim]")
        else:
            console.print(f"[dim]Unknown persona: {arg}. Available: {', '.join(PERSONAS.keys())}[/dim]")
        return False

    if command == "/export":
        if not agent.session.turns:
            console.print("[dim]Nothing to export.[/dim]")
            return False
        lines = [f"# Session {agent.session.id}\n"]
        for turn in agent.session.turns:
            if turn.role.value == "user":
                lines.append(f"## You\n\n{turn.content}\n")
            elif turn.role.value == "assistant" and not turn.content.startswith("[tool_call"):
                lines.append(f"## 来财\n\n{turn.content}\n")
        md_text = "\n".join(lines)
        if vault_root:
            export_path = vault_root / f"session-{agent.session.id}.md"
            export_path.write_text(md_text, encoding="utf-8")
            console.print(f"[dim]Exported to {export_path}[/dim]")
        else:
            console.print(Markdown(md_text))
        return False

    if command == "/help":
        _print_banner()
        return False

    console.print(f"[dim]Unknown: {command}. Type /help for commands.[/dim]")
    return False


# ── Prompt setup ───────────────────────────────────────────────

def _create_prompt_session() -> PromptSession:
    """Create a prompt_toolkit session with Tab completion and multiline."""
    bindings = KeyBindings()

    @bindings.add("escape", "enter")
    def _(event):
        """Alt+Enter inserts a newline."""
        event.current_buffer.insert_text("\n")

    # Tab completion for slash commands
    completer = WordCompleter(
        SLASH_COMMANDS + list(PERSONAS.keys()),
        sentence=True,
    )

    return PromptSession(
        key_bindings=bindings,
        completer=completer,
        complete_while_typing=False,
        multiline=False,
    )


# ── Main REPL ──────────────────────────────────────────────────

async def _repl(
    base_url: str | None = None,
    model: str | None = None,
    api_key: str | None = None,
    vault_path: str | None = None,
) -> None:
    config = load_config()
    vault_root = resolve_vault_root(vault_path)

    try:
        llm = create_llm_from_config(base_url=base_url, model=model, api_key=api_key)
    except RuntimeError as e:
        console.print(f"[yellow]⚠ {e}[/yellow]")
        sys.exit(1)

    store = SQLiteSessionStore(session_store_db_path())

    # try to set up embedding for semantic search
    embedding = None
    try:
        from harness.adapters.embedding import create_embedding_adapter
        embedding = create_embedding_adapter()
    except Exception:
        pass

    registry = SimpleToolRegistry()
    register_builtins(
        registry,
        vault_root=vault_root,
        image_generation=config.image_generation,
        embedding_adapter=embedding,
        llm=llm,
        wiki_progress=lambda message: console.print(f"[dim]{message}[/dim]"),
    )
    agent = Agent(llm, registry)
    agent.reset(uuid.uuid4().hex[:12])

    _print_banner()
    if vault_root:
        mode = "semantic" if embedding else "keyword"
        console.print(f"[dim]Vault: {vault_root} ({mode} search)[/dim]")
    console.print(f"[dim]Model: {llm.model} @ {llm.base_url}[/dim]\n")

    prompt_session = _create_prompt_session()

    while True:
        # ── get user input ──
        try:
            user_input = prompt_session.prompt(
                HTML("<ansigreen>You: </ansigreen>"),
            ).strip()
        except (EOFError, KeyboardInterrupt):
            console.print("\n[dim]Bye![/dim]")
            break

        if not user_input:
            continue

        if user_input.startswith("/"):
            should_exit = await _handle_slash(user_input, agent, vault_root, store)
            if should_exit:
                break
            continue

        # ── stream response ──
        t0 = time.monotonic()
        full_response = ""
        interrupted = False
        usage_info: dict | None = None

        console.print()  # blank line before response

        try:
            async for event in agent.chat(user_input):
                if isinstance(event, TokenEvent):
                    if event.done:
                        pass
                    else:
                        full_response += event.text
                        console.print(event.text, end="", highlight=False)
                elif isinstance(event, UsageEvent):
                    usage_info = {"in": event.input_tokens, "out": event.output_tokens}
                elif isinstance(event, ThoughtEvent):
                    console.print(f"\n  [dim]💭 {event.text}[/dim]", end="")
                elif isinstance(event, ToolCallEvent):
                    console.print(f"\n  [dim]🔧 {event.name}({event.arguments})[/dim]", end="")
                elif isinstance(event, NoteEvent):
                    console.print(f"\n  [dim]📝 {event.path}[/dim]", end="")
        except KeyboardInterrupt:
            interrupted = True
            console.print("\n[dim italic]  ⏹ Generation interrupted[/dim italic]")

        # render final markdown output
        if full_response.strip():
            console.print()  # newline after streaming
            console.print(Panel(
                Markdown(full_response),
                title="[cyan]来财[/cyan]",
                border_style="dim",
                padding=(0, 1),
            ))

        elapsed = time.monotonic() - t0
        usage_str = f"({elapsed:.1f}s"
        if usage_info:
            usage_str += f" · {usage_info['in']}→{usage_info['out']} tok"
        usage_str += ")"
        console.print(f"[dim]{usage_str}[/dim]\n")

        if store and not interrupted:
            store.save_session(agent.session)

    # cleanup
    if store:
        store.save_session(agent.session)
    await llm.close()


def run_chat(
    base_url: str | None = None,
    model: str | None = None,
    api_key: str | None = None,
    vault_path: str | None = None,
) -> None:
    """Entry point for the REPL, called from CLI."""
    asyncio.run(_repl(base_url, model, api_key, vault_path))
