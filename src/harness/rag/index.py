from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import math
import re
import time


@dataclass
class IndexedDocument:
    path: Path
    preview: str
    score: float = 0.0


class VaultIndex:
    def __init__(self, root: Path) -> None:
        self.root = root
        self._cache: dict[Path, tuple[str, float]] = {}
        self._cache_mtime: float = 0.0

    def _refresh_cache(self) -> None:
        """Rebuild in-memory cache if vault files changed."""
        # Simple heuristic: refresh if any file mtime > cache_mtime
        max_mtime = 0.0
        current_files: set[Path] = set()
        for path in self.root.rglob("*.md"):
            try:
                mtime = path.stat().st_mtime
            except OSError:
                continue
            current_files.add(path)
            max_mtime = max(max_mtime, mtime)
            if path not in self._cache:
                try:
                    text = path.read_text(encoding="utf-8", errors="ignore")
                except OSError:
                    continue
                self._cache[path] = (text, mtime)
        # Prune deleted files
        for stale in list(self._cache.keys()):
            if stale not in current_files:
                del self._cache[stale]
        self._cache_mtime = max_mtime

    def search(self, query: str, limit: int = 5) -> list[IndexedDocument]:
        terms = [token for token in re.findall(r"\w+", query.lower()) if token]
        query_text = query.strip().lower()
        if not terms and not query_text:
            return []

        self._refresh_cache()

        total_docs = len(self._cache)
        idf = {term: math.log1p(total_docs / max(1, self._doc_freq(term))) for term in terms}
        if query_text:
            idf[query_text] = math.log1p(total_docs / max(1, self._doc_freq(query_text)))

        docs: list[IndexedDocument] = []
        for path, (text, _mtime) in self._cache.items():
            lowered = text.lower()
            tf = {term: lowered.count(term) for term in terms}
            tf[query_text] = lowered.count(query_text)
            score = sum(tf.get(term, 0) * idf.get(term, 0) for term in terms)
            if query_text:
                score += tf.get(query_text, 0) * idf.get(query_text, 0) * 3
            # Name match bonus
            name_lower = path.name.lower()
            for term in terms:
                score += name_lower.count(term) * 5 * idf.get(term, 0)
            if query_text:
                score += name_lower.count(query_text) * 5 * idf.get(query_text, 0)
            if score <= 0:
                continue
            preview = self._snippet(text, terms, query_text)
            docs.append(IndexedDocument(path=path, preview=preview, score=score))

        docs.sort(key=lambda item: item.score, reverse=True)
        return docs[:limit]

    def _doc_freq(self, term: str) -> int:
        count = 0
        for _path, (text, _mtime) in self._cache.items():
            if term in text.lower():
                count += 1
        return count

    def _snippet(self, text: str, terms: list[str], query_text: str) -> str:
        lines = [line.strip() for line in text.splitlines() if line.strip()]
        best_line = ""
        best_score = -1
        for line in lines:
            lowered = line.lower()
            score = sum(lowered.count(term) for term in terms)
            if query_text:
                score += lowered.count(query_text) * 3
            if score > best_score:
                best_score = score
                best_line = line
        if best_line:
            return best_line[:280]
        return (lines[0] if lines else text[:280])[:280]
