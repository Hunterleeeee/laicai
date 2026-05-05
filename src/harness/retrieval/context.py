"""自动上下文装配与可解释性检索。

为 Agent 提供跨源（vault、历史会话、wiki、收藏）的上下文召回，
并生成可展示的来源说明（provenance）。
"""
from __future__ import annotations

import asyncio
import math
import re
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from harness.core.types import Turn, Role

_thread_pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="semantic_search")


@dataclass
class ContextSnippet:
    """单条上下文片段，带可追溯的来源信息。"""

    kind: str
    content: str
    source_id: str = ""
    source_title: str = ""
    source_path: str | None = None
    score: float = 0.0
    confidence: str = "medium"
    provenance: str = ""


@dataclass
class ContextBundle:
    """一次查询召回的完整上下文包。"""

    query: str = ""
    snippets: list[ContextSnippet] = field(default_factory=list)
    total_tokens: int = 0
    source_counts: dict[str, int] = field(default_factory=dict)

    def as_prompt_block(self, max_chars: int = 2800) -> str:
        """将上下文打包成适合注入系统提示的文本块。"""
        if not self.snippets:
            return ""
        lines: list[str] = []
        lines.append("## Relevant Context")
        used = 0
        for snippet in sorted(self.snippets, key=lambda s: s.score, reverse=True):
            entry = f"[{snippet.kind}] {snippet.source_title}\n{snippet.content}"
            if used + len(entry) > max_chars and used > 0:
                break
            lines.append(entry)
            used += len(entry)
        if len(lines) > 1:
            lines.append("## End Context")
        return "\n\n".join(lines)

    def to_payload(self) -> dict[str, Any]:
        """序列化为前端可展示的 JSON。"""
        return {
            "query": self.query,
            "total_tokens": self.total_tokens,
            "source_counts": dict(self.source_counts),
            "snippets": [
                {
                    "kind": s.kind,
                    "source_id": s.source_id,
                    "source_title": s.source_title,
                    "source_path": s.source_path,
                    "score": round(s.score, 3),
                    "confidence": s.confidence,
                    "provenance": s.provenance,
                    "preview": _collapse_text(s.content, 240),
                }
                for s in self.snippets
            ],
        }


