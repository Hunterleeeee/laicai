from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path

from pydantic import BaseModel, Field


class WorkflowStep(BaseModel):
    name: str
    action: str
    input: dict[str, str] = Field(default_factory=dict)


class WorkflowSpec(BaseModel):
    name: str
    description: str
    steps: list[WorkflowStep]
    generate_contract: bool = Field(default=True, description="Whether to generate acceptance criteria before execution")
    contract: list[str] = Field(default_factory=list, description="Pre-defined acceptance criteria (optional)")
    created_at: str = ""
    updated_at: str = ""
    staleness_days: float = 0.0
    fresh: bool = True

    @classmethod
    def from_file(cls, path: Path) -> "WorkflowSpec":
        text = path.read_text(encoding="utf-8")
        if path.suffix.lower() == ".json":
            data = json.loads(text)
        elif path.suffix.lower() == ".toml":
            import tomllib
            data = tomllib.loads(text)
        else:
            # Markdown with frontmatter
            import re
            frontmatter_match = re.search(r'^---\s*\n(.*?)\n---\s*\n', text, re.DOTALL)
            if frontmatter_match:
                import tomllib
                try:
                    data = tomllib.loads(frontmatter_match.group(1))
                except Exception:
                    data = {"name": path.stem, "description": "", "steps": []}
                # Extract steps from body (numbered list)
                body = text[frontmatter_match.end():]
                steps = []
                for line in body.strip().split('\n'):
                    match = re.match(r'^\s*\d+\.\s*(.+)$', line)
                    if match:
                        steps.append({"name": f"step_{len(steps)}", "action": "prompt", "input": {"prompt": match.group(1)}})
                if steps:
                    data["steps"] = steps
            else:
                data = {"name": path.stem, "description": "", "steps": []}
        spec = cls.model_validate(data)
        # Compute freshness from file stats
        stat = os.stat(path)
        spec.created_at = datetime.fromtimestamp(stat.st_ctime, tz=timezone.utc).isoformat()
        spec.updated_at = datetime.fromtimestamp(stat.st_mtime, tz=timezone.utc).isoformat()
        spec.staleness_days = round((datetime.now(timezone.utc) - datetime.fromtimestamp(stat.st_mtime, tz=timezone.utc)).total_seconds() / 86400, 1)
        spec.fresh = spec.staleness_days <= 30
        return spec
