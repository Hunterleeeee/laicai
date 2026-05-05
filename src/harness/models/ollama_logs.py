from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import re


@dataclass
class OllamaRuntimeHints:
    gpu_name: str | None = None
    offloaded_layers: str | None = None
    total_memory: str | None = None
    model_weights_metal: str | None = None
    kv_cache_metal: str | None = None
    compute_graph_metal: str | None = None


def read_ollama_runtime_hints(log_path: Path | None = None) -> OllamaRuntimeHints:
    target = (log_path or Path.home() / ".ollama" / "logs" / "server.log").expanduser()
    if not target.exists():
        return OllamaRuntimeHints()

    try:
        text = target.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return OllamaRuntimeHints()

    gpu_name = _last_group(text, r'ggml_metal_device_init: GPU name:\s+(.+)')
    offloaded = _last_group(text, r'offloaded (\d+/\d+) layers to GPU')
    total_memory = _last_group(text, r'total memory" size="([^"]+)"')
    model_weights_metal = _last_group(text, r'model weights" device=Metal size="([^"]+)"')
    kv_cache_metal = _last_group(text, r'kv cache" device=Metal size="([^"]+)"')
    compute_graph_metal = _last_group(text, r'compute graph" device=Metal size="([^"]+)"')
    return OllamaRuntimeHints(
        gpu_name=gpu_name,
        offloaded_layers=offloaded,
        total_memory=total_memory,
        model_weights_metal=model_weights_metal,
        kv_cache_metal=kv_cache_metal,
        compute_graph_metal=compute_graph_metal,
    )


def _last_group(text: str, pattern: str) -> str | None:
    matches = re.findall(pattern, text)
    if not matches:
        return None
    return matches[-1].strip()
