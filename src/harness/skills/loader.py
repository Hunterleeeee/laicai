from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import json


@dataclass
class VaultContextSpec:
    enabled: bool = False
    query_from: str = "goal"
    limit: int = 4


@dataclass
class WebFetchSpec:
    enabled: bool = False
    url_from: str = "manual"


@dataclass
class OutputSpec:
    save_by_default: bool = False
    folder: str | None = None
    title_template: str = "{{skill}} - {{goal}}"


@dataclass
class SkillStep:
    kind: str
    name: str | None = None
    query_from: str = "goal"
    url_from: str = "manual"
    limit: int | None = None
    chars: int | None = None
    folder: str | None = None
    save_by_default: bool | None = None
    max_tokens: int | None = None


@dataclass
class Skill:
    name: str
    description: str
    tools: list[str]
    path: Path
    prompt_template: str
    vault_context: VaultContextSpec
    web_fetch: WebFetchSpec
    output: OutputSpec
    steps: list[SkillStep]
    created_at: str = ""
    updated_at: str = ""
    staleness_days: float = 0.0
    fresh: bool = True

    def render(self, goal: str, extra_context: str = "", fetched_url: str = "", fetched_text: str = "") -> str:
        return (
            self.prompt_template
            .replace("{{goal}}", goal)
            .replace("{{extra_context}}", extra_context.strip())
            .replace("{{fetched_url}}", fetched_url.strip())
            .replace("{{fetched_text}}", fetched_text.strip())
        )

    def render_title(self, goal: str) -> str:
        short_goal = goal.strip()[:80] or self.name
        return (
            self.output.title_template
            .replace("{{skill}}", self.name)
            .replace("{{goal}}", short_goal)
        )


class SkillLoader:
    def __init__(self, skill_dirs: list[Path]) -> None:
        self.skill_dirs = skill_dirs

    def list_skills(self) -> list[Skill]:
        skills: list[Skill] = []
        for base_dir in self.skill_dirs:
            if not base_dir.exists():
                continue
            for skill_dir in sorted(path for path in base_dir.iterdir() if path.is_dir()):
                manifest = skill_dir / "skill.json"
                prompt = skill_dir / "prompt.md"
                if not manifest.exists() or not prompt.exists():
                    continue
                raw = json.loads(manifest.read_text(encoding="utf-8"))
                vault_context = VaultContextSpec(**raw.get("vault_context", {}))
                web_fetch = WebFetchSpec(**raw.get("web_fetch", {}))
                output = OutputSpec(**raw.get("output", {}))
                # Compute freshness from file stats
                from datetime import datetime, timezone
                import os
                stat = os.stat(manifest)
                created_at = datetime.fromtimestamp(stat.st_ctime, tz=timezone.utc).isoformat()
                updated_at = datetime.fromtimestamp(stat.st_mtime, tz=timezone.utc).isoformat()
                staleness_days = (datetime.now(timezone.utc) - datetime.fromtimestamp(stat.st_mtime, tz=timezone.utc)).total_seconds() / 86400
                fresh = staleness_days <= 30  # fresh if updated within 30 days
                skills.append(
                    Skill(
                        name=raw["name"],
                        description=raw["description"],
                        tools=raw.get("tools", []),
                        path=skill_dir,
                        prompt_template=prompt.read_text(encoding="utf-8"),
                        vault_context=vault_context,
                        web_fetch=web_fetch,
                        output=output,
                        steps=self._build_steps(raw=raw, vault_context=vault_context, web_fetch=web_fetch, output=output),
                        created_at=created_at,
                        updated_at=updated_at,
                        staleness_days=round(staleness_days, 1),
                        fresh=fresh,
                    )
                )
        return skills

    def get(self, name: str) -> Skill:
        for skill in self.list_skills():
            if skill.name == name:
                return skill
        raise KeyError(f"Unknown skill: {name}")

    def _build_steps(
        self,
        raw: dict[str, object],
        vault_context: VaultContextSpec,
        web_fetch: WebFetchSpec,
        output: OutputSpec,
    ) -> list[SkillStep]:
        raw_steps = raw.get("steps")
        if isinstance(raw_steps, list) and raw_steps:
            return [SkillStep(**item) for item in raw_steps if isinstance(item, dict)]

        steps: list[SkillStep] = []
        if vault_context.enabled:
            steps.append(
                SkillStep(
                    kind="vault_context",
                    name="vault-context",
                    query_from=vault_context.query_from,
                    limit=vault_context.limit,
                )
            )
        if web_fetch.enabled:
            steps.append(
                SkillStep(
                    kind="web_fetch",
                    name="web-fetch",
                    url_from=web_fetch.url_from,
                )
            )
        steps.append(SkillStep(kind="prompt", name="prompt"))
        steps.append(
            SkillStep(
                kind="save_note",
                name="save-note",
                folder=output.folder,
                save_by_default=output.save_by_default,
            )
        )
        return steps
