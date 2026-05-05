from __future__ import annotations

from dataclasses import dataclass
import mimetypes
from pathlib import Path
import shutil

from harness.config import HarnessConfig
from harness.ingest.chunker import Chunker
from harness.ingest.mineru import MinerUAdapter
from harness.storage import StateStore
from harness.vault import VaultAdapter


@dataclass
class DocumentPipelineResult:
    document_id: int
    source_path: Path
    note_path: Path | None
    copied_path: Path | None
    chunks_count: int
    source_type: str


class DocumentPipeline:
    def __init__(self, config: HarnessConfig, store: StateStore, vault: VaultAdapter) -> None:
        self.config = config
        self.store = store
        self.vault = vault
        self.mineru = MinerUAdapter(config.mineru)
        self.chunker = Chunker()

    def ingest_file(self, path: Path, *, title: str | None = None) -> DocumentPipelineResult:
        source = path.expanduser().resolve()
        if not source.exists():
            raise FileNotFoundError(source)

        copied_path: Path | None = None
        body = ""
        source_type, _ = mimetypes.guess_type(source.name)
        mime_type = source_type or "unknown"
        resolved_title = title or source.stem

        if source.suffix.lower() == ".md":
            body = source.read_text(encoding="utf-8", errors="ignore")
        else:
            attachments_dir = self.vault.root / "Attachments"
            attachments_dir.mkdir(parents=True, exist_ok=True)
            copied_path = attachments_dir / source.name
            if copied_path != source:
                shutil.copy2(source, copied_path)
            extraction = self.mineru.extract(source, self.vault.root / "Attachments" / "_extracted")
            if extraction.ok and extraction.output_path:
                body = extraction.output_path.read_text(encoding="utf-8", errors="ignore")
            else:
                body = (
                    "Imported source file.\n\n"
                    f"- Original path: `{source}`\n"
                    f"- MIME type: `{mime_type}`\n"
                    f"- MinerU mode: `{extraction.mode}`\n"
                    f"- Extraction status: `{extraction.message}`\n"
                    "- Next step: configure a callable MinerU CLI or command template.\n"
                )

        note_path: Path | None = None
        try:
            note = self.vault.create_source_note(
                title=resolved_title,
                body=body,
                source_path=str(source),
                source_type=mime_type,
            )
            note_path = note.path
        except OSError:
            note_path = None

        document_id = self.store.record_document(
            title=resolved_title,
            source_path=str(source),
            source_type=mime_type,
            mime_type=mime_type,
            content=body,
            note_path=str(note_path) if note_path else None,
        )
        chunks = self.chunker.split(body).chunks
        self.store.replace_document_chunks(document_id, chunks)
        return DocumentPipelineResult(
            document_id=document_id,
            source_path=source,
            note_path=note_path,
            copied_path=copied_path,
            chunks_count=len(chunks),
            source_type=mime_type,
        )
