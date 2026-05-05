from __future__ import annotations

from pathlib import Path

from harness.config.loader import (
    APP_SUPPORT_ENV_VAR,
    StorageConfig,
    _desktop_default_vault_candidates,
    load_config,
    session_store_db_path,
    state_store_db_path,
)


def test_default_storage_config_uses_application_support_dir(monkeypatch, tmp_path):
    monkeypatch.setenv(APP_SUPPORT_ENV_VAR, str(tmp_path))
    storage = StorageConfig()
    assert storage.sqlite_path == tmp_path / "data" / "memory" / "harness.db"


def test_session_store_db_path_uses_application_support_dir(monkeypatch, tmp_path):
    monkeypatch.setenv(APP_SUPPORT_ENV_VAR, str(tmp_path))
    assert session_store_db_path() == tmp_path / "data" / "memory" / "sessions.db"
    assert state_store_db_path() == tmp_path / "data" / "memory" / "harness.db"


def test_default_vault_candidates_are_generic():
    candidates = _desktop_default_vault_candidates()
    assert candidates == [
        Path.home() / "Documents" / "Laicai Vault",
        Path.home() / "Documents" / "Obsidian",
        Path.home() / "Obsidian",
    ]


def test_load_config_without_file_uses_env_vault_override(monkeypatch, tmp_path):
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("LAICAI_VAULT_PATH", str(tmp_path / "vault"))
    config = load_config()
    assert config.vault.path == (tmp_path / "vault").resolve()
