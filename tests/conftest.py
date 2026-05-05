from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

import pytest

if sys.version_info < (3, 11):
    pytest.skip(
        "Laicai requires Python 3.11+; install test dependencies in a supported interpreter.",
        allow_module_level=True,
    )


@pytest.fixture
def tmp_vault():
    with tempfile.TemporaryDirectory() as tmpdir:
        vault = Path(tmpdir) / "vault"
        vault.mkdir()
        yield vault


@pytest.fixture
def tmp_db():
    with tempfile.TemporaryDirectory() as tmpdir:
        db = Path(tmpdir) / "test.db"
        yield db


@pytest.fixture
def tmp_skills_dir():
    with tempfile.TemporaryDirectory() as tmpdir:
        skills = Path(tmpdir) / "skills"
        skills.mkdir()
        yield skills


@pytest.fixture
def mock_config(tmp_vault, tmp_db, tmp_skills_dir):
    os.environ["LAICAI_HOME"] = str(tmp_vault.parent)
    from harness.config import HarnessConfig, VaultConfig, RuntimeConfig, ModelConfig
    from harness.config.loader import StorageConfig, SkillsConfig
    return HarnessConfig(
        vault=VaultConfig(path=tmp_vault),
        runtime=RuntimeConfig(workspace_root=tmp_vault.parent),
        storage=StorageConfig(sqlite_path=tmp_db),
        skills=SkillsConfig(dirs=[tmp_skills_dir]),
        model=ModelConfig(),
    )
