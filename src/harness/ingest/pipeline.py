from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from harness.config import HarnessConfig
from harness.ingest.document_pipeline import DocumentPipeline
from harness.storage import StateStore
from harness.vault import VaultAdapter


@dataclass
class IngestResult:
    source_path: Path
    note_path: Path
    copied_path: Path | None
    document_id: int | None = None
    chunks_count: int = 0


class IngestPipeline:
    def __init__(self, config: HarnessConfig, vault: VaultAdapter, store: StateStore) -> None:
        self.document_pipeline = DocumentPipeline(config=config, store=store, vault=vault)

    def ingest_file(self, path: Path, *, title: str | None = None) -> IngestResult:
        result = self.document_pipeline.ingest_file(path, title=title)
        if result.note_path is None:
            raise PermissionError(f"Unable to write source note for {result.source_path}")
        return IngestResult(
            source_path=result.source_path,
            note_path=result.note_path,
            copied_path=result.copied_path,
            document_id=result.document_id,
            chunks_count=result.chunks_count,
        )
