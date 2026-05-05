"""Core agent loop: receive message → think → call tools → respond.

Yields Event objects for streaming UI consumption.
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
from typing import AsyncIterator

from harness.adapters.llm.openai_compat import OpenAICompatLLM
from harness.agent.tools import SimpleToolRegistry
from harness.core.types import (
    Event,
    Role,
    Session,
    ThoughtEvent,
    TokenEvent,
    ToolCallEvent,
    ToolDef,
    ToolResult,
    Turn,
    UsageEvent,
)

logger = logging.getLogger(__name__)

SYSTEM_PROMPT = """\
You are 来财 (Laicai), a helpful local-first AI assistant.
You have access to a personal knowledge vault (Obsidian-style markdown notes) and web tools.
When the user asks a question:
1. If relevant notes might exist, use vault_search first.
2. If web information is needed, use web_search or web_fetch.
3. Use save_note to persist important findings.
4. If the user wants a canonical knowledge page or wiki page in Obsidian, use wiki_build_page. It can automatically combine vault notes with web research.
5. Always respond in the same language the user uses.
Be concise, accurate, and helpful.\
"""

MAX_TOOL_ROUNDS = 6
DEFAULT_MAX_CONTEXT_TOKENS = 8000  # conservative default; fits most 8k models


def _estimate_tokens(text: str) -> int:
    """Rough token estimate: ~4 chars per token for English, ~2 for CJK."""
    return max(1, len(text) // 3)


def _summarize_dropped(dropped: list[Turn]) -> str:
    """Create a compact summary of dropped turns to preserve context."""
    if not dropped:
        return ""
    user_msgs = [t.content[:100] for t in dropped if t.role == Role.USER]
    assistant_msgs = [t.content[:100] for t in dropped if t.role == Role.ASSISTANT and not t.content.startswith("[tool_call")]
    parts = []
    if user_msgs:
        parts.append(f"User discussed: {'; '.join(user_msgs[:5])}")
    if assistant_msgs:
        parts.append(f"Assistant covered: {'; '.join(assistant_msgs[:3])}")
    return "Earlier conversation summary:\n" + "\n".join(parts)


def _extract_tool_call_ids(turn: Turn) -> set[str]:
    if turn.role != Role.ASSISTANT or turn.name != "__tool_calls__":
        return set()
    try:
        payload = json.loads(turn.content)
    except Exception:
        return set()
    ids: set[str] = set()
    if isinstance(payload, list):
        for item in payload:
            if isinstance(item, dict):
                tool_call_id = str(item.get("id", "") or "").strip()
                if tool_call_id:
                    ids.add(tool_call_id)
    return ids


def _upgrade_legacy_tool_call_turn(turn: Turn, tool_turn: Turn) -> Turn | None:
    if turn.role != Role.ASSISTANT or tool_turn.role != Role.TOOL:
        return None
    if not turn.content.startswith("[tool_call:"):
        return None
    tool_call_id = str(tool_turn.tool_call_id or "").strip()
    if not tool_call_id:
        return None
    match = re.match(r"^\[tool_call:\s*([^\(]+)\((.*)\)\]$", turn.content)
    if match:
        tool_name = str(match.group(1) or tool_turn.name or "").strip()
        raw_arguments = str(match.group(2) or "").strip()
        try:
            arguments = json.loads(raw_arguments) if raw_arguments else {}
        except Exception:
            arguments = {"raw": raw_arguments}
    else:
        tool_name = str(tool_turn.name or "").strip()
        arguments = {}
    return Turn(
        role=Role.ASSISTANT,
        content=json.dumps([
            {
                "id": tool_call_id,
                "name": tool_name,
                "arguments": arguments,
            }
        ], ensure_ascii=False),
        name="__tool_calls__",
        timestamp=turn.timestamp,
    )


def _normalize_turns_for_llm(turns: list[Turn]) -> list[Turn]:
    normalized: list[Turn] = []
    valid_tool_call_ids: set[str] = set()
    index = 0
    while index < len(turns):
        turn = turns[index]
        next_turn = turns[index + 1] if index + 1 < len(turns) else None
        if (
            turn.role == Role.ASSISTANT
            and turn.name != "__tool_calls__"
            and turn.content.startswith("[tool_call:")
            and next_turn is not None
            and next_turn.role == Role.TOOL
        ):
            upgraded = _upgrade_legacy_tool_call_turn(turn, next_turn)
            if upgraded is not None:
                normalized.append(upgraded)
                valid_tool_call_ids.update(_extract_tool_call_ids(upgraded))
            index += 1
            continue
        if turn.role == Role.ASSISTANT and turn.name == "__tool_calls__":
            normalized.append(turn)
            valid_tool_call_ids.update(_extract_tool_call_ids(turn))
            index += 1
            continue
        if turn.role == Role.TOOL:
            tool_call_id = str(turn.tool_call_id or "").strip()
            if tool_call_id and tool_call_id in valid_tool_call_ids:
                normalized.append(turn)
            index += 1
            continue
        if turn.role == Role.ASSISTANT and turn.content.startswith("[tool_call:"):
            index += 1
            continue
        normalized.append(turn)
        index += 1
    return normalized


def _trim_messages(messages: list[Turn], max_tokens: int) -> list[Turn]:
    """Keep system prompt + as many recent turns as fit within the token budget.

    When turns are dropped, a summary of the dropped content is injected
    as a system message so the model retains key context.
    """
    if not messages:
        return messages

    # always keep the system message
    system = messages[0] if messages[0].role == Role.SYSTEM else None
    turns = messages[1:] if system else messages[:]

    budget = max_tokens
    if system:
        budget -= _estimate_tokens(system.content)

    # walk backwards, accumulate turns that fit
    kept: list[Turn] = []
    for turn in reversed(turns):
        cost = _estimate_tokens(turn.content)
        if budget - cost < 0 and kept:
            break
        budget -= cost
        kept.append(turn)
    kept.reverse()

    result = [system] if system else []

    # if we dropped turns, inject a summary
    dropped_count = len(turns) - len(kept)
    if dropped_count > 0:
        dropped = turns[:dropped_count]
        summary = _summarize_dropped(dropped)
        if summary:
            result.append(Turn(role=Role.SYSTEM, content=summary))

    result.extend(kept)
    return result


class Agent:
    """Stateful agent that manages a session and streams responses."""

    def __init__(
        self,
        llm: OpenAICompatLLM,
        registry: SimpleToolRegistry,
        *,
        system_prompt: str = SYSTEM_PROMPT,
        max_context_tokens: int = DEFAULT_MAX_CONTEXT_TOKENS,
    ) -> None:
        self.llm = llm
        self.registry = registry
        self.session = Session(id="default")
        self.system_prompt = system_prompt
        self.max_context_tokens = max_context_tokens
        self.stop_event: asyncio.Event | None = None

    def reset(self, session_id: str = "default") -> None:
        self.session = Session(id=session_id)

    def _build_messages(self, *, extra_system_messages: list[Turn] | None = None) -> list[Turn]:
        msgs = [Turn(role=Role.SYSTEM, content=self.system_prompt)]
        if extra_system_messages:
            msgs.extend(extra_system_messages)
        msgs.extend(_normalize_turns_for_llm(self.session.turns))
        return _trim_messages(msgs, self.max_context_tokens)

    def _is_stopped(self) -> bool:
        return self.stop_event is not None and self.stop_event.is_set()

    async def chat(self, user_message: str, *, extra_system_messages: list[Turn] | None = None) -> AsyncIterator[Event]:
        """Process a user message and yield streaming events."""
        self.session.turns.append(Turn(role=Role.USER, content=user_message))

        tool_defs = self.registry.list_tools()

        for _round in range(MAX_TOOL_ROUNDS):
            if self._is_stopped():
                yield TokenEvent(text="", done=True)
                self.session.turns.append(Turn(role=Role.ASSISTANT, content="[生成已停止]"))
                return

            messages = self._build_messages(extra_system_messages=extra_system_messages)

            # try streaming first; detect tool calls from stream or fallback
            full_text = ""
            streamed_tool_calls: list[dict] | None = None
            try:
                async for token in self.llm.stream(
                    messages, tools=tool_defs if tool_defs else None
                ):
                    if self._is_stopped():
                        yield TokenEvent(text="", done=True)
                        self.session.turns.append(Turn(role=Role.ASSISTANT, content=full_text or "[生成已停止]"))
                        return
                    # check for tool call marker from streaming
                    if token.startswith("__TOOL_CALLS__"):
                        streamed_tool_calls = json.loads(token[len("__TOOL_CALLS__"):])
                    else:
                        full_text += token
                        yield TokenEvent(text=token)
            except Exception:
                # fallback to non-streaming
                logger.debug("Streaming failed, falling back to complete()")
                turn = await self.llm.complete(
                    messages, tools=tool_defs if tool_defs else None
                )
                full_text = turn.content
                if turn.name == "__tool_calls__":
                    streamed_tool_calls = json.loads(turn.content)
                else:
                    for chunk in _chunk_text(full_text, 20):
                        yield TokenEvent(text=chunk)

            # if no text and no tool calls from stream, try non-streaming
            if not full_text.strip() and not streamed_tool_calls:
                turn = await self.llm.complete(
                    messages, tools=tool_defs if tool_defs else None
                )
                if turn.name == "__tool_calls__":
                    streamed_tool_calls = json.loads(turn.content)
                else:
                    full_text = turn.content
                    for chunk in _chunk_text(full_text, 20):
                        yield TokenEvent(text=chunk)

            # execute tool calls if any
            if streamed_tool_calls:
                self.session.turns.append(Turn(
                    role=Role.ASSISTANT,
                    content=json.dumps(streamed_tool_calls, ensure_ascii=False),
                    name="__tool_calls__",
                ))
                for tc in streamed_tool_calls:
                    if self._is_stopped():
                        yield TokenEvent(text="", done=True)
                        self.session.turns.append(Turn(role=Role.ASSISTANT, content=full_text or "[生成已停止]"))
                        return
                    yield ToolCallEvent(
                        tool_call_id=tc["id"],
                        name=tc["name"],
                        arguments=tc["arguments"],
                    )
                    yield ThoughtEvent(text=f"Calling {tc['name']}...")
                    result = await self.registry.call(tc["name"], tc["arguments"])
                    self.session.turns.append(Turn(
                        role=Role.TOOL,
                        content=result.content,
                        name=tc["name"],
                        tool_call_id=result.tool_call_id,
                    ))
                continue  # let the LLM respond with tool results in context

            # normal text response — done
            yield TokenEvent(text="", done=True)
            self.session.turns.append(Turn(role=Role.ASSISTANT, content=full_text))
            # emit usage stats
            input_toks = sum(_estimate_tokens(m.content) for m in messages)
            output_toks = _estimate_tokens(full_text)
            yield UsageEvent(input_tokens=input_toks, output_tokens=output_toks)
            return

        # exhausted tool rounds
        yield TokenEvent(text="\n[Max tool rounds reached]", done=True)

    async def complete_oneshot(self, user_message: str) -> str:
        """Non-streaming single-shot for programmatic use."""
        full = []
        async for event in self.chat(user_message):
            if isinstance(event, TokenEvent):
                full.append(event.text)
        return "".join(full)


def _chunk_text(text: str, size: int) -> list[str]:
    return [text[i:i + size] for i in range(0, len(text), size)] if text else []
