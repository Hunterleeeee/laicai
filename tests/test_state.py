from __future__ import annotations

from pathlib import Path

from harness.storage import StateStore


def test_init_db(tmp_db):
    store = StateStore(tmp_db)
    assert tmp_db.exists()


def test_create_session(tmp_db):
    store = StateStore(tmp_db)
    session = store.create_session(title="Test Session")
    assert session.id == 1
    assert session.title == "Test Session"
    assert session.model_mode == "auto"


def test_get_session(tmp_db):
    store = StateStore(tmp_db)
    created = store.create_session(title="Foo")
    fetched = store.get_session(created.id)
    assert fetched.title == "Foo"


def test_update_session(tmp_db):
    store = StateStore(tmp_db)
    session = store.create_session(title="Original")
    updated = store.update_session(session.id, status="done", model_mode="manual")
    assert updated.status == "done"
    assert updated.model_mode == "manual"


def test_record_turn(tmp_db):
    store = StateStore(tmp_db)
    session = store.create_session(title="Turn Test")
    turn_id = store.record_turn(session.id, "user", "hello", intent="ask")
    assert turn_id == 1


def test_record_note(tmp_db):
    store = StateStore(tmp_db)
    note_id = store.record_note(title="Note", path=Path("/tmp/note.md"), kind="answer")
    assert note_id == 1


def test_latest_session(tmp_db):
    store = StateStore(tmp_db)
    store.create_session(title="First")
    store.create_session(title="Second")
    latest = store.latest_session()
    assert latest is not None
    assert latest.title == "Second"


def test_document_dedup_by_hash(tmp_db):
    store = StateStore(tmp_db)
    doc_id1 = store.record_document(
        title="Doc",
        source_path="/tmp/doc.pdf",
        source_type="pdf",
        mime_type="application/pdf",
        content="same content",
    )
    doc_id2 = store.record_document(
        title="Doc",
        source_path="/tmp/doc.pdf",
        source_type="pdf",
        mime_type="application/pdf",
        content="same content",
    )
    assert doc_id1 == doc_id2


def test_replace_and_list_chunks(tmp_db):
    store = StateStore(tmp_db)
    doc_id = store.record_document(
        title="Chunked",
        source_path="/tmp/c.txt",
        source_type="text",
        mime_type="text/plain",
        content="content",
    )
    store.replace_document_chunks(doc_id, ["chunk one", "chunk two"])
    chunks = store.list_document_chunks(limit=10)
    assert len(chunks) == 2
    assert chunks[0].chunk_index == 0
    assert chunks[1].chunk_index == 1
