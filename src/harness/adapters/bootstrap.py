"""Bridge between .harness.toml config and the new Agent system.

Reads the existing HarnessConfig and creates Agent components
with the correct settings, so users don't have to pass CLI flags.
"""

from __future__ import annotations

import os
from pathlib import Path

from harness.adapters.llm.openai_compat import OpenAICompatLLM
from harness.adapters.llm.auto import create_llm


def create_llm_from_config(
    *,
    base_url: str | None = None,
    model: str | None = None,
    api_key: str | None = None,
) -> OpenAICompatLLM:
    """Create LLM from CLI overrides first, then .harness.toml, then auto-detect."""

    # CLI overrides take priority
    if base_url and model:
        return create_llm(base_url=base_url, model=model, api_key=api_key)

    # try reading .harness.toml
    try:
        from harness.config import load_config
        config = load_config()
        mc = config.model

        # resolve API key from env if configured
        resolved_key = api_key or mc.api_key or ""
        if not resolved_key and mc.api_key_env:
            resolved_key = os.environ.get(mc.api_key_env, "")

        cfg_base_url = base_url or mc.endpoint
        cfg_model = model or mc.model

        if cfg_base_url and cfg_model:
            return OpenAICompatLLM(
                base_url=cfg_base_url,
                model=cfg_model,
                api_key=resolved_key,
                timeout=float(config.runtime.resolved_request_timeout_seconds()),
            )
    except Exception:
        pass

    # fallback to auto-detection
    return create_llm(base_url=base_url, model=model, api_key=api_key)


def resolve_vault_root(vault_path: str | None = None) -> Path | None:
    """Resolve vault root from CLI arg, then .harness.toml, then common defaults."""

    if vault_path:
        return Path(vault_path).expanduser().resolve()

    # try .harness.toml
    try:
        from harness.config import load_config
        config = load_config()
        vp = config.vault.path
        if vp and vp.exists():
            return vp
    except Exception:
        pass

    # common defaults
    for candidate in [
        Path.home() / "vault",
        Path.home() / "obsidian",
        Path.home() / "Documents" / "vault",
        Path.home() / "Documents" / "Obsidian",
    ]:
        if candidate.is_dir():
            return candidate

    return None
