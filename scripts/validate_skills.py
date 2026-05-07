#!/usr/bin/env python3
import json
import pathlib
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
SKILLS_DIR = ROOT / "skills"
CANONICAL_TOP_LEVEL = {
    "name",
    "description",
    "tools",
    "steps",
    "vault_context",
    "web_fetch",
    "output",
}
LEGACY_KEYS = {"parameters", "arguments", "requires", "promptFile", "schema_version", "commandSample"}
STEP_KINDS = {"vault_context", "web_fetch", "prompt", "save_note"}


def error(message: str) -> None:
    errors.append(message)


errors: list[str] = []

if not SKILLS_DIR.exists():
    error(f"{SKILLS_DIR}: missing skills directory")
else:
    seen_names: set[str] = set()
    manifests = sorted(SKILLS_DIR.glob("*/skill.json"))
    if not manifests:
        error("skills: no skill manifests found")

    for manifest in manifests:
        rel = manifest.relative_to(ROOT)
        if manifest.stat().st_size == 0:
            error(f"{rel}: empty skill.json")
            continue

        try:
            data = json.loads(manifest.read_text(encoding="utf-8"))
        except Exception as exc:
            error(f"{rel}: invalid json: {exc}")
            continue

        unknown = set(data) - CANONICAL_TOP_LEVEL
        legacy = set(data) & LEGACY_KEYS
        if legacy:
            error(f"{rel}: legacy keys are not allowed in bundled skills: {', '.join(sorted(legacy))}")
        if unknown:
            error(f"{rel}: unknown top-level keys: {', '.join(sorted(unknown))}")

        name = data.get("name")
        if not isinstance(name, str) or not name.strip():
            error(f"{rel}: missing non-empty name")
        elif name in seen_names:
            error(f"{rel}: duplicate skill name {name}")
        else:
            seen_names.add(name)

        if not isinstance(data.get("description"), str) or not data["description"].strip():
            error(f"{rel}: missing non-empty description")

        tools = data.get("tools")
        if not isinstance(tools, list) or any(not isinstance(item, str) or not item for item in tools):
            error(f"{rel}: tools must be a string array")

        steps = data.get("steps")
        if not isinstance(steps, list) or not steps:
            error(f"{rel}: steps must be a non-empty array")
        else:
            for index, step in enumerate(steps):
                if not isinstance(step, dict):
                    error(f"{rel}: steps[{index}] must be an object")
                    continue
                kind = step.get("kind")
                if kind not in STEP_KINDS:
                    error(f"{rel}: steps[{index}].kind must be one of {', '.join(sorted(STEP_KINDS))}")
                if not isinstance(step.get("name"), str) or not step["name"].strip():
                    error(f"{rel}: steps[{index}].name must be non-empty")

        for config_key in ("vault_context", "web_fetch", "output"):
            if config_key in data and not isinstance(data[config_key], dict):
                error(f"{rel}: {config_key} must be an object")

        prompt = manifest.parent / "prompt.md"
        if not prompt.exists():
            error(f"{rel}: missing prompt.md")
        elif prompt.stat().st_size == 0:
            error(f"{prompt.relative_to(ROOT)}: empty prompt.md")

if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)

print("skills ok")
