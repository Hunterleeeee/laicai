"""Build Obsidian-friendly LLM wiki topic pages from vault notes."""

from __future__ import annotations

from collections.abc import Callable
import difflib
from dataclasses import dataclass
from pathlib import Path
import re

from harness.config import VaultConfig
from harness.core.types import Role, Turn
from harness.rag.index import VaultIndex
from harness.tools import WebFetcher, create_configured_web_fetcher
from harness.vault import VaultAdapter


@dataclass
class WikiSource:
    path: str
    title: str
    preview: str
    score: float = 0.0
    source_type: str = "vault"
    url: str | None = None


@dataclass
class WikiBuildResult:
    topic: str
    note_path: Path
    source_notes: list[str]
    web_sources: list[str]
    search_mode: str
    body: str
    rendered_markdown: str
    previous_markdown: str | None = None
    saved: bool = True


def obsidian_link(path: str | Path) -> str:
    raw = str(path).replace("\\", "/")
    if raw.endswith(".md"):
        raw = raw[:-3]
    return f"[[{raw}]]"


def _source_reference(source: WikiSource) -> str:
    if source.source_type == "web":
        target = source.url or source.path
        return f"[{source.title}]({target})"
    return obsidian_link(source.path)


def _extract_title(text: str, fallback: str) -> str:
    frontmatter_title = re.search(r'^title:\s*"?(.+?)"?\s*$', text, flags=re.MULTILINE)
    if frontmatter_title:
        return frontmatter_title.group(1).strip()
    heading = re.search(r'^#\s+(.+?)\s*$', text, flags=re.MULTILINE)
    if heading:
        return heading.group(1).strip()
    return fallback.replace("-", " ").strip() or fallback


def _sanitize_llm_body(text: str, topic: str) -> str:
    text = text.strip()
    if text.startswith("```"):
        text = re.sub(r"^```[a-zA-Z0-9_-]*\n", "", text)
        text = re.sub(r"\n```$", "", text)
    lines = text.splitlines()
    if lines and lines[0].strip().startswith("# "):
        lines = lines[1:]
    cleaned = "\n".join(lines).strip()
    if cleaned:
        return cleaned
    return _fallback_wiki_body(topic, [], "keyword")


def _render_source_context(sources: list[WikiSource]) -> str:
    if not sources:
        return "No relevant notes were found in the vault."
    blocks: list[str] = []
    for idx, source in enumerate(sources, start=1):
        if source.source_type == "web":
            blocks.append(
                f"[{idx}] {source.title} [web]\n"
                f"URL: {source.url or source.path}\n"
                f"Markdown link: {_source_reference(source)}\n"
                f"Snippet: {source.preview}"
            )
        else:
            blocks.append(
                f"[{idx}] {source.title} [vault]\n"
                f"Path: {source.path}\n"
                f"Obsidian link: {_source_reference(source)}\n"
                f"Snippet: {source.preview}"
            )
    return "\n\n".join(blocks)


def _fallback_wiki_body(topic: str, sources: list[WikiSource], search_mode: str) -> str:
    vault_sources = [source for source in sources if source.source_type == "vault"]
    web_sources = [source for source in sources if source.source_type == "web"]
    lines = [
        "## Summary",
        f"这是关于 **{topic}** 的初始 Wiki 草稿。当前通过 **{search_mode}** 检索整理而来。",
    ]
    if sources:
        lines.extend(["", "## Key Points"])
        for source in sources[:5]:
            lines.append(f"- {source.preview}")
    if vault_sources:
        lines.extend(["", "## Related Notes"])
        for source in vault_sources:
            lines.append(f"- {_source_reference(source)}")
    if web_sources:
        lines.extend(["", "## Web References"])
        for source in web_sources:
            lines.append(f"- {_source_reference(source)}")
    else:
        if not vault_sources:
            lines.extend(["", "## Notes", "- 当前 vault 里还没有足够相关的本地笔记。"])
    lines.extend(["", "## Open Questions", "- 还需要补充哪些来源或实验？"])
    return "\n".join(lines)


def wiki_diff(result: WikiBuildResult, *, context_lines: int = 2, max_lines: int = 120) -> str:
    if result.previous_markdown is None:
        return ""
    diff_lines = list(
        difflib.unified_diff(
            result.previous_markdown.splitlines(),
            result.rendered_markdown.splitlines(),
            fromfile="before",
            tofile="after",
            n=context_lines,
            lineterm="",
        )
    )
    if len(diff_lines) > max_lines:
        diff_lines = diff_lines[:max_lines] + ["..."]
    return "\n".join(diff_lines)


def save_wiki_result(result: WikiBuildResult) -> WikiBuildResult:
    result.note_path.parent.mkdir(parents=True, exist_ok=True)
    result.note_path.write_text(result.rendered_markdown, encoding="utf-8")
    result.saved = True
    return result


def _emit_progress(progress: Callable[[str], None] | None, step: int, total: int, message: str) -> None:
    if progress is not None:
        progress(f"Wiki {step}/{total} · {message}")


async def _collect_web_sources(
    topic: str,
    *,
    max_results: int = 3,
    web_fetcher: WebFetcher | None = None,
) -> list[WikiSource]:
    query = topic.strip()
    if not query:
        return []

    fetcher = web_fetcher or create_configured_web_fetcher()
    results = fetcher.research(query, max_results=max_results, text_limit=300)
    return [
        WikiSource(
            path=result.url,
            title=result.title,
            preview=result.snippet or result.title,
            source_type="web",
            url=result.url,
        )
        for result in results
    ]


