"""Tests for vector index and embedding adapter."""

import pytest
from pathlib import Path

from harness.rag.vector_index import VectorIndex, VectorHit, _cosine_similarity


class MockEmbeddingAdapter:
    """Mock embedding that returns a vector based on text length modulo."""

    async def embed(self, texts):
        return [[len(t) % 10 / 10.0, 0.5, 0.3] for t in texts]

    async def embed_one(self, text):
        return [len(text) % 10 / 10.0, 0.5, 0.3]


def test_cosine_similarity():
    assert _cosine_similarity([1, 0, 0], [1, 0, 0]) == pytest.approx(1.0)
    assert _cosine_similarity([1, 0, 0], [0, 1, 0]) == pytest.approx(0.0)
    assert _cosine_similarity([1, 0, 0], [-1, 0, 0]) == pytest.approx(-1.0)
    assert _cosine_similarity([0, 0, 0], [1, 0, 0]) == pytest.approx(0.0)


def test_vector_search():
    vi = VectorIndex(Path("/tmp/fake"))
    vi._entries = [
        {"path": "a.md", "text": "Python basics", "vector": [0.9, 0.1, 0.0], "mtime": 0},
        {"path": "b.md", "text": "JavaScript intro", "vector": [0.1, 0.9, 0.0], "mtime": 0},
        {"path": "c.md", "text": "Rust guide", "vector": [0.0, 0.1, 0.9], "mtime": 0},
    ]
    # query similar to a.md
    hits = vi.search([0.9, 0.1, 0.0], top_k=2)
    assert len(hits) == 2
    assert hits[0].path == "a.md"
    assert hits[0].score > hits[1].score


@pytest.mark.asyncio
async def test_build_index(tmp_path: Path):
    (tmp_path / "note1.md").write_text("Hello world of Python programming")
    (tmp_path / "note2.md").write_text("JavaScript is for web development")
    (tmp_path / "sub").mkdir()
    (tmp_path / "sub" / "note3.md").write_text("Rust is a systems language")

    adapter = MockEmbeddingAdapter()
    vi = VectorIndex(tmp_path, cache_dir=tmp_path / ".cache")

    count = await vi.build(adapter)
    assert count == 3

    # search
    query_vec = await adapter.embed_one("Python programming")
    hits = vi.search(query_vec, top_k=2)
    assert len(hits) == 2
    assert all(isinstance(h, VectorHit) for h in hits)

    # cache should exist
    assert (tmp_path / ".cache" / "vector_index.json").exists()

    # rebuild should reuse cache
    count2 = await vi.build(adapter)
    assert count2 == 3


def test_empty_search():
    vi = VectorIndex(Path("/tmp/fake"))
    hits = vi.search([], top_k=5)
    assert hits == []
    hits = vi.search([1, 0, 0], top_k=5)
    assert hits == []
