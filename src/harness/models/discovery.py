from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError
import json


@dataclass
class ModelHealth:
    endpoint: str
    reachable: bool
    version: str | None
    tags_count: int | None
    error: str | None
    provider: str | None = None


def discover_ollama_models(root: Path | None = None) -> list[str]:
    manifests_root = (root or Path.home() / ".ollama" / "models" / "manifests").expanduser()
    if not manifests_root.exists():
        return []

    models: list[str] = []
    for manifest in manifests_root.rglob("*"):
        if not manifest.is_file():
            continue
        relative = manifest.relative_to(manifests_root)
        parts = list(relative.parts)
        if len(parts) < 4 or parts[0] != "registry.ollama.ai" or parts[1] != "library":
            continue
        model_name = "/".join(parts[2:-1])
        tag = parts[-1]
        models.append(f"{model_name}:{tag}")
    return sorted(set(models))


def check_ollama_endpoint(endpoint: str) -> ModelHealth:
    base = endpoint.rstrip("/")
    if base.endswith("/v1"):
        base = base[:-3]

    version_url = base + "/api/version"
    tags_url = base + "/api/tags"
    version: str | None = None
    tags_count: int | None = None
    try:
        with urlopen(version_url, timeout=3) as response:
            version_payload = json.loads(response.read().decode("utf-8"))
        with urlopen(tags_url, timeout=3) as response:
            tags_payload = json.loads(response.read().decode("utf-8"))
        version = version_payload.get("version")
        tags_count = len(tags_payload.get("models", []))
        return ModelHealth(endpoint=base, reachable=True, version=version, tags_count=tags_count, provider="ollama", error=None)
    except (URLError, HTTPError, TimeoutError, json.JSONDecodeError) as exc:
        return ModelHealth(endpoint=base, reachable=False, version=version, tags_count=tags_count, provider="ollama", error=str(exc))


def check_openai_compatible_endpoint(endpoint: str, api_key: str | None = None) -> ModelHealth:
    base = endpoint.rstrip("/")
    models_url = base + "/models"
    headers = {}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    request = Request(models_url, headers=headers)
    try:
        with urlopen(request, timeout=5) as response:
            payload = json.loads(response.read().decode("utf-8"))
        tags_count = len(payload.get("data", [])) if isinstance(payload, dict) else None
        return ModelHealth(endpoint=base, reachable=True, version=None, tags_count=tags_count, provider="openai-compatible", error=None)
    except (URLError, HTTPError, TimeoutError, json.JSONDecodeError) as exc:
        return ModelHealth(endpoint=base, reachable=False, version=None, tags_count=None, provider="openai-compatible", error=str(exc))
