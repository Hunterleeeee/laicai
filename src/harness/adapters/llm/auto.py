"""Auto-detect best available LLM backend.

Strategy:
  1. If HARNESS_API_KEY or OPENAI_API_KEY is set → use that provider's API
  2. Else probe Ollama at localhost:11434
  3. Else raise with helpful message
"""

from __future__ import annotations

import logging
import os

import httpx

from harness.adapters.llm.openai_compat import OpenAICompatLLM

logger = logging.getLogger(__name__)

# well-known provider configs: (env_key, base_url, default_model)
_PROVIDERS: list[tuple[str, str, str]] = [
    ("HARNESS_API_KEY", "https://api.deepseek.com/v1", "deepseek-chat"),
    ("OPENAI_API_KEY", "https://api.openai.com/v1", "gpt-4o-mini"),
    ("DASHSCOPE_API_KEY", "https://dashscope.aliyuncs.com/compatible-mode/v1", "qwen-plus"),
]


def _probe_ollama(url: str = "http://localhost:11434") -> bool:
    try:
        r = httpx.get(f"{url}/api/tags", timeout=2.0)
        return r.status_code == 200
    except (httpx.ConnectError, httpx.TimeoutException):
        return False


def create_llm(
    *,
    base_url: str | None = None,
    model: str | None = None,
    api_key: str | None = None,
) -> OpenAICompatLLM:
    """Create an LLM instance using explicit args or auto-detection."""

    # explicit config takes priority
    if base_url and model:
        return OpenAICompatLLM(
            base_url=base_url,
            model=model,
            api_key=api_key or "",
        )

    # try well-known cloud providers
    for env_key, default_url, default_model in _PROVIDERS:
        key = os.environ.get(env_key, "")
        if key:
            logger.info("Using %s backend (%s)", env_key, default_url)
            return OpenAICompatLLM(
                base_url=base_url or default_url,
                model=model or default_model,
                api_key=key,
            )

    # try local Ollama
    ollama_url = os.environ.get("OLLAMA_HOST", "http://localhost:11434")
    if _probe_ollama(ollama_url):
        logger.info("Using local Ollama at %s", ollama_url)
        return OpenAICompatLLM(
            base_url=f"{ollama_url}/v1",
            model=model or "qwen2.5:7b",
            api_key="",
        )

    raise RuntimeError(
        "No LLM backend found.\n"
        "Either:\n"
        "  1. Install and start Ollama: https://ollama.com\n"
        "  2. Set HARNESS_API_KEY / OPENAI_API_KEY / DASHSCOPE_API_KEY\n"
        "  3. Pass --base-url and --model explicitly"
    )


def create_llm_with_fallback(
    *,
    base_url: str | None = None,
    model: str | None = None,
    api_key: str | None = None,
) -> "OpenAICompatLLM | FallbackLLM":
    """Create an LLM with automatic fallback between Ollama and cloud API.

    If both Ollama and a cloud API key are available, returns a FallbackLLM
    that tries Ollama first and falls back to the cloud.
    """
    from harness.adapters.llm.fallback import FallbackLLM

    # explicit config — single backend
    if base_url and model:
        return OpenAICompatLLM(base_url=base_url, model=model, api_key=api_key or "")

    backends: list[OpenAICompatLLM] = []

    # try Ollama
    ollama_url = os.environ.get("OLLAMA_HOST", "http://localhost:11434")
    if _probe_ollama(ollama_url):
        backends.append(OpenAICompatLLM(
            base_url=f"{ollama_url}/v1",
            model=model or "qwen2.5:7b",
            api_key="",
        ))

    # try cloud providers
    for env_key, default_url, default_model in _PROVIDERS:
        key = os.environ.get(env_key, "")
        if key:
            backends.append(OpenAICompatLLM(
                base_url=default_url,
                model=default_model,
                api_key=key,
            ))
            break  # use first available cloud provider

    if not backends:
        raise RuntimeError(
            "No LLM backend found.\n"
            "Either:\n"
            "  1. Install and start Ollama: https://ollama.com\n"
            "  2. Set HARNESS_API_KEY / OPENAI_API_KEY / DASHSCOPE_API_KEY\n"
            "  3. Pass --base-url and --model explicitly"
        )

    if len(backends) == 1:
        return backends[0]

    logger.info("Using FallbackLLM: %s", " → ".join(f"{b.model}@{b.base_url}" for b in backends))
    return FallbackLLM(backends)
