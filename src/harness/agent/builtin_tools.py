"""Built-in tools available to the agent out of the box."""

from __future__ import annotations

import logging
import asyncio
from pathlib import Path
from typing import Any

from harness.agent.tools import SimpleToolRegistry
from harness.config import ImageGenerationConfig
from harness.core.types import ToolParam
from harness.tools.comfyui import ComfyUIImageGenerator, view_url
from harness.tools import WebFetcher, create_configured_web_fetcher

logger = logging.getLogger(__name__)

# VaultIndex singleton cache per vault root
_vault_index_cache: dict[str, Any] = {}
# Vector index singleton
_vector_index_cache: dict[str, Any] = {}
# Embedding adapter singleton
_embedding_adapter: Any = None
# Prepared wiki preview cache
_wiki_preview_cache: dict[str, Any] = {}


def _get_vault_index(vault_root: Path) -> Any:
    """Return a cached VaultIndex for the given vault root."""
    key = str(vault_root)
    if key not in _vault_index_cache:
        from harness.rag.index import VaultIndex
        _vault_index_cache[key] = VaultIndex(vault_root)
    return _vault_index_cache[key]


def _wiki_preview_key(vault_root: Path, topic: str, top_k: int, use_web: bool, web_max_results: int) -> str:
    return f"{vault_root}::{topic.strip().lower()}::{top_k}::{int(use_web)}::{web_max_results}"


def register_builtins(
    registry: SimpleToolRegistry,
    *,
    vault_root: Path | None = None,
    web_enabled: bool = True,
    learning_enabled: bool = True,
    image_generation: ImageGenerationConfig | None = None,
    embedding_adapter: Any = None,
    llm: Any = None,
    web_fetcher: WebFetcher | None = None,
    wiki_progress: Any = None,
) -> None:
    """Register all built-in tools onto the given registry."""
    global _embedding_adapter
    if embedding_adapter is not None:
        _embedding_adapter = embedding_adapter

    shared_web_fetcher = web_fetcher
    if shared_web_fetcher is None and (web_enabled or llm is not None):
        shared_web_fetcher = create_configured_web_fetcher()

    if vault_root:
        _register_vault_tools(
            registry,
            vault_root,
            llm=llm,
            web_fetcher=shared_web_fetcher,
            wiki_progress=wiki_progress,
        )
    _register_code_tools(registry)
    if web_enabled:
        _register_web_tools(registry, shared_web_fetcher)
    if image_generation is not None and image_generation.enabled:
        _register_image_tools(registry, image_generation)
    if learning_enabled:
        from harness.agent.learning_tools import register_learning_tools
        register_learning_tools(registry, vault_root=vault_root)


# ── Vault Tools ────────────────────────────────────────────────

