from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import json
import re


def _slugify(value: str) -> str:
    cleaned = re.sub(r"[^\w\s-]", "", value, flags=re.UNICODE).strip().lower()
    return re.sub(r"[-\s]+", "-", cleaned) or "custom-skill"


@dataclass
class SkillDraft:
    name: str
    description: str
    prompt_template: str
    manifest: dict[str, object]


class SkillAuthor:
    def create_draft(self, request: str, name: str | None = None, root_dir: Path | None = None) -> SkillDraft:
        normalized = request.strip()
        if not normalized:
            raise ValueError("Skill request cannot be empty.")

        skill_name = self.resolve_name(
            request=normalized,
            explicit_name=name,
            root_dir=root_dir,
        )
        description = self._infer_description(normalized)
        tools = self._infer_tools(normalized)
        steps = self._infer_steps(normalized)
        output = self._infer_output(normalized)
        prompt_template = self._build_prompt_template(skill_name=skill_name, request=normalized)

        manifest = {
            "name": skill_name,
            "description": description,
            "tools": tools,
            "steps": steps,
            "vault_context": {
                "enabled": any(step["kind"] == "vault_context" for step in steps),
                "query_from": "goal",
                "limit": next((step.get("limit", 4) for step in steps if step["kind"] == "vault_context"), 4),
            },
            "web_fetch": {
                "enabled": any(step["kind"] == "web_fetch" for step in steps),
                "url_from": "manual",
            },
            "output": output,
        }
        return SkillDraft(
            name=skill_name,
            description=description,
            prompt_template=prompt_template,
            manifest=manifest,
        )

    def write_skill(self, target_dir: Path, draft: SkillDraft) -> Path:
        target_dir.mkdir(parents=True, exist_ok=True)
        manifest_path = target_dir / "skill.json"
        prompt_path = target_dir / "prompt.md"
        manifest_path.write_text(json.dumps(draft.manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        prompt_path.write_text(draft.prompt_template, encoding="utf-8")
        return target_dir

    def publish_draft(self, draft_dir: Path, root_dir: Path, published_name: str | None = None) -> Path:
        if not draft_dir.exists() or not draft_dir.is_dir():
            raise FileNotFoundError(f"Draft skill not found: {draft_dir}")
        manifest_path = draft_dir / "skill.json"
        prompt_path = draft_dir / "prompt.md"
        if not manifest_path.exists() or not prompt_path.exists():
            raise ValueError(f"Draft skill is incomplete: {draft_dir}")

        raw = json.loads(manifest_path.read_text(encoding="utf-8"))
        current_name = str(raw.get("name", draft_dir.name))
        base_name = published_name or current_name.removeprefix("draft-") or draft_dir.name.removeprefix("draft-")
        final_name = self._ensure_unique_name(base_name, {path.name for path in root_dir.iterdir() if path.is_dir() and path != draft_dir})
        raw["name"] = final_name
        manifest_path.write_text(json.dumps(raw, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

        target_dir = root_dir / final_name
        draft_dir.rename(target_dir)
        return target_dir

    def resolve_name(self, request: str, explicit_name: str | None = None, root_dir: Path | None = None) -> str:
        base_name = explicit_name or self._infer_name(request)
        if root_dir is None:
            return base_name
        existing = {path.name for path in root_dir.iterdir() if path.is_dir()} if root_dir.exists() else set()
        if explicit_name:
            return self._ensure_unique_name(base_name, existing)
        draft_base = base_name if base_name.startswith("draft-") else f"draft-{base_name}"
        return self._ensure_unique_name(draft_base, existing)

    def _ensure_unique_name(self, base_name: str, existing_names: set[str]) -> str:
        if base_name not in existing_names:
            return base_name
        index = 2
        while True:
            candidate = f"{base_name}-{index}"
            if candidate not in existing_names:
                return candidate
            index += 1

    def _infer_name(self, request: str) -> str:
        explicit = re.search(r"(?:名字|叫|命名为|name)\s*[:：]?\s*([A-Za-z0-9_-]{3,40})", request, flags=re.IGNORECASE)
        if explicit:
            return explicit.group(1)

        if any(token in request for token in ("日报", "daily", "daily brief")):
            return "daily-brief"
        if any(token in request for token in ("网站", "网页", "web", "url", "站点")):
            return "website-research"
        if any(token in request for token in ("记忆", "经验", "复盘", "memory")):
            return "project-memory-update"

        words = re.findall(r"[A-Za-z0-9\u4e00-\u9fff]+", request)
        return _slugify("-".join(words[:4]))

    def _infer_description(self, request: str) -> str:
        base = request.strip().rstrip("。.")
        if len(base) <= 120:
            return base[0].upper() + base[1:] if len(base) > 1 else base
        return base[:117] + "..."

    def _infer_tools(self, request: str) -> list[str]:
        tools: list[str] = []
        if any(token in request.lower() for token in ("网页", "网站", "web", "url", "http", "链接", "link")):
            tools.append("web.fetch")
        if any(token in request.lower() for token in ("知识库", "vault", "obsidian", "笔记", "记忆", "memory", "项目")):
            tools.append("vault.search")
        if any(token in request.lower() for token in ("保存", "写回", "落库", "存到", "save", "capture", "笔记", "note", "记忆")):
            tools.append("vault.capture")
        if not tools:
            tools.append("vault.capture")
        return tools

    def _infer_steps(self, request: str) -> list[dict[str, object]]:
        lowered = request.lower()
        steps: list[dict[str, object]] = []

        if any(token in lowered for token in ("知识库", "vault", "obsidian", "笔记", "记忆", "memory", "项目")):
            steps.append(
                {
                    "kind": "vault_context",
                    "name": "vault-context",
                    "query_from": "goal",
                    "limit": 4,
                }
            )

        if any(token in lowered for token in ("网页", "网站", "web", "url", "http", "链接", "link")):
            steps.append(
                {
                    "kind": "web_fetch",
                    "name": "web-fetch",
                    "url_from": "manual",
                    "chars": 1600,
                }
            )

        steps.append(
            {
                "kind": "prompt",
                "name": "prompt",
                "max_tokens": 160,
            }
        )

        steps.append(
            {
                "kind": "save_note",
                "name": "save-note",
                "folder": self._infer_folder(request),
                "save_by_default": self._infer_save_default(request),
            }
        )
        return steps

    def _infer_output(self, request: str) -> dict[str, object]:
        return {
            "save_by_default": self._infer_save_default(request),
            "folder": self._infer_folder(request),
            "title_template": "{{skill}} - {{goal}}",
        }

    def _infer_folder(self, request: str) -> str:
        lowered = request.lower()
        if any(token in lowered for token in ("记忆", "经验", "复盘", "memory")):
            return "06 Memory"
        if any(token in lowered for token in ("来源", "source", "pdf", "文档导入")):
            return "01 Sources"
        return "02 Notes"

    def _infer_save_default(self, request: str) -> bool:
        lowered = request.lower()
        return any(token in lowered for token in ("保存", "写回", "落库", "存到", "默认保存", "记忆", "日报", "note"))

    def _build_prompt_template(self, skill_name: str, request: str) -> str:
        rule_lines = [
            "- Be concise and practical.",
            "- Use the goal as the main task boundary.",
            "- Prefer reusable output that can be stored in Obsidian.",
            "- Call out uncertainty clearly.",
        ]
        if any(token in request.lower() for token in ("网页", "网站", "web", "url", "http", "链接", "link")):
            rule_lines.append("- When fetched page text exists, prioritize it over vague prior assumptions.")
        if any(token in request.lower() for token in ("知识库", "vault", "obsidian", "笔记", "记忆", "memory", "项目")):
            rule_lines.append("- Use vault context as supporting evidence, not as a substitute for the requested task.")

        return (
            f"You are running the `{skill_name}` skill.\n\n"
            "Goal:\n"
            "{{goal}}\n\n"
            "Skill request:\n"
            f"{request.strip()}\n\n"
            "Rules:\n"
            + "\n".join(rule_lines)
            + "\n\n"
            "Extra context:\n"
            "{{extra_context}}\n\n"
            "Fetched URL:\n"
            "{{fetched_url}}\n\n"
            "Fetched page text:\n"
            "{{fetched_text}}\n"
        )
