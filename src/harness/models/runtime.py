"""DEPRECATED: Use harness.adapters.llm.OpenAICompatLLM (async, streaming) instead."""
from __future__ import annotations

from dataclasses import dataclass
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError
import json
import os

from harness.config import ModelConfig, RuntimeConfig
from harness.models.discovery import discover_ollama_models


@dataclass
class ModelResponse:
    content: str
    ok: bool = True


class LocalModelRuntime:
    def __init__(self, config: ModelConfig, runtime: RuntimeConfig) -> None:
        self.config = config
        self.runtime = runtime
        self._model_name = self._resolve_model_name()
        self._api_key = self._resolve_api_key()

    def status(self) -> str:
        return f"{self.config.provider} @ {self.config.endpoint} ({self._model_name})"

    def resolved_api_key(self) -> str:
        return self._api_key

    def complete(self, prompt: str, max_tokens: int | None = None) -> ModelResponse:
        max_tokens = max_tokens if max_tokens is not None else self.runtime.resolved_max_output_tokens()
        response = ModelResponse(content="", ok=False)
        token_budgets = [max_tokens]
        if self._is_local_provider():
            token_budgets.append(max(max_tokens, 256))
        for current_tokens in token_budgets:
            response = self._complete_once(prompt, max_tokens=current_tokens)
            if response.ok and response.content.strip():
                return response
            if self._is_local_provider():
                ollama_response = self._complete_ollama(prompt, max_tokens=current_tokens, disable_thinking=True)
                if ollama_response.ok and ollama_response.content.strip():
                    return ollama_response
                response = ollama_response
        return response

    def _complete_once(self, prompt: str, max_tokens: int | None = None) -> ModelResponse:
        max_tokens = max_tokens if max_tokens is not None else self.runtime.resolved_max_output_tokens()
        endpoint = self.config.endpoint.rstrip("/") + "/chat/completions"
        payload = {
            "model": self._model_name,
            "messages": [
                {"role": "system", "content": "You are a concise local agent assistant."},
                {"role": "user", "content": prompt},
            ],
            "temperature": 0.2,
            "stream": False,
        }
        if max_tokens is not None:
            payload["max_tokens"] = max_tokens
        request = Request(
            endpoint,
            data=json.dumps(payload).encode("utf-8"),
            headers=self._openai_headers(),
        )
        try:
            with urlopen(request, timeout=self.runtime.resolved_request_timeout_seconds()) as response:
                data = json.loads(response.read().decode("utf-8"))
        except HTTPError as exc:
            if exc.code == 404 and self._is_local_provider():
                return self._complete_ollama(prompt, max_tokens=max_tokens)
            return ModelResponse(
                content=(
                    "Model call failed.\n\n"
                    f"Endpoint: {endpoint}\n"
                    f"Provider: {self.config.provider}\n"
                    f"Model: {self._model_name}\n"
                    f"Error: {exc}\n\n"
                    "Prompt preview:\n"
                    f"{prompt[:1000]}"
                ),
                ok=False,
            )
        except (URLError, TimeoutError, json.JSONDecodeError) as exc:
            return ModelResponse(
                content=(
                    "Model call failed.\n\n"
                    f"Endpoint: {endpoint}\n"
                    f"Provider: {self.config.provider}\n"
                    f"Model: {self._model_name}\n"
                    f"Error: {exc}\n\n"
                    "Prompt preview:\n"
                    f"{prompt[:1000]}"
                ),
                ok=False,
            )

        try:
            message = data["choices"][0]["message"]
        except (KeyError, IndexError, TypeError):
            content = json.dumps(data, ensure_ascii=False, indent=2)
        else:
            content = self._extract_message_content(message)
        content = content.strip()
        return ModelResponse(content=content, ok=bool(content))

    def _complete_ollama(
        self,
        prompt: str,
        max_tokens: int | None = None,
        *,
        disable_thinking: bool = False,
    ) -> ModelResponse:
        max_tokens = max_tokens if max_tokens is not None else self.runtime.resolved_max_output_tokens()
        endpoint = self.config.endpoint.rstrip("/")
        if endpoint.endswith("/v1"):
            endpoint = endpoint[:-3]
        endpoint = endpoint + "/api/chat"
        payload = {
            "model": self._model_name,
            "messages": [
                {"role": "system", "content": "You are a concise local agent assistant."},
                {"role": "user", "content": prompt},
            ],
            "stream": False,
        }
        if disable_thinking:
            payload["think"] = False
        options: dict[str, int] = {
            "num_predict": max_tokens,
            "num_ctx": self.runtime.resolved_ollama_num_ctx(),
        }
        payload["options"] = options
        request = Request(
            endpoint,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        try:
            with urlopen(request, timeout=self.runtime.resolved_request_timeout_seconds()) as response:
                data = json.loads(response.read().decode("utf-8"))
        except (HTTPError, URLError, TimeoutError, json.JSONDecodeError) as exc:
            return ModelResponse(
                content=(
                    "Local model call failed.\n\n"
                    f"Endpoint: {endpoint}\n"
                    f"Model: {self._model_name}\n"
                    f"Error: {exc}\n\n"
                    "Prompt preview:\n"
                    f"{prompt[:1000]}"
                ),
                ok=False,
            )

        try:
            content = data["message"]["content"]
        except (KeyError, TypeError):
            content = json.dumps(data, ensure_ascii=False, indent=2)
        content = content.strip()
        return ModelResponse(content=content, ok=bool(content))

    def _extract_message_content(self, message: object) -> str:
        if not isinstance(message, dict):
            return ""
        content = message.get("content", "")
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            parts: list[str] = []
            for item in content:
                if isinstance(item, dict):
                    text = item.get("text", "")
                    if isinstance(text, str) and text:
                        parts.append(text)
            return "\n".join(parts)
        return ""

    def _resolve_model_name(self) -> str:
        configured = self.config.model.strip()
        if configured and configured.lower() != "auto":
            return configured
        if not self._is_local_provider():
            return "gpt-4.1-mini"
        discovered = discover_ollama_models()
        if discovered:
            return discovered[-1]
        return "qwen3.5:9b"

    def _resolve_api_key(self) -> str:
        env_name = (self.config.api_key_env or "").strip()
        if env_name:
            return os.getenv(env_name, self.config.api_key)
        return self.config.api_key

    def _openai_headers(self) -> dict[str, str]:
        headers = {"Content-Type": "application/json"}
        if self._api_key:
            headers["Authorization"] = f"Bearer {self._api_key}"
        return headers

    def _is_local_provider(self) -> bool:
        return self.config.provider in {"local-openai-compatible", "ollama"}
