"""Tests for learning tools registration and invocation."""

import pytest
from pathlib import Path

from harness.agent.tools import SimpleToolRegistry
from harness.agent.learning_tools import register_learning_tools


@pytest.fixture
def registry_with_vault(tmp_path: Path):
    # create a tiny vault
    note = tmp_path / "python-basics.md"
    note.write_text("# Python Basics\nVariables, loops, functions.\n", encoding="utf-8")

    reg = SimpleToolRegistry()
    register_learning_tools(reg, vault_root=tmp_path)
    return reg


def test_learning_tools_registered(registry_with_vault: SimpleToolRegistry):
    names = [t.name for t in registry_with_vault.list_tools()]
    assert "generate_quiz" in names
    assert "generate_flashcards" in names
    assert "create_study_plan" in names
    assert "review_notes" in names
    assert "daily_review" in names


@pytest.mark.asyncio
async def test_generate_quiz(registry_with_vault: SimpleToolRegistry):
    result = await registry_with_vault.call("generate_quiz", {"topic": "Python"})
    assert result.success is True
    assert "quiz" in result.content.lower() or "questions" in result.content.lower()


@pytest.mark.asyncio
async def test_generate_flashcards(registry_with_vault: SimpleToolRegistry):
    result = await registry_with_vault.call("generate_flashcards", {"topic": "Python", "count": 3})
    assert result.success is True
    assert "flashcard" in result.content.lower() or "card" in result.content.lower()


@pytest.mark.asyncio
async def test_create_study_plan(registry_with_vault: SimpleToolRegistry):
    result = await registry_with_vault.call("create_study_plan", {
        "topic": "Python", "days": 3, "level": "beginner",
    })
    assert result.success is True
    assert "study plan" in result.content.lower() or "day" in result.content.lower()


@pytest.mark.asyncio
async def test_daily_review(registry_with_vault: SimpleToolRegistry):
    result = await registry_with_vault.call("daily_review", {})
    assert result.success is True
    assert "review" in result.content.lower() or "python" in result.content.lower()


@pytest.mark.asyncio
async def test_review_notes_no_vault():
    reg = SimpleToolRegistry()
    register_learning_tools(reg, vault_root=None)
    result = await reg.call("review_notes", {"topic": "anything"})
    assert "No vault" in result.content
