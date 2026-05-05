"""SQLite-backed session storage for the new Agent system."""

from __future__ import annotations

import json
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

from harness.core.types import Role, Session, Turn


_SCHEMA = """
CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    created_at TEXT NOT NULL,
    metadata TEXT NOT NULL DEFAULT '{}'
);
CREATE TABLE IF NOT EXISTS turns (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL REFERENCES sessions(id),
    role TEXT NOT NULL,
    content TEXT NOT NULL,
    name TEXT,
    tool_call_id TEXT,
    timestamp TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_turns_session ON turns(session_id);
"""


def _collapse_text(text: str, limit: int) -> str:
    collapsed = " ".join(text.split())
    if len(collapsed) <= limit:
        return collapsed
    return collapsed[: limit - 1].rstrip() + "…"


def _derive_session_title(session: Session) -> str:
    explicit = str(session.metadata.get("title", "")).strip()
    if explicit:
        return explicit
    for turn in session.turns:
        if turn.role == Role.USER and turn.content.strip():
            return _collapse_text(turn.content, 48)
    return f"Session {session.id}"


def _derive_session_preview(session: Session) -> str:
    for turn in reversed(session.turns):
        if turn.role in (Role.ASSISTANT, Role.USER) and turn.content.strip() and not turn.content.startswith("[tool_call"):
            return _collapse_text(turn.content, 72)
    return ""


class SQLiteSessionStore:
    """Persist and retrieve agent sessions."""

    def __init__(self, db_path: str | Path = ":memory:") -> None:
        path = Path(db_path).expanduser() if isinstance(db_path, Path) or db_path != ":memory:" else None
        if path is not None:
            path.parent.mkdir(parents=True, exist_ok=True)
            self.db_path = str(path)
        else:
            self.db_path = ":memory:"
        self._ensure_schema()

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        return conn

    def _ensure_schema(self) -> None:
        with self._connect() as conn:
            conn.executescript(_SCHEMA)

    def save_session(self, session: Session) -> None:
        session.metadata["title"] = _derive_session_title(session)
        session.metadata["preview"] = _derive_session_preview(session)
        session.metadata["turn_count"] = len(session.turns)
        with self._connect() as conn:
            conn.execute("BEGIN IMMEDIATE")
            conn.execute(
                "INSERT OR REPLACE INTO sessions (id, created_at, metadata) VALUES (?, ?, ?)",
                (session.id, session.created_at.isoformat(), json.dumps(session.metadata)),
            )
            # delete old turns and re-insert in a single transaction
            conn.execute("DELETE FROM turns WHERE session_id = ?", (session.id,))
            for t in session.turns:
                conn.execute(
                    "INSERT INTO turns (session_id, role, content, name, tool_call_id, timestamp) VALUES (?, ?, ?, ?, ?, ?)",
                    (session.id, t.role.value, t.content, t.name, t.tool_call_id, t.timestamp.isoformat()),
                )
            conn.commit()

    def load_session(self, session_id: str) -> Session | None:
        with self._connect() as conn:
            row = conn.execute("SELECT * FROM sessions WHERE id = ?", (session_id,)).fetchone()
            if not row:
                return None
            turns_rows = conn.execute(
                "SELECT * FROM turns WHERE session_id = ? ORDER BY id", (session_id,)
            ).fetchall()
            turns = [
                Turn(
                    role=Role(r["role"]),
                    content=r["content"],
                    name=r["name"],
                    tool_call_id=r["tool_call_id"],
                    timestamp=datetime.fromisoformat(r["timestamp"]),
                )
                for r in turns_rows
            ]
            return Session(
                id=row["id"],
                turns=turns,
                created_at=datetime.fromisoformat(row["created_at"]),
                metadata=json.loads(row["metadata"]),
            )

    def list_sessions(self, limit: int = 20) -> list[Session]:
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT id, created_at, metadata FROM sessions ORDER BY created_at DESC LIMIT ?",
                (limit,),
            ).fetchall()
            return [
                Session(
                    id=r["id"],
                    created_at=datetime.fromisoformat(r["created_at"]),
                    metadata=json.loads(r["metadata"]),
                )
                for r in rows
            ]

    def delete_session(self, session_id: str) -> bool:
        with self._connect() as conn:
            conn.execute("DELETE FROM turns WHERE session_id = ?", (session_id,))
            cursor = conn.execute("DELETE FROM sessions WHERE id = ?", (session_id,))
            return cursor.rowcount > 0
