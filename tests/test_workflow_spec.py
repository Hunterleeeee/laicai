from pathlib import Path

import pytest

from harness.workflow.spec import WorkflowSpec, WorkflowStep


def test_workflow_spec_from_json(tmp_path: Path):
    json_path = tmp_path / "workflow.json"
    json_path.write_text(
        '{"name": "test", "description": "d", "steps": [{"name": "s1", "action": "prompt", "input": {"text": "hi"}}]}',
        encoding="utf-8",
    )
    spec = WorkflowSpec.from_file(json_path)
    assert spec.name == "test"
    assert spec.steps[0].action == "prompt"


def test_workflow_spec_from_toml(tmp_path: Path):
    toml_path = tmp_path / "workflow.toml"
    toml_path.write_text(
        'name = "test"\ndescription = "d"\n\n[[steps]]\nname = "s1"\naction = "prompt"\n\n[steps.input]\ntext = "hi"\n',
        encoding="utf-8",
    )
    spec = WorkflowSpec.from_file(toml_path)
    assert spec.name == "test"
    assert spec.steps[0].input["text"] == "hi"