def _register_vault_tools(
    registry: SimpleToolRegistry,
    vault_root: Path,
    *,
    llm: Any = None,
    web_fetcher: WebFetcher | None = None,
    wiki_progress: Any = None,
) -> None:

    def _emit_wiki_progress(message: str) -> None:
        if wiki_progress is not None:
            wiki_progress(message)

    @registry.tool(
        name="vault_search",
        description="Search notes in the knowledge vault. Uses semantic search if available, falls back to keyword.",
        parameters=[
            ToolParam(name="query", description="Search query"),
            ToolParam(name="top_k", type="integer", description="Max results", required=False),
        ],
    )
    async def vault_search(query: str, top_k: int = 5) -> str:
        # try semantic search first
        if _embedding_adapter is not None:
            try:
                return await _semantic_vault_search(vault_root, query, top_k)
            except Exception as exc:
                logger.debug("Semantic search failed, falling back to keyword: %s", exc)

        # keyword fallback
        index = _get_vault_index(vault_root)
        hits = index.search(query, limit=top_k)
        if not hits:
            return "No matching notes found."
        lines = []
        for h in hits:
            lines.append(f"**{h.path}** (score: {h.score:.2f})\n{h.preview[:200]}")
        return "\n---\n".join(lines)

    @registry.tool(
        name="save_note",
        description="Save text content as a new note in the vault.",
        parameters=[
            ToolParam(name="title", description="Note title"),
            ToolParam(name="content", description="Markdown content to save"),
            ToolParam(name="folder", description="Subfolder in vault", required=False),
        ],
    )
    async def save_note(title: str, content: str, folder: str = "") -> str:
        target_dir = vault_root / folder if folder else vault_root
        target_dir.mkdir(parents=True, exist_ok=True)
        # simple slugify
        slug = title.lower().replace(" ", "-")
        for ch in "!@#$%^&*()+=[]{}|\\:;\"'<>,?/":
            slug = slug.replace(ch, "")
        path = target_dir / f"{slug}.md"
        path.write_text(content, encoding="utf-8")
        return f"Saved to {path.relative_to(vault_root)}"

    @registry.tool(
        name="list_notes",
        description="List note filenames in the vault, optionally filtered by folder.",
        parameters=[
            ToolParam(name="folder", description="Subfolder to list", required=False),
            ToolParam(name="limit", type="integer", description="Max notes to list", required=False),
        ],
    )
    async def list_notes(folder: str = "", limit: int = 20) -> str:
        target = vault_root / folder if folder else vault_root
        if not target.exists():
            return f"Folder not found: {folder}"
        files = sorted(target.rglob("*.md"))[:limit]
        if not files:
            return "No notes found."
        return "\n".join(str(f.relative_to(vault_root)) for f in files)

    @registry.tool(
        name="read_note",
        description="Read the full content of a specific note.",
        parameters=[
            ToolParam(name="path", description="Relative path to the note in the vault"),
        ],
    )
    async def read_note(path: str) -> str:
        target = vault_root / path
        if not target.exists():
            return f"Note not found: {path}"
        return target.read_text(encoding="utf-8")[:8000]

    if llm is not None:
        @registry.tool(
            name="wiki_build_page",
            description="Prepare or save an Obsidian wiki topic page from vault notes and optional automatic web research. Preview first by default; set save=true only after the user clearly wants to write the page.",
            parameters=[
                ToolParam(name="topic", description="Topic name for the wiki page"),
                ToolParam(name="top_k", type="integer", description="Max related notes to use", required=False),
                ToolParam(name="use_web", type="boolean", description="Whether to automatically search the web for supplemental knowledge", required=False),
                ToolParam(name="web_max_results", type="integer", description="Max web pages to fetch for the wiki page", required=False),
                ToolParam(name="save", type="boolean", description="Whether to actually write the generated wiki page into the vault", required=False),
            ],
        )
        async def wiki_build_page(topic: str, top_k: int = 8, use_web: bool = True, web_max_results: int = 3, save: bool = False) -> str:
            from harness.wiki import build_wiki_topic, obsidian_link, save_wiki_result, wiki_diff

            cache_key = _wiki_preview_key(vault_root, topic, top_k, use_web, web_max_results)
            result = _wiki_preview_cache.get(cache_key) if save else None

            if result is None:
                result = await build_wiki_topic(
                    llm=llm,
                    vault_root=vault_root,
                    topic=topic,
                    top_k=top_k,
                    embedding_adapter=_embedding_adapter,
                    use_web=use_web,
                    web_max_results=web_max_results,
                    save=False,
                    web_fetcher=web_fetcher,
                    progress=_emit_wiki_progress,
                )
            if save:
                _emit_wiki_progress("Wiki 1/1 · Saving wiki page...")
                save_wiki_result(result)
                _wiki_preview_cache.pop(cache_key, None)
            else:
                _wiki_preview_cache[cache_key] = result
            lines = [
                f"{'Built' if result.saved else 'Prepared'} wiki page for **{topic}**.",
                f"Target path: {result.note_path.relative_to(vault_root)}",
                f"Search mode: {result.search_mode}",
            ]
            if result.previous_markdown is None:
                lines.append("Change type: new page")
            else:
                lines.append("Change type: update")
            if result.source_notes:
                lines.append("Source notes:")
                for note in result.source_notes:
                    lines.append(f"- {obsidian_link(note)}")
            else:
                lines.append("Source notes: none found")
            if result.web_sources:
                lines.append("Web sources:")
                for source in result.web_sources:
                    lines.append(f"- {source}")
            diff = wiki_diff(result)
            if diff:
                lines.append("Diff:")
                lines.append("```diff\n" + diff + "\n```")
            elif result.previous_markdown is not None:
                lines.append("Diff: no content changes")
            if result.saved:
                lines.append(f"Saved to: {result.note_path.relative_to(vault_root)}")
            else:
                lines.append("Preview only. Call again with `save=true` to write it.")
            return "\n".join(lines)


# ── Semantic search helper ────────────────────────────────────

