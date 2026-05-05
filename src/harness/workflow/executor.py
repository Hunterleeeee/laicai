from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING

from harness.workflow.spec import WorkflowSpec, WorkflowStep

if TYPE_CHECKING:
    from harness.vault import VaultAdapter
    from harness.models import LocalModelRuntime
    from harness.skills import SkillLoader
    from harness.tools import WebFetcher


@dataclass
class ExecutionResult:
    step_name: str
    action: str
    status: str  # ok | skipped | failed
    output: str = ""
    saved_path: str | None = None
    error: str | None = None


@dataclass
class WorkflowRunResult:
    workflow_name: str
    steps: list[ExecutionResult] = field(default_factory=list)
    ok: bool = True
    contract: list[str] = field(default_factory=list)
    contract_verification: dict[str, str] = field(default_factory=dict)
    contract_generated: bool = False


class WorkflowExecutor:
    """Execute a WorkflowSpec using available runtime services."""

    def __init__(
        self,
        *,
        vault: VaultAdapter | None = None,
        web: WebFetcher | None = None,
        model: LocalModelRuntime | None = None,
        skills: SkillLoader | None = None,
    ) -> None:
        self.vault = vault
        self.web = web
        self.model = model
        self.skills = skills
        self._context: dict[str, str] = {}

    def run(self, spec: WorkflowSpec, goal: str = "") -> WorkflowRunResult:
        self._context = {"goal": goal}

        # Sprint contract generation
        contract: list[str] = list(spec.contract)
        contract_generated = False
        if spec.generate_contract and not contract and self.model is not None:
            generated = self._generate_contract(spec, goal)
            if generated:
                contract = generated
                contract_generated = True
        self._context["contract"] = "\n".join(contract)

        results: list[ExecutionResult] = []
        overall_ok = True
        for step in spec.steps:
            result = self._execute_step(step)
            results.append(result)
            if result.status == "failed":
                overall_ok = False
                if step.action == "stop_on_error":
                    break

        # Contract verification
        contract_verification = self._verify_contract(contract, results)

        return WorkflowRunResult(
            workflow_name=spec.name,
            steps=results,
            ok=overall_ok,
            contract=contract,
            contract_verification=contract_verification,
            contract_generated=contract_generated,
        )

    def _execute_step(self, step: WorkflowStep) -> ExecutionResult:
        handler = getattr(self, f"_handle_{step.action}", None)
        if handler is None:
            return ExecutionResult(
                step_name=step.name,
                action=step.action,
                status="failed",
                error=f"Unknown action: {step.action}",
            )
        try:
            return handler(step)
        except Exception as exc:
            return ExecutionResult(
                step_name=step.name,
                action=step.action,
                status="failed",
                error=str(exc),
            )

    def _handle_vault_context(self, step: WorkflowStep) -> ExecutionResult:
        if self.vault is None:
            return ExecutionResult(step_name=step.name, action=step.action, status="skipped", error="Vault not available")
        query = step.input.get("query", self._context.get("goal", ""))
        limit = int(step.input.get("limit", "3"))
        from harness.rag import VaultIndex
        index = VaultIndex(self.vault.root)
        docs = index.search(query, limit=limit)
        context = "\n\n".join(f"{doc.path}:\n{doc.preview}" for doc in docs)
        self._context["vault_context"] = context
        return ExecutionResult(
            step_name=step.name,
            action=step.action,
            status="ok",
            output=f"Retrieved {len(docs)} notes",
        )

    def _handle_web_fetch(self, step: WorkflowStep) -> ExecutionResult:
        if self.web is None:
            return ExecutionResult(step_name=step.name, action=step.action, status="skipped", error="Web fetcher not available")
        url = step.input.get("url", self._context.get("url", ""))
        if not url:
            return ExecutionResult(step_name=step.name, action=step.action, status="skipped", error="No URL provided")
        page = self.web.fetch(url, use_browser=step.input.get("browser", "true").lower() == "true")
        self._context["fetched_url"] = page.url
        self._context["fetched_text"] = page.text
        return ExecutionResult(
            step_name=step.name,
            action=step.action,
            status="ok",
            output=f"Fetched {page.url} ({len(page.text)} chars)",
        )

    def _handle_prompt(self, step: WorkflowStep) -> ExecutionResult:
        if self.model is None:
            return ExecutionResult(step_name=step.name, action=step.action, status="skipped", error="Model not available")
        prompt_template = step.input.get("prompt", "{{goal}}")
        prompt = self._render(prompt_template)
        max_tokens = int(step.input.get("max_tokens", "160"))
        response = self.model.complete(prompt, max_tokens=max_tokens)
        self._context["prompt_output"] = response.content
        return ExecutionResult(
            step_name=step.name,
            action=step.action,
            status="ok" if response.ok else "failed",
            output=response.content,
            error=None if response.ok else "Model returned empty or failed",
        )

    def _handle_save_note(self, step: WorkflowStep) -> ExecutionResult:
        if self.vault is None:
            return ExecutionResult(step_name=step.name, action=step.action, status="skipped", error="Vault not available")
        title_template = step.input.get("title", "Workflow Output")
        title = self._render(title_template)
        body = self._render(step.input.get("body", "{{prompt_output}}"))
        folder = step.input.get("folder", "02 Notes")
        note = self.vault.create_note(title=title, body=body, folder=folder)
        self._context["saved_path"] = str(note.path)
        return ExecutionResult(
            step_name=step.name,
            action=step.action,
            status="ok",
            output=f"Saved to {note.path}",
            saved_path=str(note.path),
        )

    def _handle_run_skill(self, step: WorkflowStep) -> ExecutionResult:
        if self.skills is None or self.model is None:
            return ExecutionResult(step_name=step.name, action=step.action, status="skipped", error="Skills or model not available")
        skill_name = step.input.get("skill", "")
        try:
            skill = self.skills.get(skill_name)
        except KeyError:
            return ExecutionResult(step_name=step.name, action=step.action, status="failed", error=f"Skill not found: {skill_name}")
        from harness.skills import SkillRunner, SkillRunRequest
        from harness.config import RuntimeConfig
        runner = SkillRunner(
            vault=self.vault,
            web=self.web,
            model=self.model,
            runtime=RuntimeConfig(),
        )
        goal = self._render(step.input.get("goal", "{{goal}}"))
        result = runner.run(skill, SkillRunRequest(goal=goal))
        self._context["skill_output"] = result.output
        return ExecutionResult(
            step_name=step.name,
            action=step.action,
            status="ok" if result.ok else "failed",
            output=result.output,
            saved_path=result.saved_path,
        )

    def _generate_contract(self, spec: WorkflowSpec, goal: str) -> list[str] | None:
        """Ask the model to generate acceptance criteria for this workflow."""
        step_descriptions = "\n".join(
            f"- {step.name} ({step.action}): {step.input.get('prompt', '') or step.input.get('query', '') or step.input.get('skill', '')}"
            for step in spec.steps
        )
        prompt = (
            f"You are a technical evaluator. Given the following workflow goal and steps, "
            f"generate 3-8 concise acceptance criteria that would prove the workflow succeeded. "
            f"Each criterion should be a single, verifiable statement.\n\n"
            f"Goal: {goal or spec.description}\n\n"
            f"Steps:\n{step_descriptions}\n\n"
            f"Return ONLY a numbered list of criteria, one per line. No extra commentary."
        )
        try:
            response = self.model.complete(prompt, max_tokens=400)
            if not response.ok:
                return None
            text = response.content or ""
            criteria: list[str] = []
            for line in text.strip().split("\n"):
                line = line.strip()
                if not line:
                    continue
                # Remove numbering prefix like "1. " or "- "
                cleaned = line
                if cleaned[0:2] in ("- ", "* "):
                    cleaned = cleaned[2:]
                elif ". " in cleaned[:4]:
                    cleaned = cleaned.split(". ", 1)[1]
                cleaned = cleaned.strip()
                if cleaned:
                    criteria.append(cleaned)
            return criteria[:10]
        except Exception:
            return None

    def _verify_contract(self, contract: list[str], results: list[ExecutionResult]) -> dict[str, str]:
        """Lightweight verification: match criterion keywords against step outputs."""
        all_outputs = "\n".join(r.output for r in results if r.output)
        verification: dict[str, str] = {}
        for criterion in contract:
            keywords = [w.lower() for w in criterion.split() if len(w) > 3]
            if not keywords:
                verification[criterion] = "unknown"
                continue
            matches = sum(1 for kw in keywords if kw in all_outputs.lower())
            verification[criterion] = "pass" if matches >= max(1, len(keywords) // 2) else "fail"
        return verification

    def _render(self, template: str) -> str:
        result = template
        for key, value in self._context.items():
            result = result.replace(f"{{{{{key}}}}}", str(value))
        return result