async def _collect_sources(
    vault_root: Path,
    topic: str,
    *,
    top_k: int = 8,
    embedding_adapter=None,
) -> tuple[list[WikiSource], str]:
    if embedding_adapter is not None:
        try:
            from harness.rag.vector_index import VectorIndex

            vector_index = VectorIndex(vault_root)
            await vector_index.build(embedding_adapter)
            query_vec = await embedding_adapter.embed_one(topic)
            hits = vector_index.search(query_vec, top_k=top_k)
            if hits:
                sources: list[WikiSource] = []
                for hit in hits:
                    full_path = vault_root / hit.path
                    text = full_path.read_text(encoding="utf-8", errors="replace")
                    sources.append(
                        WikiSource(
                            path=hit.path,
                            title=_extract_title(text, Path(hit.path).stem),
                            preview=hit.preview,
                            score=hit.score,
                            source_type="vault",
                        )
                    )
                return sources, "semantic"
        except Exception:
            pass

    index = VaultIndex(vault_root)
    hits = index.search(topic, limit=top_k)
    sources = []
    for hit in hits:
        rel = str(hit.path.relative_to(vault_root)) if hit.path.is_absolute() else str(hit.path)
        try:
            text = hit.path.read_text(encoding="utf-8", errors="replace") if hit.path.is_absolute() else (vault_root / rel).read_text(encoding="utf-8", errors="replace")
        except OSError:
            text = hit.preview
        sources.append(
            WikiSource(
                path=rel,
                title=_extract_title(text, Path(rel).stem),
                preview=hit.preview,
                score=hit.score,
                source_type="vault",
            )
        )
    return sources, "keyword"


async def build_wiki_topic(
    *,
    llm,
    vault_root: Path,
    topic: str,
    top_k: int = 8,
    embedding_adapter=None,
    use_web: bool = False,
    web_max_results: int = 3,
    save: bool = True,
    web_fetcher: WebFetcher | None = None,
    progress: Callable[[str], None] | None = None,
) -> WikiBuildResult:
    total_steps = 3 + int(use_web) + int(save)
    step = 1

    _emit_progress(progress, step, total_steps, "Searching related vault notes...")
    vault_sources, search_mode = await _collect_sources(
        vault_root,
        topic,
        top_k=top_k,
        embedding_adapter=embedding_adapter,
    )
    step += 1

    web_sources: list[WikiSource] = []
    if use_web:
        _emit_progress(progress, step, total_steps, "Researching web sources...")
        try:
            if web_fetcher is None:
                web_sources = await _collect_web_sources(
                    topic,
                    max_results=web_max_results,
                )
            else:
                web_sources = await _collect_web_sources(
                    topic,
                    max_results=web_max_results,
                    web_fetcher=web_fetcher,
                )
        except Exception:
            web_sources = []
        step += 1

    sources = vault_sources + web_sources
    if web_sources:
        search_mode = f"{search_mode}+web"

    fallback_body = _fallback_wiki_body(topic, sources, search_mode)
    body = fallback_body

    _emit_progress(progress, step, total_steps, "Drafting wiki page...")
    step += 1

    prompt = (
        "为 Obsidian 生成一个个人 Wiki 主题页。要求：\n"
        "1. 只使用提供的笔记内容，不要编造。\n"
        "2. 返回纯 Markdown 正文，不要 YAML frontmatter，不要一级标题。\n"
        "3. 使用二级标题，如 ## Summary / ## Concepts / ## Related Notes / ## Web References / ## Open Questions。\n"
        "4. 引用本地笔记时使用 Obsidian wikilink，例如 [[03 Topics/topic-name]]。\n"
        "5. 引用网页来源时使用普通 Markdown 链接。\n"
        "6. 如果证据不足，要明确说明。\n\n"
        f"主题：{topic}\n\n"
        f"相关笔记：\n{_render_source_context(sources)}"
    )

    try:
        turn = await llm.complete(
            [
                Turn(role=Role.SYSTEM, content="You write concise, well-structured Obsidian wiki pages from local notes."),
                Turn(role=Role.USER, content=prompt),
            ],
            temperature=0.2,
            max_tokens=1600,
        )
        if turn.content.strip():
            body = _sanitize_llm_body(turn.content, topic)
    except Exception:
        body = fallback_body

    vault = VaultAdapter(VaultConfig(path=vault_root))
    frontmatter = {
        "type": "topic",
        "topic": topic,
        "tags": ["wiki", "topic"],
        "search_mode": search_mode,
        "source_count": len(vault_sources),
        "source_notes": [source.path for source in vault_sources],
        "web_source_count": len(web_sources),
        "web_sources": [source.url or source.path for source in web_sources],
    }
    _emit_progress(progress, step, total_steps, "Preparing wiki preview...")
    step += 1
    note_path, rendered_markdown = vault.render_topic_note(
        title=topic,
        body=body,
        frontmatter=frontmatter,
    )
    previous_markdown = note_path.read_text(encoding="utf-8") if note_path.exists() else None
    if save:
        _emit_progress(progress, step, total_steps, "Saving wiki page...")
        note = vault.upsert_topic_note(
            title=topic,
            body=body,
            frontmatter=frontmatter,
        )
        note_path = note.path
    return WikiBuildResult(
        topic=topic,
        note_path=note_path,
        source_notes=[source.path for source in vault_sources],
        web_sources=[source.url or source.path for source in web_sources],
        search_mode=search_mode,
        body=body,
        rendered_markdown=rendered_markdown,
        previous_markdown=previous_markdown,
        saved=save,
    )
