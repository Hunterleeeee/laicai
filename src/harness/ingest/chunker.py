from __future__ import annotations

from dataclasses import dataclass
import re


@dataclass
class ChunkedDocument:
    chunks: list[str]


class Chunker:
    def __init__(self, chunk_chars: int = 1200, overlap_chars: int = 120) -> None:
        self.chunk_chars = chunk_chars
        self.overlap_chars = overlap_chars

    def split(self, text: str) -> ChunkedDocument:
        content = text.strip()
        if not content:
            return ChunkedDocument(chunks=[])

        chunks: list[str] = []
        start = 0
        size = len(content)
        while start < size:
            end = min(size, start + self.chunk_chars)
            # Try to extend to a paragraph boundary if within tolerance
            if end < size:
                end = self._find_boundary(content, start, end, tolerance=int(self.chunk_chars * 0.15))
            chunk = content[start:end].strip()
            if chunk:
                chunks.append(chunk)
            if end >= size:
                break
            # Overlap: step back by overlap_chars, but keep semantic start
            next_start = max(end - self.overlap_chars, start + 1)
            next_start = self._find_forward_boundary(content, next_start, end)
            start = next_start
        return ChunkedDocument(chunks=chunks)

    def _find_boundary(self, text: str, start: int, preferred_end: int, tolerance: int) -> int:
        """Look for paragraph or sentence boundary near preferred_end."""
        min_chars = max(int(self.chunk_chars * 0.5), 20)
        search_back_start = start + min_chars
        # First search backward from preferred_end for a good boundary
        # (accepting a slightly shorter chunk for semantic coherence)
        para_match = text.rfind("\n\n", search_back_start, preferred_end + 1)
        if para_match != -1:
            return para_match + 2  # after the newline
        sentence_match = text.rfind(". ", search_back_start, preferred_end + 1)
        if sentence_match != -1:
            return sentence_match + 2
        line_match = text.rfind("\n", search_back_start, preferred_end + 1)
        if line_match != -1:
            return line_match + 1

        # Fallback: search forward within tolerance
        search_end = min(len(text), preferred_end + tolerance)
        para_match = text.rfind("\n\n", preferred_end, search_end)
        if para_match != -1:
            return para_match + 2
        sentence_match = text.rfind(". ", preferred_end, search_end)
        if sentence_match != -1:
            return sentence_match + 2
        line_match = text.rfind("\n", preferred_end, search_end)
        if line_match != -1:
            return line_match + 1
        return preferred_end

    def _find_forward_boundary(self, text: str, preferred_start: int, max_end: int) -> int:
        """When stepping back for overlap, try to start at a sentence or line boundary."""
        search_end = min(len(text), max_end)
        # Look for sentence start after a period
        match = re.search(r"\.\s+([A-Z])", text[preferred_start:search_end])
        if match:
            return preferred_start + match.start(1)
        # Look for paragraph start
        para = text.find("\n\n", preferred_start, search_end)
        if para != -1:
            return para + 2
        line = text.find("\n", preferred_start, search_end)
        if line != -1:
            return line + 1
        return preferred_start
