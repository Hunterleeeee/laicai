from __future__ import annotations

from pathlib import Path

from harness.workflow import WorkflowSpec, WorkflowStep, WorkflowExecutor, WorkflowRunResult


def test_workflow_executor_prompt_only(tmp_path):
    """Workflow with a single prompt step should run and produce output."""
    spec = WorkflowSpec(
        name="echo",
        description="Echo workflow",
        steps=[
            WorkflowStep(name="prompt", action="prompt", input={"prompt": "Goal: {{goal}}", "max_tokens": "10"}),
        ],
    )
    # Use a mock model that echoes back
    class FakeModel:
        def complete(self, prompt, max_tokens=None):
            from harness.models.runtime import ModelResponse
            return ModelResponse(content=prompt, ok=True)

    executor = WorkflowExecutor(model=FakeModel())
    result = executor.run(spec, goal="hello")
    assert result.ok
    assert len(result.steps) == 1
    assert result.steps[0].status == "ok"


def test_workflow_save_note(tmp_path):
    from harness.config import VaultConfig
    from harness.vault import VaultAdapter

    vault = VaultAdapter(VaultConfig(path=tmp_path))
    spec = WorkflowSpec(
        name="save_test",
        description="Save a note",
        steps=[
            WorkflowStep(name="prompt", action="prompt", input={"prompt": "Test", "max_tokens": "10"}),
            WorkflowStep(name="save", action="save_note", input={"title": "Test Note", "body": "{{prompt_output}}", "folder": "02 Notes"}),
        ],
    )

    class FakeModel:
        def complete(self, prompt, max_tokens=None):
            from harness.models.runtime import ModelResponse
            return ModelResponse(content="Generated text", ok=True)

    executor = WorkflowExecutor(vault=vault, model=FakeModel())
    result = executor.run(spec, goal="test")
    assert result.ok
    assert result.steps[-1].status == "ok"
    assert result.steps[-1].saved_path is not None
    saved = Path(result.steps[-1].saved_path)
    assert saved.exists()


def test_workflow_unknown_action():
    spec = WorkflowSpec(
        name="bad",
        description="Bad action",
        steps=[WorkflowStep(name="bad", action="nonexistent_action", input={})],
    )
    executor = WorkflowExecutor()
    result = executor.run(spec)
    assert not result.ok
    assert result.steps[0].status == "failed"
    assert "unknown action" in result.steps[0].error.lower()


def test_workflow_vault_context_skipped_without_vault():
    spec = WorkflowSpec(
        name="vault_test",
        description="Vault context",
        steps=[WorkflowStep(name="ctx", action="vault_context", input={"query": "test", "limit": "3"})],
    )
    executor = WorkflowExecutor()
    result = executor.run(spec)
    assert result.steps[0].status == "skipped"


def test_workflow_web_fetch_skipped_without_web():
    spec = WorkflowSpec(
        name="web_test",
        description="Web fetch",
        steps=[WorkflowStep(name="web", action="web_fetch", input={"url": "https://example.com"})],
    )
    executor = WorkflowExecutor()
    result = executor.run(spec)
    assert result.steps[0].status == "skipped"
