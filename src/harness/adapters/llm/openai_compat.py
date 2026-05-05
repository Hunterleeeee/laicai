"""Async LLM adapter for any OpenAI-compatible API (Ollama, DeepSeek, Qwen, etc.)."""

from __future__ import annotations

import json
import logging
import uuid
from typing import Any, AsyncIterator

import httpx

from harness.core.types import Role, ToolDef, Turn

logger = logging.getLogger(__name__)


def _tool_calls_message(content: str) -> dict[str, Any]:
    parsed = json.loads(content)
    raw_tool_calls: list[dict[str, Any]] = []
    for item in parsed if isinstance(parsed, list) else []:
        if not isinstance(item, dict):
            continue
        raw_tool_calls.append(
            {
                "id": str(item.get("id", "") or uuid.uuid4().hex[:8]),
                "type": "function",
                "function": {
                    "name": str(item.get("name", "") or ""),
                    "arguments": json.dumps(item.get("arguments", {}), ensure_ascii=False),
                },
            }
        )
    return {"role": Role.ASSISTANT.value, "content": None, "tool_calls": raw_tool_calls}


def _turn_to_message(t: Turn) -> dict[str, Any]:
    if t.role == Role.ASSISTANT and t.name == "__tool_calls__":
        return _tool_calls_message(t.content)
    msg: dict[str, Any] = {"role": t.role.value, "content": t.content}
    if t.name:
        msg["name"] = t.name
    if t.tool_call_id:
        msg["tool_call_id"] = t.tool_call_id
    return msg


def _parse_tool_calls(raw: list[dict]) -> list[dict[str, Any]]:
    """Extract tool calls from the OpenAI response format."""
    calls = []
    for tc in raw:
        fn = tc.get("function", {})
        args_str = fn.get("arguments", "{}")
        try:
            args = json.loads(args_str)
        except json.JSONDecodeError:
            args = {"raw": args_str}
        calls.append({
            "id": tc.get("id", uuid.uuid4().hex[:8]),
            "name": fn.get("name", ""),
            "arguments": args,
        })
    return calls


