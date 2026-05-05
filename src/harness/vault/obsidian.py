from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
import re

from harness.config import VaultConfig


def slugify(value: str) -> str:
    cleaned = re.sub(r"[^\w\s-]", "", value, flags=re.UNICODE).strip().lower()
    return re.sub(r"[-\s]+", "-", cleaned) or "untitled"


@dataclass
class CreatedNote:
    title: str
    path: Path


class VaultAdapter:
    def __init__(self, config: VaultConfig) -> None:
        self.config = config
        self.root = config.path

    def ensure_layout(self) -> None:
        for folder in (
            self.config.inbox_dir,
            self.config.sources_dir,
            self.config.notes_dir,
            "03 Topics",
            self.config.memory_dir,
            "04 Skills",
            "05 Workflows",
            "07 Reviews",
            "08 Flashcards",
            "Attachments",
        ):
            try:
                (self.root / folder).mkdir(parents=True, exist_ok=True)
            except PermissionError:
                continue

    def create_source_note(
        self,
        *,
        title: str,
        body: str,
        source_path: str,
        source_type: str,
        document_id: int | None = None,
        extra_frontmatter: dict[str, object] | None = None,
    ) -> CreatedNote:
        frontmatter = {
            "type": "source",
            "source_path": source_path,
            "source_type": source_type,
            "document_id": document_id or "",
            "tags": ["source", "ingest"],
        }
        if extra_frontmatter:
            frontmatter.update(extra_frontmatter)
        return self.create_note(
            title=title,
            body=body,
            folder=self.config.sources_dir,
            frontmatter=frontmatter,
        )

    def create_note(self, title: str, body: str, folder: str | None = None, frontmatter: dict[str, object] | None = None) -> CreatedNote:
        self.ensure_layout()
        target_dir = self.root / (folder or self.config.notes_dir)
        target_dir.mkdir(parents=True, exist_ok=True)
        filename = f"{datetime.now().strftime('%Y%m%d-%H%M%S')}-{slugify(title)}.md"
        target = target_dir / filename
        payload = self._render_markdown(title=title, body=body, frontmatter=frontmatter or {})
        target.write_text(payload, encoding="utf-8")
        return CreatedNote(title=title, path=target)

    def topic_note_path(self, title: str) -> Path:
        return self.root / "03 Topics" / f"{slugify(title)}.md"

    def render_topic_note(self, title: str, body: str, frontmatter: dict[str, object] | None = None) -> tuple[Path, str]:
        target = self.topic_note_path(title)
        payload = self._render_markdown(title=title, body=body, frontmatter=frontmatter or {})
        return target, payload

    def upsert_topic_note(self, title: str, body: str, frontmatter: dict[str, object] | None = None) -> CreatedNote:
        self.ensure_layout()
        target, payload = self.render_topic_note(title=title, body=body, frontmatter=frontmatter)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(payload, encoding="utf-8")
        return CreatedNote(title=title, path=target)

    def _render_markdown(self, title: str, body: str, frontmatter: dict[str, object]) -> str:
        lines = ["---", f'title: "{title}"']
        for key, value in frontmatter.items():
            if isinstance(value, list):
                rendered = "[" + ", ".join(f'"{item}"' for item in value) + "]"
            else:
                rendered = f'"{value}"'
            lines.append(f"{key}: {rendered}")
        lines.extend(["---", "", f"# {title}", "", body.strip(), ""])
        return "\n".join(lines)
