from __future__ import annotations

import httpx
import pytest
import json

from harness.adapters.llm.openai_compat import OpenAICompatLLM, _turn_to_message
from harness.core.types import Role, ToolDef, Turn


class FakeAsyncClient:
    def __init__(self, responder):
        self.responder = responder
        self.requests: list[dict] = []

    async def post(self, path: str, json: dict):
        self.requests.append({"path": path, "json": json})
        return self.responder(path, json)


def _response(status_code: int, payload: dict) -> httpx.Response:
    request = httpx.Request("POST", "https://example.com/v1/chat/completions")
    return httpx.Response(status_code, request=request, json=payload)


@pytest.mark.asyncio
async def test_complete_retries_without_tools(monkeypatch: pytest.MonkeyPatch):
    def responder(_path: str, body: dict) -> httpx.Response:
        if "tools" in body:
            return _response(400, {"error": {"message": "tools are not supported by this model"}})
        return _response(200, {"choices": [{"message": {"content": "ok without tools"}}]})

    client = FakeAsyncClient(responder)
    llm = OpenAICompatLLM(base_url="https://example.com/v1", model="demo-model")

    async def fake_get_client():
        return client

    monkeypatch.setattr(llm, "_get_client", fake_get_client)

    result = await llm.complete(
        [Turn(role=Role.USER, content="hello")],
        tools=[ToolDef(name="ping", description="Ping tool")],
    )

    assert result.content == "ok without tools"
    assert len(client.requests) == 2
    assert "tools" in client.requests[0]["json"]
    assert "tools" not in client.requests[1]["json"]


@pytest.mark.asyncio
async def test_complete_retries_with_max_completion_tokens(monkeypatch: pytest.MonkeyPatch):
    def responder(_path: str, body: dict) -> httpx.Response:
        if "max_completion_tokens" in body:
            return _response(200, {"choices": [{"message": {"content": "ok with completion tokens"}}]})
        if "max_tokens" in body:
            return _response(400, {"error": {"message": "unsupported parameter: max_tokens"}})
        return _response(400, {"error": {"message": "unexpected request"}})

    client = FakeAsyncClient(responder)
    llm = OpenAICompatLLM(base_url="https://example.com/v1", model="demo-model")

    async def fake_get_client():
        return client

    monkeypatch.setattr(llm, "_get_client", fake_get_client)

    result = await llm.complete([Turn(role=Role.USER, content="hello")])

    assert result.content == "ok with completion tokens"
    assert any("max_completion_tokens" in call["json"] for call in client.requests)


@pytest.mark.asyncio
async def test_complete_surfaces_provider_error_details(monkeypatch: pytest.MonkeyPatch):
    def responder(_path: str, _body: dict) -> httpx.Response:
        return _response(400, {"error": {"message": "model_not_found", "code": "bad_request"}})

    client = FakeAsyncClient(responder)
    llm = OpenAICompatLLM(base_url="https://example.com/v1", model="missing-model")

    async def fake_get_client():
        return client

    monkeypatch.setattr(llm, "_get_client", fake_get_client)

    with pytest.raises(RuntimeError) as excinfo:
        await llm.complete([Turn(role=Role.USER, content="hello")])

    message = str(excinfo.value)
    assert "model_not_found" in message
    assert "bad_request" in message


def test_turn_to_message_serializes_assistant_tool_calls():
    turn = Turn(
        role=Role.ASSISTANT,
        content=json.dumps([
            {"id": "call_1", "name": "search", "arguments": {"query": "python"}}
        ], ensure_ascii=False),
        name="__tool_calls__",
    )

    message = _turn_to_message(turn)

    assert message["role"] == "assistant"
    assert message["content"] is None
    assert message["tool_calls"][0]["id"] == "call_1"
    assert message["tool_calls"][0]["function"]["name"] == "search"
    assert json.loads(message["tool_calls"][0]["function"]["arguments"]) == {"query": "python"}
