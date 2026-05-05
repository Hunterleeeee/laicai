from __future__ import annotations

from pathlib import Path

import pytest

import harness.wiki as wiki_module
from harness.agent.builtin_tools import register_builtins
from harness.agent.tools import SimpleToolRegistry
from harness.core.types import Role, Turn
from harness.wiki import WikiSource, build_wiki_topic, obsidian_link, save_wiki_result, wiki_diff


class WikiMockLLM:
    model = "mock-wiki"
    base_url = "http://mock"

    async def complete(self, messages, **kwargs):
        return Turn(
            role=Role.ASSISTANT,
            content=(
                "## Summary\n"
                "Python 是一种通用编程语言。\n\n"
                "## Related Notes\n"
                "- [[02 Notes/python-intro]]"
            ),
        )

    async def stream(self, messages, **kwargs):
        raise NotImplementedError
        yield

    async def close(self):
        pass


class FailingWikiLLM:
    model = "mock-fail"
    base_url = "http://mock"

    async def complete(self, messages, **kwargs):
        raise RuntimeError("llm unavailable")

    async def stream(self, messages, **kwargs):
        raise NotImplementedError
        yield

    async def close(self):
        pass


@pytest.mark.asyncio
async def test_build_wiki_topic_creates_topic_note(tmp_path: Path):
    notes_dir = tmp_path / "02 Notes"
    notes_dir.mkdir(parents=True)
    note = notes_dir / "python-intro.md"
    note.write_text(
        "---\ntitle: \"Python Intro\"\n---\n\n# Python Intro\n\nPython is a versatile programming language.",
        encoding="utf-8",
    )

    result = await build_wiki_topic(
        llm=WikiMockLLM(),
        vault_root=tmp_path,
        topic="Python",
        top_k=5,
    )

    assert result.note_path.exists()
    assert result.note_path.name == "python.md"
    content = result.note_path.read_text(encoding="utf-8")
    assert 'type: "topic"' in content
    assert 'topic: "Python"' in content
    assert "## Summary" in content
    assert "[[02 Notes/python-intro]]" in content
    assert result.source_notes == ["02 Notes/python-intro.md"]
    assert result.saved is True
    assert result.previous_markdown is None


@pytest.mark.asyncio
async def test_wiki_tool_registered_and_callable(tmp_path: Path):
    notes_dir = tmp_path / "02 Notes"
    notes_dir.mkdir(parents=True)
    (notes_dir / "python-intro.md").write_text(
        "# Python Intro\nPython is a versatile programming language.",
        encoding="utf-8",
    )

    registry = SimpleToolRegistry()
    register_builtins(
        registry,
        vault_root=tmp_path,
        web_enabled=False,
        learning_enabled=False,
        llm=WikiMockLLM(),
    )

    tools = registry.list_tools()
    assert any(t.name == "wiki_build_page" for t in tools)

    result = await registry.call("wiki_build_page", {"topic": "Python"})
    assert result.success is True
    assert "Prepared wiki page for **Python**." in result.content
    assert "Preview only. Call again with `save=true` to write it." in result.content
    assert "python.md" in result.content

    saved = await registry.call("wiki_build_page", {"topic": "Python", "save": True})
    assert saved.success is True
    assert "Built wiki page for **Python**." in saved.content
    assert "Saved to: 03 Topics/python.md" in saved.content


@pytest.mark.asyncio
async def test_wiki_tool_emits_progress_updates(tmp_path: Path):
    notes_dir = tmp_path / "02 Notes"
    notes_dir.mkdir(parents=True)
    (notes_dir / "python-intro.md").write_text(
        "# Python Intro\nPython is a versatile programming language.",
        encoding="utf-8",
    )

    progress_messages: list[str] = []
    registry = SimpleToolRegistry()
    register_builtins(
        registry,
        vault_root=tmp_path,
        web_enabled=False,
        learning_enabled=False,
        llm=WikiMockLLM(),
        wiki_progress=progress_messages.append,
    )

    preview = await registry.call("wiki_build_page", {"topic": "Python", "use_web": False})
    saved = await registry.call("wiki_build_page", {"topic": "Python", "use_web": False, "save": True})

    assert preview.success is True
    assert saved.success is True
    assert progress_messages[:3] == [
        "Wiki 1/3 · Searching related vault notes...",
        "Wiki 2/3 · Drafting wiki page...",
        "Wiki 3/3 · Preparing wiki preview...",
    ]
    assert progress_messages[-1] == "Wiki 1/1 · Saving wiki page..."


