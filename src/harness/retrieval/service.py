from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
import re

from harness.rag import IndexedDocument, VaultIndex
from harness.storage import StateStore


@dataclass
class RetrievalHit:
    kind: str
    path: str
    preview: str
    score: int


@dataclass
class RetrievalResult:
    query: str
    hits: list[RetrievalHit] = field(default_factory=list)

    @property
    def sources(self) -> list[str]:
        return [hit.path for hit in self.hits]


class RetrievalService:
    def __init__(self, vault_root: Path, store: StateStore) -> None:
        self.vault_index = VaultIndex(vault_root)
        self.store = store

    def search(self, query: str, limit: int = 5) -> RetrievalResult:
        hits: list[RetrievalHit] = []
        hits.extend(self._search_vault(query, limit=limit))
        hits.extend(self._search_document_chunks(query, limit=limit))
        hits.sort(key=lambda item: item.score, reverse=True)
        return RetrievalResult(query=query, hits=hits[:limit])

    def _search_vault(self, query: str, limit: int) -> list[RetrievalHit]:
        docs = self.vault_index.search(query, limit=limit)
        hits: list[RetrievalHit] = []
        for item in docs:
            hits.append(
                RetrievalHit(
                    kind="vault_note",
                    path=str(item.path),
                    preview=item.preview,
                    score=int(item.score),
                )
            )
        return hits

    def _search_document_chunks(self, query: str, limit: int) -> list[RetrievalHit]:
        terms = [token for token in re.findall(r"\w+", query.lower()) if token]
        query_text = query.strip().lower()
        if not terms and not query_text:
            return []
        hits: list[RetrievalHit] = []
        for chunk in self.store.list_document_chunks(limit=400):
            lowered = chunk.content.lower()
            score = sum(lowered.count(term) for term in terms)
            if query_text:
                score += lowered.count(query_text) * 3
            if score <= 0:
                continue
            hits.append(
                RetrievalHit(
                    kind="document_chunk",
                    path=f"document:{chunk.document_id}#chunk-{chunk.chunk_index}",
                    preview=f"[score={score}] {chunk.content_preview}",
                    score=score,
                )
            )
        hits.sort(key=lambda item: item.score, reverse=True)
        return hits[:limit]

    def _extract_score(self, preview: str) -> int:
        match = re.search(r"\[score=(\d+)\]", preview)
        if match is None:
            return 0
        return int(match.group(1))
