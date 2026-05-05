from __future__ import annotations

from harness.config import VaultConfig
from harness.vault import VaultAdapter


def test_ensure_layout_creates_folders(tmp_path):
    vault = VaultAdapter(VaultConfig(path=tmp_path))
    vault.ensure_layout()
    assert (tmp_path / "00 Inbox").exists()
    assert (tmp_path / "01 Sources").exists()
    assert (tmp_path / "02 Notes").exists()
    assert (tmp_path / "06 Memory").exists()


def test_create_note(tmp_path):
    vault = VaultAdapter(VaultConfig(path=tmp_path))
    note = vault.create_note(title="Hello World", body="This is a test note.")
    assert note.path.exists()
    content = note.path.read_text(encoding="utf-8")
    assert "Hello World" in content
    assert "This is a test note." in content
    assert "title: \"Hello World\"" in content


def test_create_note_with_frontmatter(tmp_path):
    vault = VaultAdapter(VaultConfig(path=tmp_path))
    note = vault.create_note(
        title="Test",
        body="Body",
        folder="02 Notes",
        frontmatter={"tags": ["test", "demo"]},
    )
    content = note.path.read_text(encoding="utf-8")
    assert "test\"" in content
    assert "demo\"" in content


def test_upsert_topic_note_is_stable(tmp_path):
    vault = VaultAdapter(VaultConfig(path=tmp_path))
    first = vault.upsert_topic_note(title="Python", body="First body")
    second = vault.upsert_topic_note(title="Python", body="Second body")
    assert first.path == second.path
    assert first.path.name == "python.md"
    content = second.path.read_text(encoding="utf-8")
    assert "Second body" in content
    assert "# Python" in content


def test_render_topic_note_does_not_write(tmp_path):
    vault = VaultAdapter(VaultConfig(path=tmp_path))
    target, payload = vault.render_topic_note(title="Python", body="Body", frontmatter={"type": "topic"})
    assert target == tmp_path / "03 Topics" / "python.md"
    assert not target.exists()
    assert 'title: "Python"' in payload
    assert 'type: "topic"' in payload
    assert "# Python" in payload


def test_slugify_special_chars():
    from harness.vault.obsidian import slugify
    assert slugify("Hello World!!!") == "hello-world"
    # CJK characters are preserved; the function normalizes accents but does not strip CJK
    assert slugify("测试-Test") == "测试-test"
    assert slugify("") == "untitled"
