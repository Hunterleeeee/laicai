"""In-memory vector index for semantic vault search.

Uses cosine similarity. No external deps (pure Python math).
For large vaults (>10k docs), consider using faiss or hnswlib.
"""

from __future__ import annotations

import json
import math
import logging
from dataclasses import dataclass
from pathlib import Path

logger = logging.getLogger(__name__)


@dataclass
class VectorHit:
    path: str
    score: float
    preview: str


def _cosine_similarity(a: list[float], b: list[float]) -> float:
    """Cosine similarity between two vectors."""
    dot = sum(x * y for x, y in zip(a, b))
    norm_a = math.sqrt(sum(x * x for x in a))
    norm_b = math.sqrt(sum(x * x for x in b))
    if norm_a == 0 or norm_b == 0:
        return 0.0
    return dot / (norm_a * norm_b)


class VectorIndex:
    """In-memory vector store for vault notes.

    Call `build()` to embed all notes, then `search()` for semantic queries.
    Persists to a JSON cache file for fast reload.
    """

    def __init__(self, vault_root: Path, cache_dir: Path | None = None) -> None:
        self.vault_root = vault_root
        self.cache_dir = cache_dir or (vault_root / ".laicai-cache")
        self.cache_file = self.cache_dir / "vector_index.json"
        self._entries: list[dict] = []  # {"path": str, "text": str, "vector": list[float]}

    async def build(self, embedding_adapter) -> int:
        """Embed all markdown files in vault. Returns number of indexed notes."""
        notes = list(self.vault_root.rglob("*.md"))
        if not notes:
            return 0

        # load existing cache
        cached = self._load_cache()
        cached_map = {e["path"]: e for e in cached}

        to_embed: list[tuple[str, str]] = []
        reused = 0

        for note_path in notes:
            rel = str(note_path.relative_to(self.vault_root))
            mtime = note_path.stat().st_mtime
            # skip if cached and not modified
            if rel in cached_map and cached_map[rel].get("mtime", 0) >= mtime:
                reused += 1
                continue
            text = note_path.read_text(encoding="utf-8", errors="replace")[:2000]
            to_embed.append((rel, text))

        logger.info("Vector index: %d cached, %d to embed", reused, len(to_embed))

        # keep cached entries that are still valid
        self._entries = [e for e in cached if e["path"] in {str(n.relative_to(self.vault_root)) for n in notes}]

        # batch embed new/modified notes
        if to_embed:
            BATCH = 32
            for i in range(0, len(to_embed), BATCH):
                batch = to_embed[i:i + BATCH]
                texts = [t for _, t in batch]
                vectors = await embedding_adapter.embed(texts)
                for (rel, text), vec in zip(batch, vectors):
                    mtime = (self.vault_root / rel).stat().st_mtime
                    # remove old entry if exists
                    self._entries = [e for e in self._entries if e["path"] != rel]
                    self._entries.append({
                        "path": rel,
                        "text": text[:300],
                        "vector": vec,
                        "mtime": mtime,
                    })

        self._save_cache()
        return len(self._entries)

    def search(self, query_vector: list[float], top_k: int = 5) -> list[VectorHit]:
        """Find most similar notes to a query vector."""
        if not self._entries or not query_vector:
            return []

        scored = []
        for entry in self._entries:
            sim = _cosine_similarity(query_vector, entry["vector"])
            scored.append((sim, entry))

        scored.sort(key=lambda x: x[0], reverse=True)
        return [
            VectorHit(
                path=entry["path"],
                score=round(sim, 4),
                preview=entry.get("text", "")[:200],
            )
            for sim, entry in scored[:top_k]
        ]

    def _load_cache(self) -> list[dict]:
        if self.cache_file.exists():
            try:
                return json.loads(self.cache_file.read_text(encoding="utf-8"))
            except (json.JSONDecodeError, KeyError):
                pass
        return []

    def _save_cache(self) -> None:
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        # save without vectors for text entries, include vectors
        self.cache_file.write_text(
            json.dumps(self._entries, ensure_ascii=False),
            encoding="utf-8",
        )
        logger.info("Vector index cached: %d entries → %s", len(self._entries), self.cache_file)