async def _semantic_vault_search(vault_root: Path, query: str, top_k: int = 5) -> str:
    """Semantic vault search using embedding adapter + vector index."""
    from harness.rag.vector_index import VectorIndex

    key = str(vault_root)
    if key not in _vector_index_cache:
        vi = VectorIndex(vault_root)
        count = await vi.build(_embedding_adapter)
        logger.info("Built vector index for %s: %d notes", vault_root, count)
        _vector_index_cache[key] = vi
    vi = _vector_index_cache[key]

    query_vec = await _embedding_adapter.embed_one(query)
    hits = vi.search(query_vec, top_k=top_k)
    if not hits:
        return "No matching notes found."
    lines = []
    for h in hits:
        lines.append(f"**{h.path}** (score: {h.score:.4f})\n{h.preview[:200]}")
    return "\n---\n".join(lines)


# ── Web Tools ──────────────────────────────────────────────────

def _register_web_tools(registry: SimpleToolRegistry, web_fetcher: WebFetcher | None = None) -> None:
    fetcher = web_fetcher or create_configured_web_fetcher()

    @registry.tool(
        name="web_fetch",
        description="Fetch a web page and return its text content (no JS rendering).",
        parameters=[
            ToolParam(name="url", description="URL to fetch"),
        ],
    )
    async def web_fetch(url: str) -> str:
        try:
            page = fetcher.fetch(url, use_browser=False, text_limit=6000)
            return page.text[:6000]
        except RuntimeError as exc:
            return f"Fetch failed: {exc}"

    @registry.tool(
        name="web_search",
        description="Search the web using DuckDuckGo and return top results.",
        parameters=[
            ToolParam(name="query", description="Search query"),
            ToolParam(name="max_results", type="integer", description="Max results", required=False),
        ],
    )
    async def web_search(query: str, max_results: int = 5) -> str:
        try:
            results = fetcher.search(query, max_results=max_results)
            if not results:
                return "No results found."
            return "\n".join(f"- [{result.title}]({result.url})" for result in results)
        except RuntimeError as exc:
            return f"Search failed: {exc}"


# ── Code Execution Tools ───────────────────────────────────────

def _register_code_tools(registry: SimpleToolRegistry) -> None:
    """Register the Python code execution tool."""

    @registry.tool(
        name="python_execute",
        description="Execute Python code safely in a sandbox. Use for calculations, data processing, algorithm prototyping, and verifying code. Returns stdout, stderr, and execution time.",
        parameters=[
            ToolParam(name="code", description="Python source code to execute"),
            ToolParam(name="timeout", type="integer", description="Max seconds to run (default 30)", required=False),
        ],
    )
    async def python_execute(code: str, timeout: int = 30) -> str:
        from harness.agent.code_runner import run_python
        result = await run_python(code, timeout=timeout)
        lines = []
        if result.get("stdout"):
            lines.append("**Output:**\n```\n" + result["stdout"] + "\n```")
        if result.get("stderr"):
            lines.append("**Stderr:**\n```\n" + result["stderr"] + "\n```")
        if result.get("error"):
            lines.append(f"**Error:** {result['error']}")
        if result.get("ok") and not any([result.get("stdout"), result.get("stderr"), result.get("error")]):
            lines.append("Execution completed successfully (no output).")
        if result.get("elapsed"):
            lines.append(f"*Elapsed: {result['elapsed']}s*")
        return "\n\n".join(lines)


def _register_image_tools(registry: SimpleToolRegistry, config: ImageGenerationConfig) -> None:
    generator = ComfyUIImageGenerator(config)

    @registry.tool(
        name="generate_image",
        description="Generate an image locally with ComfyUI/Qwen-Image and return the saved file path. Use when the user asks to create, draw, render, or generate an image.",
        parameters=[
            ToolParam(name="prompt", description="Detailed image prompt. Include subject, style, lighting, composition, and any text that should appear."),
            ToolParam(name="negative_prompt", description="Things to avoid in the image", required=False),
            ToolParam(name="width", type="integer", description="Image width in pixels. Default is configured value.", required=False),
            ToolParam(name="height", type="integer", description="Image height in pixels. Default is configured value.", required=False),
            ToolParam(name="steps", type="integer", description="Sampling steps. Default is configured value.", required=False),
            ToolParam(name="seed", type="integer", description="Optional deterministic seed.", required=False),
        ],
    )
    async def generate_image(
        prompt: str,
        negative_prompt: str = "",
        width: int = 0,
        height: int = 0,
        steps: int = 0,
        seed: int = 0,
    ) -> str:
        image_path = await asyncio.to_thread(
            generator.generate,
            prompt,
            negative_prompt=negative_prompt,
            width=width or None,
            height=height or None,
            steps=steps or None,
            seed=seed or None,
        )
        lines = [
            "Generated image locally with ComfyUI.",
            f"Path: {image_path}",
        ]
        if image_path.exists():
            lines.append(f"Preview: {view_url(config.endpoint, image_path)}")
        return "\n".join(lines)
