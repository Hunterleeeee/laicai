"""Async embedding adapter — works with Ollama or any OpenAI-compatible endpoint.

Usage:
    emb = EmbeddingAdapter(base_url="http://localhost:11434/v1", model="nomic-embed-text")
    vectors = await emb.embed(["hello world", "second text"])
"""

from __future__ import annotations

import logging
from typing import Sequence

import httpx

logger = logging.getLogger(__name__)


class EmbeddingAdapter:
    """Async embedding client using the OpenAI /embeddings endpoint."""

    def __init__(
        self,
        base_url: str = "http://localhost:11434/v1",
        model: str = "nomic-embed-text",
        api_key: str = "",
        timeout: float = 30.0,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.api_key = api_key
        self.timeout = timeout
        self._client: httpx.AsyncClient | None = None

    async def _get_client(self) -> httpx.AsyncClient:
        if self._client is None or self._client.is_closed:
            headers = {"Content-Type": "application/json"}
            if self.api_key:
                headers["Authorization"] = f"Bearer {self.api_key}"
            self._client = httpx.AsyncClient(
                base_url=self.base_url,
                headers=headers,
                timeout=self.timeout,
            )
        return self._client

    async def embed(self, texts: Sequence[str]) -> list[list[float]]:
        """Embed a batch of texts. Returns list of float vectors."""
        if not texts:
            return []
        client = await self._get_client()
        body = {
            "model": self.model,
            "input": list(texts),
        }
        resp = await client.post("/embeddings", json=body)
        resp.raise_for_status()
        data = resp.json()
        # sort by index in case API returns unordered
        items = sorted(data["data"], key=lambda x: x["index"])
        return [item["embedding"] for item in items]

    async def embed_one(self, text: str) -> list[float]:
        """Embed a single text."""
        results = await self.embed([text])
        return results[0]

    async def close(self) -> None:
        if self._client and not self._client.is_closed:
            await self._client.aclose()


def create_embedding_adapter(
    base_url: str | None = None,
    model: str | None = None,
    api_key: str | None = None,
) -> EmbeddingAdapter | None:
    """Try to create an embedding adapter. Returns None if not available."""
    import os

    # explicit
    if base_url and model:
        return EmbeddingAdapter(base_url=base_url, model=model, api_key=api_key or "")

    # try Ollama
    ollama_url = os.environ.get("OLLAMA_HOST", "http://localhost:11434")
    try:
        r = httpx.get(f"{ollama_url}/api/tags", timeout=2.0)
        if r.status_code == 200:
            return EmbeddingAdapter(
                base_url=f"{ollama_url}/v1",
                model=model or "nomic-embed-text",
                api_key="",
            )
    except (httpx.ConnectError, httpx.TimeoutException):
        pass

    # try OpenAI
    for env_key, default_url, default_model in [
        ("OPENAI_API_KEY", "https://api.openai.com/v1", "text-embedding-3-small"),
        ("DASHSCOPE_API_KEY", "https://dashscope.aliyuncs.com/compatible-mode/v1", "text-embedding-v3"),
    ]:
        key = os.environ.get(env_key, "")
        if key:
            return EmbeddingAdapter(
                base_url=default_url,
                model=default_model,
                api_key=key,
            )

    return None
