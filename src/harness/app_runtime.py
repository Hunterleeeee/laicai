from __future__ import annotations

from harness.agent import Planner
from harness.config import HarnessConfig, load_config
from harness.logging_config import setup_logging
from harness.memory import MemoryManager
from harness.models import LocalModelRuntime
from harness.orchestrator import ArtifactManager, Orchestrator, OrchestratorContext
from harness.retrieval import RetrievalService
from harness.skills import SkillLoader
from harness.storage import StateStore
from harness.tools import WebFetcher
from harness.vault import VaultAdapter


def bootstrap_services(config: HarnessConfig | None = None) -> tuple[HarnessConfig, StateStore, VaultAdapter, SkillLoader, WebFetcher, Planner, LocalModelRuntime]:
    config = config or load_config()
    setup_logging()
    store = StateStore(config.storage.sqlite_path)
    vault = VaultAdapter(config.vault)
    skills = SkillLoader(config.skills.dirs)
    web = WebFetcher(config.web, workspace_root=config.runtime.workspace_root)
    planner = Planner()
    model = LocalModelRuntime(config.model, config.runtime)
    return config, store, vault, skills, web, planner, model


def bootstrap_orchestrator(config: HarnessConfig | None = None) -> Orchestrator:
    config, store, vault, skills, web, planner, model = bootstrap_services(config)
    artifacts = ArtifactManager(store)
    memory = MemoryManager(store, vault)
    retrieval = RetrievalService(vault.root, store)
    return Orchestrator(
        OrchestratorContext(
            config=config,
            store=store,
            vault=vault,
            skills=skills,
            web=web,
            planner=planner,
            model=model,
            artifacts=artifacts,
            memory=memory,
            retrieval=retrieval,
        )
    )
