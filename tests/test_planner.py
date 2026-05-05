from __future__ import annotations

from harness.agent.planner import Planner, TaskPlan


def test_plan_returns_tools_and_reasoning():
    planner = Planner()
    plan = planner.plan("Fetch https://example.com and save notes")
    assert isinstance(plan, TaskPlan)
    assert plan.goal == "Fetch https://example.com and save notes"
    assert len(plan.steps) >= 2
    assert any(t.name == "web_fetch" for t in plan.tools)
    assert any(t.name == "save_note" for t in plan.tools)
    assert "https" in plan.reasoning.lower() or "url" in plan.reasoning.lower()


def test_plan_with_available_tools_filtering():
    planner = Planner()
    plan = planner.plan("Fetch https://example.com and save notes", available_tools=["vault_context", "save_note"])
    # web_fetch should be excluded because not in available_tools
    assert "web_fetch" not in {t.name for t in plan.tools}
    assert "save_note" in {t.name for t in plan.tools}


def test_plan_learning_task_signals():
    planner = Planner()
    plan = planner.plan("给我做一个学习计划")
    assert any(t.name == "learning_task" for t in plan.tools)
    assert any("learning artifact" in s.lower() for s in plan.steps)


def test_plan_default_ask():
    planner = Planner()
    plan = planner.plan("随便说两句")
    assert plan.tools == [] or all(t.confidence < 0.7 for t in plan.tools)
    assert "direct ask" in plan.reasoning.lower() or "defaulting" in plan.reasoning.lower()


def test_taskplan_steps_accessible():
    planner = Planner()
    plan = planner.plan("Test goal")
    # Ensure backward compatibility with orchestrator that only accesses .steps
    assert isinstance(plan.steps, list)
    assert len(plan.steps) >= 1
