from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
import hashlib
import json
import sqlite3


@dataclass
class SessionRecord:
    id: int
    title: str
    status: str
    current_intent: str | None
    model_mode: str
    current_provider: str | None
    current_model: str | None
    created_at: str
    updated_at: str


@dataclass
class ArtifactRecord:
    id: int
    session_id: int
    turn_id: int | None
    kind: str
    title: str
    path: str | None
    content_preview: str
    metadata_json: str
    created_at: str


@dataclass
class DocumentRecord:
    id: int
    title: str
    source_path: str
    source_type: str
    mime_type: str
    status: str
    note_path: str | None
    content_hash: str
    created_at: str
    updated_at: str


@dataclass
class DocumentChunkRecord:
    id: int
    document_id: int
    chunk_index: int
    content: str
    content_preview: str
    token_estimate: int
    created_at: str


class StateStore:
    def __init__(self, db_path: Path) -> None:
        self.db_path = db_path
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self._init_db()

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        return conn

    def _init_db(self) -> None:
        with self._connect() as conn:
            conn.executescript(
                """
                create table if not exists runs (
                    id integer primary key autoincrement,
                    kind text not null,
                    input text not null,
                    status text not null,
                    created_at text not null
                );

                create table if not exists notes (
                    id integer primary key autoincrement,
                    title text not null,
                    path text not null,
                    kind text not null,
                    created_at text not null
                );

                create table if not exists sessions (
                    id integer primary key autoincrement,
                    title text not null,
                    status text not null,
                    current_intent text,
                    model_mode text not null default 'auto',
                    current_provider text,
                    current_model text,
                    created_at text not null,
                    updated_at text not null
                );

                create table if not exists session_turns (
                    id integer primary key autoincrement,
                    session_id integer not null,
                    role text not null,
                    message text not null,
                    intent text,
                    created_at text not null,
                    foreign key(session_id) references sessions(id)
                );

                create table if not exists artifacts (
                    id integer primary key autoincrement,
                    session_id integer not null,
                    turn_id integer,
                    kind text not null,
                    title text not null,
                    path text,
                    content_preview text not null default '',
                    metadata_json text not null default '{}',
                    created_at text not null,
                    foreign key(session_id) references sessions(id),
                    foreign key(turn_id) references session_turns(id)
                );

                create table if not exists memory_items (
                    id integer primary key autoincrement,
                    kind text not null,
                    scope text not null,
                    title text not null,
                    summary text not null,
                    content text not null,
                    confidence real not null default 0.0,
                    project text not null default '',
                    source_type text not null default 'session',
                    source_ref text not null default '',
                    note_path text,
                    status text not null default 'active',
                    tags_json text not null default '[]',
                    created_at text not null,
                    updated_at text not null
                );

                create table if not exists documents (
                    id integer primary key autoincrement,
                    title text not null,
                    source_path text not null,
                    source_type text not null,
                    mime_type text not null default 'unknown',
                    status text not null default 'ready',
                    note_path text,
                    content_hash text not null,
                    created_at text not null,
                    updated_at text not null
                );

                create table if not exists document_chunks (
                    id integer primary key autoincrement,
                    document_id integer not null,
                    chunk_index integer not null,
                    content text not null,
                    content_preview text not null,
                    token_estimate integer not null default 0,
                    created_at text not null,
                    foreign key(document_id) references documents(id)
                );
                """
            )
            existing_columns = {
                row["name"]
                for row in conn.execute("pragma table_info(sessions)").fetchall()
            }
            if "model_mode" not in existing_columns:
                conn.execute("alter table sessions add column model_mode text not null default 'auto'")
            if "current_provider" not in existing_columns:
                conn.execute("alter table sessions add column current_provider text")
            if "current_model" not in existing_columns:
                conn.execute("alter table sessions add column current_model text")

    def record_run(self, kind: str, input_text: str, status: str = "created") -> int:
        timestamp = datetime.now(UTC).isoformat()
        with self._connect() as conn:
            cur = conn.execute(
                "insert into runs(kind, input, status, created_at) values (?, ?, ?, ?)",
                (kind, input_text, status, timestamp),
            )
            return int(cur.lastrowid)

    def record_note(self, title: str, path: Path, kind: str) -> int:
        timestamp = datetime.now(UTC).isoformat()
        with self._connect() as conn:
            cur = conn.execute(
                "insert into notes(title, path, kind, created_at) values (?, ?, ?, ?)",
                (title, str(path), kind, timestamp),
            )
            return int(cur.lastrowid)

    def record_artifact(
        self,
        *,
        session_id: int,
        turn_id: int | None,
        kind: str,
        title: str,
        path: str | None = None,
        content_preview: str = "",
        metadata: dict[str, object] | None = None,
    ) -> int:
        timestamp = datetime.now(UTC).isoformat()
        metadata_json = json.dumps(metadata or {}, ensure_ascii=False, sort_keys=True)
        with self._connect() as conn:
            cur = conn.execute(
                "insert into artifacts(session_id, turn_id, kind, title, path, content_preview, metadata_json, created_at) values (?, ?, ?, ?, ?, ?, ?, ?)",
                (session_id, turn_id, kind, title, path, content_preview, metadata_json, timestamp),
            )
            return int(cur.lastrowid)

    def list_artifacts(self, session_id: int, limit: int = 100) -> list[ArtifactRecord]:
        with self._connect() as conn:
            rows = conn.execute(
                "select id, session_id, turn_id, kind, title, path, content_preview, metadata_json, created_at from artifacts where session_id = ? order by id desc limit ?",
                (session_id, limit),
            ).fetchall()
        return [
            ArtifactRecord(
                id=int(row["id"]),
                session_id=int(row["session_id"]),
                turn_id=int(row["turn_id"]) if row["turn_id"] is not None else None,
                kind=str(row["kind"]),
                title=str(row["title"]),
                path=row["path"],
                content_preview=str(row["content_preview"] or ""),
                metadata_json=str(row["metadata_json"] or "{}"),
                created_at=str(row["created_at"]),
            )
            for row in rows
        ]

    def record_memory_item(
        self,
        *,
        kind: str,
        scope: str,
        title: str,
        summary: str,
        content: str,
        confidence: float,
        project: str = "",
        source_type: str = "session",
        source_ref: str = "",
        note_path: str | None = None,
        status: str = "active",
        tags: list[str] | None = None,
    ) -> int:
        timestamp = datetime.now(UTC).isoformat()
        tags_json = json.dumps(tags or [], ensure_ascii=False, sort_keys=True)
        with self._connect() as conn:
            cur = conn.execute(
                "insert into memory_items(kind, scope, title, summary, content, confidence, project, source_type, source_ref, note_path, status, tags_json, created_at, updated_at) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (kind, scope, title, summary, content, confidence, project, source_type, source_ref, note_path, status, tags_json, timestamp, timestamp),
            )
            return int(cur.lastrowid)

    def find_memory_by_title(self, title: str, kind: str, scope: str) -> bool:
        with self._connect() as conn:
            row = conn.execute(
                "select 1 from memory_items where title = ? and kind = ? and scope = ? and status = 'active' limit 1",
                (title, kind, scope),
            ).fetchone()
        return row is not None

    def record_document(
        self,
        *,
        title: str,
        source_path: str,
        source_type: str,
        mime_type: str,
        content: str,
        note_path: str | None = None,
        status: str = "ready",
    ) -> int:
        timestamp = datetime.now(UTC).isoformat()
        content_hash = hashlib.sha256(content.encode("utf-8", errors="ignore")).hexdigest()
        with self._connect() as conn:
            existing = conn.execute(
                "select id from documents where source_path = ? and content_hash = ? limit 1",
                (source_path, content_hash),
            ).fetchone()
            if existing is not None:
                return int(existing["id"])
            cur = conn.execute(
                "insert into documents(title, source_path, source_type, mime_type, status, note_path, content_hash, created_at, updated_at) values (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (title, source_path, source_type, mime_type, status, note_path, content_hash, timestamp, timestamp),
            )
            return int(cur.lastrowid)

    def replace_document_chunks(self, document_id: int, chunks: list[str]) -> None:
        timestamp = datetime.now(UTC).isoformat()
        with self._connect() as conn:
            conn.execute("delete from document_chunks where document_id = ?", (document_id,))
            for index, chunk in enumerate(chunks):
                content = chunk.strip()
                if not content:
                    continue
                conn.execute(
                    "insert into document_chunks(document_id, chunk_index, content, content_preview, token_estimate, created_at) values (?, ?, ?, ?, ?, ?)",
                    (document_id, index, content, content[:240], self._estimate_tokens(content), timestamp),
                )
            conn.execute(
                "update documents set updated_at = ?, status = 'ready' where id = ?",
                (timestamp, document_id),
            )

    def list_document_chunks(self, document_id: int | None = None, limit: int = 20) -> list[DocumentChunkRecord]:
        with self._connect() as conn:
            if document_id is not None:
                rows = conn.execute(
                    "SELECT id, document_id, chunk_index, content, content_preview, token_estimate, created_at FROM document_chunks WHERE document_id = ? ORDER BY chunk_index ASC LIMIT ?",
                    (document_id, limit),
                ).fetchall()
            else:
                rows = conn.execute(
                    "SELECT id, document_id, chunk_index, content, content_preview, token_estimate, created_at FROM document_chunks ORDER BY chunk_index ASC LIMIT ?",
                    (limit,),
                ).fetchall()
        return [
            DocumentChunkRecord(
                id=int(row["id"]),
                document_id=int(row["document_id"]),
                chunk_index=int(row["chunk_index"]),
                content=str(row["content"]),
                content_preview=str(row["content_preview"]),
                token_estimate=int(row["token_estimate"]),
                created_at=str(row["created_at"]),
            )
            for row in rows
        ]

    def list_documents(self, limit: int = 100) -> list[DocumentRecord]:
        with self._connect() as conn:
            rows = conn.execute(
                "select id, title, source_path, source_type, mime_type, status, note_path, content_hash, created_at, updated_at from documents order by id desc limit ?",
                (limit,),
            ).fetchall()
        return [
            DocumentRecord(
                id=int(row["id"]),
                title=str(row["title"]),
                source_path=str(row["source_path"]),
                source_type=str(row["source_type"]),
                mime_type=str(row["mime_type"]),
                status=str(row["status"]),
                note_path=row["note_path"],
                content_hash=str(row["content_hash"]),
                created_at=str(row["created_at"]),
                updated_at=str(row["updated_at"]),
            )
            for row in rows
        ]

    def create_session(
        self,
        title: str,
        status: str = "active",
        current_intent: str | None = None,
        model_mode: str = "auto",
        current_provider: str | None = None,
        current_model: str | None = None,
    ) -> SessionRecord:
        timestamp = datetime.now(UTC).isoformat()
        with self._connect() as conn:
            cur = conn.execute(
                "insert into sessions(title, status, current_intent, model_mode, current_provider, current_model, created_at, updated_at) values (?, ?, ?, ?, ?, ?, ?, ?)",
                (title, status, current_intent, model_mode, current_provider, current_model, timestamp, timestamp),
            )
            session_id = int(cur.lastrowid)
        return self.get_session(session_id)

    def get_session(self, session_id: int) -> SessionRecord:
        with self._connect() as conn:
            row = conn.execute(
                "select id, title, status, current_intent, model_mode, current_provider, current_model, created_at, updated_at from sessions where id = ?",
                (session_id,),
            ).fetchone()
        if row is None:
            raise KeyError(f"Unknown session: {session_id}")
        return SessionRecord(
            id=int(row["id"]),
            title=str(row["title"]),
            status=str(row["status"]),
            current_intent=row["current_intent"],
            model_mode=str(row["model_mode"] or "auto"),
            current_provider=row["current_provider"],
            current_model=row["current_model"],
            created_at=str(row["created_at"]),
            updated_at=str(row["updated_at"]),
        )

    def latest_session(self) -> SessionRecord | None:
        with self._connect() as conn:
            row = conn.execute(
                "select id, title, status, current_intent, model_mode, current_provider, current_model, created_at, updated_at from sessions order by id desc limit 1"
            ).fetchone()
        if row is None:
            return None
        return SessionRecord(
            id=int(row["id"]),
            title=str(row["title"]),
            status=str(row["status"]),
            current_intent=row["current_intent"],
            model_mode=str(row["model_mode"] or "auto"),
            current_provider=row["current_provider"],
            current_model=row["current_model"],
            created_at=str(row["created_at"]),
            updated_at=str(row["updated_at"]),
        )

    def update_session(
        self,
        session_id: int,
        *,
        status: str | None = None,
        current_intent: str | None = None,
        model_mode: str | None = None,
        current_provider: str | None = None,
        current_model: str | None = None,
    ) -> SessionRecord:
        current = self.get_session(session_id)
        timestamp = datetime.now(UTC).isoformat()
        new_status = status or current.status
        new_intent = current_intent if current_intent is not None else current.current_intent
        new_mode = model_mode if model_mode is not None else current.model_mode
        new_provider = current_provider if current_provider is not None else current.current_provider
        new_model = current_model if current_model is not None else current.current_model
        with self._connect() as conn:
            conn.execute(
                "update sessions set status = ?, current_intent = ?, model_mode = ?, current_provider = ?, current_model = ?, updated_at = ? where id = ?",
                (new_status, new_intent, new_mode, new_provider, new_model, timestamp, session_id),
            )
        return self.get_session(session_id)

    def record_turn(self, session_id: int, role: str, message: str, intent: str | None = None) -> int:
        timestamp = datetime.now(UTC).isoformat()
        with self._connect() as conn:
            cur = conn.execute(
                "insert into session_turns(session_id, role, message, intent, created_at) values (?, ?, ?, ?, ?)",
                (session_id, role, message, intent, timestamp),
            )
            conn.execute(
                "update sessions set updated_at = ?, current_intent = coalesce(?, current_intent) where id = ?",
                (timestamp, intent, session_id),
            )
            return int(cur.lastrowid)

    def _estimate_tokens(self, content: str) -> int:
        return max(1, len(content) // 4)
