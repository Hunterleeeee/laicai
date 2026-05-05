from __future__ import annotations

from pathlib import Path

from harness.rag import VaultIndex
from harness.retrieval import RetrievalService
from harness.storage import StateStore


def test_vault_index_keyword_search(tmp_vault):
    # Seed vault with a note
    note = tmp_vault / "note.md"
    note.write_text("# Python\nPython is a programming language.\n", encoding="utf-8")
    index = VaultIndex(tmp_vault)
    results = index.search("python", limit=5)
    assert len(results) == 1
    assert results[0].path.name == "note.md"
    assert "Python" in results[0].preview


def test_vault_index_empty_query(tmp_vault):
    index = VaultIndex(tmp_vault)
    results = index.search("", limit=5)
    assert results == []


def test_vault_index_no_match(tmp_vault):
    note = tmp_vault / "note.md"
    note.write_text("# JavaScript\nJS is a language.\n", encoding="utf-8")
    index = VaultIndex(tmp_vault)
    results = index.search("python", limit=5)
    assert results == []


def test_retrieval_service_combined(tmp_vault, tmp_db):
    # Seed vault
    note = tmp_vault / "note.md"
    note.write_text("# Go\nGo is fast.", encoding="utf-8")
    store = StateStore(tmp_db)
    service = RetrievalService(tmp_vault, store)
    result = service.search("go fast", limit=5)
    assert len(result.hits) >= 1
    assert result.hits[0].kind == "vault_note"


def test_vault_index_snippet_contains_term(tmp_vault):
    note = tmp_vault / "doc.md"
    note.write_text("Line one.\nLine two has keyword.\nLine three.", encoding="utf-8")
    index = VaultIndex(tmp_vault)
    results = index.search("keyword", limit=5)
    assert len(results) == 1
    assert "keyword" in results[0].preview
