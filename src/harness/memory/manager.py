from __future__ import annotations

from harness.memory.extractors import extract_memory_candidates
from harness.memory.models import MemoryCandidate, MemoryItem, MemoryWriteResult
from harness.memory.writeback import write_memory_note
from harness.storage import StateStore
from harness.vault import VaultAdapter


class MemoryManager:
    def __init__(self, store: StateStore, vault: VaultAdapter) -> None:
        self.store = store
        self.vault = vault

    def capture_file_fact(self, *, title: str, detail: str, source_ref: str) -> MemoryWriteResult:
        candidate = MemoryCandidate(
            kind="project_memory",
            scope="project",
            title=title[:60],
            summary=detail[:120],
            content=detail,
            confidence=0.6,
            source_ref=source_ref,
            tags=["project_memory", "ingest"],
        )
        return self._persist_candidates([candidate], source_type="document")

    def capture_from_text(self, text: str, *, source_ref: str = "", source_type: str = "session") -> MemoryWriteResult:
        candidates = extract_memory_candidates(text, source_ref=source_ref)
        return self._persist_candidates(candidates, source_type=source_type)

    def capture_project_update(self, text: str, *, source_ref: str = "") -> MemoryWriteResult:
        candidates = extract_memory_candidates(text, source_ref=source_ref)
        for candidate in candidates:
            if candidate.scope == "project":
                candidate.tags.append("project-update")
        return self._persist_candidates(candidates, source_type="project")

    def _persist_candidates(self, candidates: list[MemoryCandidate], *, source_type: str) -> MemoryWriteResult:
        created: list[MemoryItem] = []
        skipped: list[MemoryCandidate] = []

        for candidate in candidates:
            candidate.source_type = source_type
            if self.store.find_memory_by_title(candidate.title, candidate.kind, candidate.scope):
                skipped.append(candidate)
                continue
            note_path = write_memory_note(self.vault, candidate)
            self.store.record_memory_item(
                kind=candidate.kind,
                scope=candidate.scope,
                title=candidate.title,
                summary=candidate.summary,
                content=candidate.content,
                confidence=candidate.confidence,
                project=candidate.project,
                source_type=candidate.source_type,
                source_ref=candidate.source_ref,
                note_path=note_path,
                tags=candidate.tags,
            )
            created.append(
                MemoryItem(
                    kind=candidate.kind,
                    scope=candidate.scope,
                    title=candidate.title,
                    summary=candidate.summary,
                    content=candidate.content,
                    confidence=candidate.confidence,
                    source_type=candidate.source_type,
                    source_ref=candidate.source_ref,
                    project=candidate.project,
                    tags=candidate.tags,
                    updated_at="",
                )
            )
        return MemoryWriteResult(created=created, skipped=skipped)