class OpenAICompatLLM:
    """Works with Ollama (localhost:11434), DeepSeek, Qwen, OpenAI, etc."""

    def __init__(
        self,
        base_url: str = "http://localhost:11434/v1",
        model: str = "qwen2.5:7b",
        api_key: str = "",
        extra_headers: dict[str, str] | None = None,
        timeout: float = 120.0,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.api_key = api_key
        self.extra_headers = {
            str(key).strip(): str(value).strip()
            for key, value in (extra_headers or {}).items()
            if str(key).strip() and str(value).strip()
        }
        self.timeout = timeout
        self._client: httpx.AsyncClient | None = None

    async def _get_client(self) -> httpx.AsyncClient:
        if self._client is None or self._client.is_closed:
            headers: dict[str, str] = {"Content-Type": "application/json", **self.extra_headers}
            if self.api_key and "Authorization" not in headers:
                headers["Authorization"] = f"Bearer {self.api_key}"
            self._client = httpx.AsyncClient(
                base_url=self.base_url,
                headers=headers,
                timeout=httpx.Timeout(self.timeout),
            )
        return self._client

    def _build_body(
        self,
        messages: list[Turn],
        *,
        tools: list[ToolDef] | None = None,
        temperature: float = 0.7,
        max_tokens: int = 4096,
        stream: bool = False,
    ) -> dict[str, Any]:
        body: dict[str, Any] = {
            "model": self.model,
            "messages": [_turn_to_message(t) for t in messages],
            "temperature": temperature,
            "max_tokens": max_tokens,
            "stream": stream,
        }
        if tools:
            body["tools"] = [t.to_openai_schema() for t in tools]
        return body

    def _response_error_text(self, response: httpx.Response) -> str:
        parts: list[str] = []
        payload: Any = None
        try:
            payload = response.json()
        except Exception:
            payload = None
        if isinstance(payload, dict):
            error = payload.get("error")
            if isinstance(error, dict):
                for key in ("message", "code", "type", "param"):
                    value = str(error.get(key, "") or "").strip()
                    if value:
                        parts.append(value)
            elif error is not None:
                value = str(error).strip()
                if value:
                    parts.append(value)
            for key in ("message", "detail"):
                value = str(payload.get(key, "") or "").strip()
                if value:
                    parts.append(value)
        text = response.text.strip()
        if text:
            parts.append(text[:2000])
        deduped: list[str] = []
        seen: set[str] = set()
        for part in parts:
            if part not in seen:
                seen.add(part)
                deduped.append(part)
        return " | ".join(deduped)

    def _compat_retry_bodies(self, body: dict[str, Any], seen: set[str]) -> list[dict[str, Any]]:
        variants: list[dict[str, Any]] = []

        def add(candidate: dict[str, Any]) -> None:
            fingerprint = json.dumps(candidate, sort_keys=True, ensure_ascii=False)
            if fingerprint in seen:
                return
            seen.add(fingerprint)
            variants.append(candidate)

        if "tools" in body:
            candidate = dict(body)
            candidate.pop("tools", None)
            add(candidate)
        if "temperature" in body:
            candidate = dict(body)
            candidate.pop("temperature", None)
            add(candidate)
        if "max_tokens" in body:
            candidate = dict(body)
            candidate["max_completion_tokens"] = candidate.pop("max_tokens")
            add(candidate)
            candidate = dict(body)
            candidate.pop("max_tokens", None)
            add(candidate)
        return variants

    async def _post_chat_completion(self, client: httpx.AsyncClient, body: dict[str, Any]) -> httpx.Response:
        pending: list[dict[str, Any]] = [body]
        seen = {json.dumps(body, sort_keys=True, ensure_ascii=False)}
        last_status = 0
        last_error = ""
        while pending:
            current = pending.pop(0)
            response = await client.post("/chat/completions", json=current)
            if response.is_success:
                return response
            last_status = response.status_code
            last_error = self._response_error_text(response)
            if response.status_code == 400:
                retries = self._compat_retry_bodies(current, seen)
                if retries:
                    pending.extend(retries)
                    continue
            break
        detail = last_error or f"HTTP {last_status}"
        raise RuntimeError(f"OpenAI-compatible chat request failed ({last_status}): {detail}")

    # ── single-shot completion ──

    async def complete(
        self,
        messages: list[Turn],
        *,
        tools: list[ToolDef] | None = None,
        temperature: float = 0.7,
        max_tokens: int = 4096,
    ) -> Turn:
        client = await self._get_client()
        body = self._build_body(
            messages, tools=tools, temperature=temperature,
            max_tokens=max_tokens, stream=False,
        )
        resp = await self._post_chat_completion(client, body)
        data = resp.json()

        choice = data["choices"][0]
        msg = choice["message"]

        # handle tool calls
        raw_tool_calls = msg.get("tool_calls")
        if raw_tool_calls:
            parsed = _parse_tool_calls(raw_tool_calls)
            # return a Turn with tool call info serialised into content
            return Turn(
                role=Role.ASSISTANT,
                content=json.dumps(parsed, ensure_ascii=False),
                name="__tool_calls__",
            )

        return Turn(
            role=Role.ASSISTANT,
            content=msg.get("content", ""),
        )

    # ── streaming completion ──

    async def stream(
        self,
        messages: list[Turn],
        *,
        tools: list[ToolDef] | None = None,
        temperature: float = 0.7,
        max_tokens: int = 4096,
    ) -> AsyncIterator[str]:
        client = await self._get_client()
        body = self._build_body(
            messages, tools=tools, temperature=temperature,
            max_tokens=max_tokens, stream=True,
        )
        # accumulate streamed tool calls
        tool_call_buffers: dict[int, dict] = {}

        async with client.stream("POST", "/chat/completions", json=body) as resp:
            resp.raise_for_status()
            async for line in resp.aiter_lines():
                if not line.startswith("data: "):
                    continue
                payload = line[6:]
                if payload.strip() == "[DONE]":
                    break
                try:
                    chunk = json.loads(payload)
                    delta = chunk["choices"][0].get("delta", {})

                    # handle streamed tool calls
                    if "tool_calls" in delta:
                        for tc_delta in delta["tool_calls"]:
                            idx = tc_delta.get("index", 0)
                            if idx not in tool_call_buffers:
                                tool_call_buffers[idx] = {
                                    "id": tc_delta.get("id", ""),
                                    "name": "",
                                    "arguments": "",
                                }
                            fn = tc_delta.get("function", {})
                            if "name" in fn:
                                tool_call_buffers[idx]["name"] = fn["name"]
                            if "arguments" in fn:
                                tool_call_buffers[idx]["arguments"] += fn["arguments"]
                        continue

                    text = delta.get("content", "")
                    if text:
                        yield text
                except (json.JSONDecodeError, KeyError, IndexError):
                    continue

        # if we accumulated tool calls, yield them as a special marker
        if tool_call_buffers:
            calls = []
            for idx in sorted(tool_call_buffers):
                buf = tool_call_buffers[idx]
                try:
                    args = json.loads(buf["arguments"])
                except json.JSONDecodeError:
                    args = {"raw": buf["arguments"]}
                calls.append({
                    "id": buf["id"] or uuid.uuid4().hex[:8],
                    "name": buf["name"],
                    "arguments": args,
                })
            yield f"__TOOL_CALLS__{json.dumps(calls, ensure_ascii=False)}"

    # ── lifecycle ──

    async def close(self) -> None:
        if self._client and not self._client.is_closed:
            await self._client.aclose()