@pytest.mark.asyncio
async def test_build_wiki_topic_with_web_sources(tmp_path: Path, monkeypatch):
    notes_dir = tmp_path / "02 Notes"
    notes_dir.mkdir(parents=True)
    (notes_dir / "python-intro.md").write_text(
        "# Python Intro\nPython is a versatile programming language.",
        encoding="utf-8",
    )

    async def fake_collect_web_sources(topic: str, *, max_results: int = 3):
        return [
            WikiSource(
                path="https://example.com/python",
                title="Python Reference",
                preview="Official and community resources about Python.",
                source_type="web",
                url="https://example.com/python",
            )
        ]

    monkeypatch.setattr(wiki_module, "_collect_web_sources", fake_collect_web_sources)

    result = await build_wiki_topic(
        llm=FailingWikiLLM(),
        vault_root=tmp_path,
        topic="Python",
        top_k=5,
        use_web=True,
        web_max_results=1,
    )

    assert result.search_mode.endswith("+web")
    assert result.web_sources == ["https://example.com/python"]
    content = result.note_path.read_text(encoding="utf-8")
    assert 'web_source_count: "1"' in content
    assert "## Web References" in content
    assert "[Python Reference](https://example.com/python)" in content


@pytest.mark.asyncio
async def test_build_wiki_topic_reports_progress(tmp_path: Path, monkeypatch):
    notes_dir = tmp_path / "02 Notes"
    notes_dir.mkdir(parents=True)
    (notes_dir / "python-intro.md").write_text(
        "# Python Intro\nPython is a versatile programming language.",
        encoding="utf-8",
    )

    async def fake_collect_web_sources(topic: str, *, max_results: int = 3):
        return [
            WikiSource(
                path="https://example.com/python",
                title="Python Reference",
                preview="Official and community resources about Python.",
                source_type="web",
                url="https://example.com/python",
            )
        ]

    monkeypatch.setattr(wiki_module, "_collect_web_sources", fake_collect_web_sources)

    progress_messages: list[str] = []
    result = await build_wiki_topic(
        llm=FailingWikiLLM(),
        vault_root=tmp_path,
        topic="Python",
        top_k=5,
        use_web=True,
        web_max_results=1,
        save=False,
        progress=progress_messages.append,
    )

    assert result.saved is False
    assert progress_messages == [
        "Wiki 1/4 · Searching related vault notes...",
        "Wiki 2/4 · Researching web sources...",
        "Wiki 3/4 · Drafting wiki page...",
        "Wiki 4/4 · Preparing wiki preview...",
    ]


@pytest.mark.asyncio
async def test_build_wiki_topic_preview_does_not_write_until_saved(tmp_path: Path):
    notes_dir = tmp_path / "02 Notes"
    notes_dir.mkdir(parents=True)
    (notes_dir / "python-intro.md").write_text(
        "# Python Intro\nPython is a versatile programming language.",
        encoding="utf-8",
    )

    result = await build_wiki_topic(
        llm=WikiMockLLM(),
        vault_root=tmp_path,
        topic="Python",
        top_k=5,
        save=False,
    )

    assert result.saved is False
    assert not result.note_path.exists()
    assert result.rendered_markdown.startswith("---\n")
    assert wiki_diff(result) == ""

    save_wiki_result(result)
    assert result.saved is True
    assert result.note_path.exists()


@pytest.mark.asyncio
async def test_build_wiki_topic_preview_tracks_previous_markdown(tmp_path: Path):
    topic_path = tmp_path / "03 Topics"
    topic_path.mkdir(parents=True)
    existing = topic_path / "python.md"
    existing.write_text("---\ntitle: \"Python\"\n---\n\n# Python\n\nOld body\n", encoding="utf-8")

    notes_dir = tmp_path / "02 Notes"
    notes_dir.mkdir(parents=True)
    (notes_dir / "python-intro.md").write_text(
        "# Python Intro\nPython is a versatile programming language.",
        encoding="utf-8",
    )

    result = await build_wiki_topic(
        llm=WikiMockLLM(),
        vault_root=tmp_path,
        topic="Python",
        top_k=5,
        save=False,
    )

    assert result.previous_markdown is not None
    diff = wiki_diff(result)
    assert diff
    assert "--- before" in diff
    assert "+++ after" in diff


def test_obsidian_link_renders_relative_markdown_path():
    assert obsidian_link("02 Notes/python-intro.md") == "[[02 Notes/python-intro]]"
    assert obsidian_link("03 Topics/python.md") == "[[03 Topics/python]]"
