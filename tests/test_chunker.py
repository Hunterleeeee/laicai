from __future__ import annotations

from harness.ingest.chunker import Chunker


def test_empty_text():
    chunker = Chunker(chunk_chars=100, overlap_chars=10)
    result = chunker.split("")
    assert result.chunks == []


def test_short_text_single_chunk():
    chunker = Chunker(chunk_chars=100, overlap_chars=10)
    text = "Short text."
    result = chunker.split(text)
    assert len(result.chunks) == 1
    assert result.chunks[0] == "Short text."


def test_paragraph_boundary_respected():
    chunker = Chunker(chunk_chars=50, overlap_chars=5)
    # First paragraph is long enough that the \n\n boundary falls within search range
    text = "First paragraph here with enough text to reach the boundary.\n\nSecond paragraph starts here and continues onward."
    result = chunker.split(text)
    # Should prefer splitting at paragraph boundaries
    assert len(result.chunks) >= 1
    # The first chunk should not break mid-paragraph if avoidable
    first = result.chunks[0]
    assert "Second paragraph" not in first or first.endswith(".")


def test_sentence_boundary_fallback():
    chunker = Chunker(chunk_chars=30, overlap_chars=5)
    text = "Sentence one. Sentence two here. Sentence three now."
    result = chunker.split(text)
    for chunk in result.chunks:
        # Prefer ending at a sentence boundary
        assert chunk.endswith(".") or len(chunk) < 30


def test_overlap_present():
    chunker = Chunker(chunk_chars=20, overlap_chars=5)
    text = "This is a longer text that should definitely be split into multiple chunks with overlap."
    result = chunker.split(text)
    if len(result.chunks) > 1:
        # Overlap should exist between consecutive chunks
        assert result.chunks[1][:5] == result.chunks[0][-5:]


def test_chunker_respects_max_chars():
    chunker = Chunker(chunk_chars=50, overlap_chars=5)
    text = "a" * 200
    result = chunker.split(text)
    for chunk in result.chunks:
        assert len(chunk) <= 50 + 10  # small tolerance for boundary search