class ContextAssembler:
    """从 vault、历史会话、收藏、wiki 等来源装配上下文。"""

    def __init__(
        self,
        *,
        vault_root: Path | None = None,
        session_store: Any | None = None,
        embedding_adapter: Any | None = None,
        web_fetcher: Any | None = None,
    ) -> None:
        self.vault_root = vault_root
        self.session_store = session_store
        self.embedding_adapter = embedding_adapter
        self.web_fetcher = web_fetcher
        self._vault_index_cache: dict[str, Any] = {}

    def assemble(self, query: str, *, current_session_id: str | None = None, max_snippets: int = 8) -> ContextBundle:
        """同步装配上下文。优先从本地存储召回。"""
        bundle = ContextBundle(query=query)
        all_hits: list[tuple[float, ContextSnippet]] = []

        # 1. Vault notes (keyword)
        if self.vault_root and self.vault_root.exists():
            hits = self._search_vault_keyword(query)
            for h in hits:
                all_hits.append((h.score, h))

        # 2. Recent sessions (keyword in turns + metadata)
        if self.session_store is not None:
            hits = self._search_sessions_keyword(query, exclude_session_id=current_session_id)
            for h in hits:
                all_hits.append((h.score, h))

        # 3. Semantic vault search (if embedding available)
        if self.embedding_adapter is not None and self.vault_root:
            try:
                hits = self._search_vault_semantic_sync(query)
                for h in hits:
                    all_hits.append((h.score, h))
            except Exception:
                pass

        # 4. Starred messages from current session (if available via metadata)
        # handled inside _search_sessions_keyword by scanning metadata

        # Deduplicate by source_id + first 60 chars of content
        seen: set[str] = set()
        deduped: list[tuple[float, ContextSnippet]] = []
        for score, snippet in sorted(all_hits, key=lambda x: x[0], reverse=True):
            key = f"{snippet.source_id}:{snippet.content[:60]}"
            if key in seen:
                continue
            seen.add(key)
            deduped.append((score, snippet))

        # Take top N
        for score, snippet in deduped[:max_snippets]:
            bundle.snippets.append(snippet)
            bundle.source_counts[snippet.kind] = bundle.source_counts.get(snippet.kind, 0) + 1

        # Rough token estimate (4 chars per token conservative)
        bundle.total_tokens = sum(max(1, len(s.content) // 4) for s in bundle.snippets)
        return bundle

    def _search_vault_keyword(self, query: str, limit: int = 5) -> list[ContextSnippet]:
        from harness.rag.index import VaultIndex

        if not self.vault_root:
            return []
        key = str(self.vault_root)
        index = self._vault_index_cache.get(key)
        if index is None:
            index = VaultIndex(self.vault_root)
            self._vault_index_cache[key] = index
        docs = index.search(query, limit=limit)
        snippets: list[ContextSnippet] = []
        for doc in docs:
            score = float(doc.score)
            # normalize score roughly to 0..100
            normalized = min(100.0, max(0.0, score))
            confidence = "high" if normalized >= 50 else "medium" if normalized >= 20 else "low"
            snippets.append(
                ContextSnippet(
                    kind="vault_note",
                    content=doc.preview,
                    source_id=str(doc.path),
                    source_title=Path(doc.path).name,
                    source_path=str(doc.path),
                    score=normalized,
                    confidence=confidence,
                    provenance=f"Vault keyword search: {query}",
                )
            )
        return snippets

    async def _search_vault_semantic(self, query: str, limit: int = 5) -> list[ContextSnippet]:
        from harness.rag.vector_index import VectorIndex

        if not self.vault_root or not self.embedding_adapter:
            return []
        vi = VectorIndex(self.vault_root)
        try:
            count = await vi.build(self.embedding_adapter)
            if count == 0:
                return []
        except Exception:
            return []
        query_vec = await self.embedding_adapter.embed_one(query)
        hits = vi.search(query_vec, top_k=limit)
        snippets: list[ContextSnippet] = []
        for h in hits:
            # cosine similarity -> 0..1, scale to 0..100
            normalized = min(100.0, max(0.0, h.score * 100))
            confidence = "high" if normalized >= 75 else "medium" if normalized >= 50 else "low"
            snippets.append(
                ContextSnippet(
                    kind="vault_semantic",
                    content=h.preview,
                    source_id=h.path,
                    source_title=Path(h.path).name,
                    source_path=h.path,
                    score=normalized,
                    confidence=confidence,
                    provenance=f"Vault semantic search: {query}",
                )
            )
        return snippets

    def _search_vault_semantic_sync(self, query: str, limit: int = 5) -> list[ContextSnippet]:
        """同步调用异步语义检索，使用线程池避免事件循环冲突。"""
        try:
            future = _thread_pool.submit(
                asyncio.run,
                self._search_vault_semantic(query, limit=limit)
            )
            return future.result(timeout=10.0)
        except Exception:
            return []

    def _search_sessions_keyword(self, query: str, exclude_session_id: str | None = None, limit: int = 5) -> list[ContextSnippet]:
        """从最近会话的 metadata 和 turns 中关键词匹配。"""
        if self.session_store is None:
            return []
        sessions = self.session_store.list_sessions(limit=40)
        terms = [t for t in re.findall(r"\w+", query.lower()) if t]
        query_lower = query.strip().lower()
        hits: list[tuple[float, ContextSnippet]] = []
        for sess in sessions:
            if exclude_session_id and sess.id == exclude_session_id:
                continue
            # load full turns for scoring
            full = self.session_store.load_session(sess.id)
            if full is None:
                continue
            score = 0
            matched_turns: list[str] = []
            for turn in full.turns:
                text = (turn.content or "").lower()
                tscore = sum(text.count(t) for t in terms)
                if query_lower:
                    tscore += text.count(query_lower) * 3
                if tscore > 0:
                    score += tscore
                    matched_turns.append(_collapse_text(turn.content, 180))
            # metadata bonus
            meta = full.metadata or {}
            for k in ("title", "tags", "group"):
                val = str(meta.get(k, "")).lower()
                score += sum(val.count(t) for t in terms) * 5
                if query_lower:
                    score += val.count(query_lower) * 15
            # starred messages bonus
            starred = meta.get("starred_messages")
            if isinstance(starred, list):
                for item in starred:
                    if isinstance(item, dict):
                        content = str(item.get("content", "")).lower()
                        sc = sum(content.count(t) for t in terms)
                        if query_lower:
                            sc += content.count(query_lower) * 3
                        if sc > 0:
                            score += sc * 2
                            matched_turns.append(_collapse_text(item.get("content", ""), 180))
            # wiki results bonus
            wiki = meta.get("wiki_last_result")
            if isinstance(wiki, dict):
                topic = str(wiki.get("topic", "")).lower()
                sc = sum(topic.count(t) for t in terms) * 10
                if query_lower:
                    sc += topic.count(query_lower) * 30
                if sc > 0:
                    score += sc
                    matched_turns.append(f"Wiki topic: {wiki.get('topic', '')}")

            if score > 0 and matched_turns:
                normalized = min(100.0, max(0.0, score * 2))
                confidence = "high" if normalized >= 60 else "medium" if normalized >= 30 else "low"
                hits.append(
                    (
                        normalized,
                        ContextSnippet(
                            kind="session_history",
                            content="\n".join(matched_turns[:4]),
                            source_id=sess.id,
                            source_title=str(meta.get("title", sess.id))[:60],
                            score=normalized,
                            confidence=confidence,
                            provenance=f"Session history keyword match: {query}",
                        ),
                    )
                )
        hits.sort(key=lambda x: x[0], reverse=True)
        return [h[1] for h in hits[:limit]]


def _collapse_text(text: str, limit: int) -> str:
    collapsed = " ".join(str(text or "").split())
    if len(collapsed) <= limit:
        return collapsed
    return collapsed[: limit - 1].rstrip() + "…"
