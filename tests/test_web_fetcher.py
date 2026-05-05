from __future__ import annotations

from pathlib import Path

import pytest

from harness.agent.builtin_tools import register_builtins
from harness.agent.tools import SimpleToolRegistry
from harness.config import WebConfig
from harness.core.types import Role, Turn
from harness.tools import FetchedPage, WebFetcher, WebSearchResult
import harness.tools.web as web_module


class _FakeResponse:
    def __init__(self, text: str) -> None:
        self._payload = text.encode("utf-8")

    def read(self) -> bytes:
        return self._payload

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb) -> bool:
        return False


def test_web_fetcher_search_parses_duckduckgo_results(monkeypatch, tmp_path: Path):
    html = (
        '<a rel="nofollow" class="result__a" '
        'href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpython">'
        'Python &amp; Reference</a>'
    )

    def fake_urlopen(request, timeout=0):
        assert request.full_url == "https://html.duckduckgo.com/html/"
        return _FakeResponse(html)

    monkeypatch.setattr(web_module, "urlopen", fake_urlopen)

    fetcher = WebFetcher(WebConfig(browser_enabled=False), workspace_root=tmp_path)
    results = fetcher.search("Python", max_results=1)

    assert len(results) == 1
    assert results[0].title == "Python & Reference"
    assert results[0].url == "https://example.com/python"


def test_web_fetcher_research_enriches_results(monkeypatch, tmp_path: Path):
    fetcher = WebFetcher(WebConfig(browser_enabled=False), workspace_root=tmp_path)

    monkeypatch.setattr(
        fetcher,
        "search",
        lambda query, max_results=5: [WebSearchResult(title="Python", url="https://example.com/python")],
    )
    monkeypatch.setattr(
        fetcher,
        "fetch",
        lambda url, use_browser=None, text_limit=None: FetchedPage(
            url=url,
            title="Python Article",
            text="Python article body with practical notes.",
        ),
    )

    results = fetcher.research("Python", max_results=1, text_limit=20)

    assert len(results) == 1
    assert results[0].title == "Python Article"
    assert results[0].snippet == "Python article body"


class _WikiFallbackLLM:
    model = "mock-web"
    base_url = "http://mock"

    async def complete(self, messages, **kwargs):
        raise RuntimeError("llm unavailable")

    async def stream(self, messages, **kwargs):
        raise NotImplementedError
        yield

    async def close(self):
        pass


class _FakeWebFetcher:
    def __init__(self) -> None:
        self.search_calls: list[tuple[str, int]] = []
        self.fetch_calls: list[tuple[str, bool | None, int | None]] = []
        self.research_calls: list[tuple[str, int, int, bool | None]] = []

    def search(self, query: str, *, max_results: int = 5) -> list[WebSearchResult]:
        self.search_calls.append((query, max_results))
        return [WebSearchResult(title="Python Docs", url="https://example.com/python")]

    def fetch(
        self,
        url: str,
        *,
        use_browser: bool | None = None,
        wait_for: str | None = None,
        text_limit: int | None = None,
    ) -> FetchedPage:
        self.fetch_calls.append((url, use_browser, text_limit))
        return FetchedPage(url=url, title="Python Docs", text="Python docs body")

    def research(
        self,
        query: str,
        *,
        max_results: int = 3,
        text_limit: int = 300,
        use_browser: bool | None = None,
    ) -> list[WebSearchResult]:
        self.research_calls.append((query, max_results, text_limit, use_browser))
        return [WebSearchResult(title="Python Docs", url="https://example.com/python", snippet="Python docs body")]


@pytest.mark.asyncio
async def test_register_builtins_shares_web_fetcher_across_tools(tmp_path: Path):
    notes_dir = tmp_path / "02 Notes"
    notes_dir.mkdir(parents=True)
    (notes_dir / "python-intro.md").write_text("# Python\nPython is versatile.", encoding="utf-8")

    registry = SimpleToolRegistry()
    fetcher = _FakeWebFetcher()
    register_builtins(
        registry,
        vault_root=tmp_path,
        web_enabled=True,
        learning_enabled=False,
        llm=_WikiFallbackLLM(),
        web_fetcher=fetcher,
    )

    search_result = await registry.call("web_search", {"query": "Python", "max_results": 1})
    fetch_result = await registry.call("web_fetch", {"url": "https://example.com/python"})
    wiki_result = await registry.call("wiki_build_page", {"topic": "Python", "use_web": True})

    assert search_result.success is True
    assert "[Python Docs](https://example.com/python)" in search_result.content
    assert fetch_result.success is True
    assert "Python docs body" in fetch_result.content
    assert wiki_result.success is True
    assert "https://example.com/python" in wiki_result.content
    assert fetcher.search_calls == [("Python", 1)]
    assert fetcher.fetch_calls == [("https://example.com/python", False, 6000)]
    assert fetcher.research_calls == [("Python", 3, 300, None)]
