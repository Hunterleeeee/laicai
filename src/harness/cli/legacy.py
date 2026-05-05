"""Legacy CLI commands — retained for backward compatibility.

These commands depend on the old Orchestrator/WebFetcher/SkillRunner pipeline.
New code should use `laicai chat` (the Agent-based REPL) instead.
"""

from __future__ import annotations

import json
import shutil
from dataclasses import asdict
from pathlib import Path

import typer

from harness.app_runtime import (
    bootstrap_orchestrator as runtime_bootstrap_orchestrator,
    bootstrap_services as runtime_bootstrap_services,
)
from harness.config import load_config, render_config_toml
from harness.ingest import DocumentPipeline, open_with_app
from harness.models import (
    LocalModelRuntime,
    check_ollama_endpoint,
    check_openai_compatible_endpoint,
    discover_ollama_models,
    read_ollama_runtime_hints,
)
from harness.rag import VaultIndex
from harness.skills import SkillAuthor, SkillRunRequest, SkillRunner
from harness.tools import WebFetcher, parse_browser_action


# ── Sub-apps ──────────────────────────────────────────────────

skill_app = typer.Typer(help="Legacy / advanced: inspect and run local skills.")
vault_app = typer.Typer(help="Legacy / advanced: write notes into the configured Obsidian vault.")
web_app = typer.Typer(help="Legacy / advanced: fetch web content.")
ingest_app = typer.Typer(help="Legacy / advanced: import files into the knowledge pipeline.")
task_app = typer.Typer(help="Legacy / advanced: task planning and future execution flows.")
model_app = typer.Typer(help="Legacy / advanced: talk to the configured local model runtime.")
mineru_app = typer.Typer(help="Legacy / advanced: MinerU helpers.")
mode_app = typer.Typer(help="Legacy / advanced: switch local runtime profiles.")
training_app = typer.Typer(help="Legacy / advanced: dataset prep and local LoRA/training workflows.")


# ── Bootstrap helpers ─────────────────────────────────────────

def _bootstrap_with_config():
    return runtime_bootstrap_services()


def _bootstrap():
    _, store, vault, skills, web, planner, model = _bootstrap_with_config()
    return store, vault, skills, web, planner, model


def _bootstrap_orchestrator():
    return runtime_bootstrap_orchestrator()


def _bootstrap_web(cdp_url=None):
    config, store, vault, skills, web, planner, model = _bootstrap_with_config()
    if cdp_url:
        web_config = config.web.model_copy(update={"browser_cdp_url": cdp_url})
        web = WebFetcher(web_config, workspace_root=config.runtime.workspace_root)
    return config, store, vault, skills, web, planner, model


def _browser_runtime_hint(web):
    report = web.doctor()
    hints = [
        f"Runtime root: {report.runtime_root}",
        f"Playwright browsers dir: {report.browsers_dir}",
        f"Install Chromium here: {report.install_command}",
    ]
    if report.browser_cache_issue:
        hints.append(f"Browser cache issue: {report.browser_cache_issue}")
    elif not report.bundled_browser_files:
        hints.append("Local Playwright Chromium cache is empty.")
    return hints


def _raise_browser_cli_error(web, exc):
    lines = [str(exc).strip()] + _browser_runtime_hint(web)
    raise typer.BadParameter("\n".join(lines)) from exc


# ── Legacy top-level commands ─────────────────────────────────

def register_legacy_commands(app: typer.Typer) -> None:
    """Register all legacy commands onto the main app."""

    @app.command("doctor")
    def doctor():
        config, store, vault, skills, _, _, model = _bootstrap_with_config()
        hints = read_ollama_runtime_hints()
        vault.ensure_layout()
        print(f"Vault: {vault.root}")
        print(f"Vault exists: {vault.root.exists()}")
        print(f"State DB: {store.db_path}")
        print(f"Skills discovered: {len(skills.list_skills())}")
        print(f"Model runtime: {model.status()}")
        print(f"Profile: {config.runtime.profile}")
        if hints.gpu_name:
            print(f"Ollama GPU: {hints.gpu_name}")

    @app.command("status")
    def status():
        doctor()

    @app.command("ask")
    def ask(
        goal: str = typer.Argument(...),
        save: bool = typer.Option(False, "--save"),
    ):
        config = load_config()
        store, vault, _, _, _, model = _bootstrap()
        index = VaultIndex(vault.root)
        matches = index.search(goal, limit=config.runtime.resolved_vault_context_limit())
        context = "\n\n".join(f"{item.path}:\n{item.preview}" for item in matches)
        context = context[:config.runtime.resolved_vault_context_chars()]
        prompt = (
            "You are answering with help from a local Obsidian vault.\n\n"
            f"User goal:\n{goal}\n\nRelevant vault context:\n{context or 'No relevant notes found.'}\n\n"
            "Write a practical answer."
        )
        run_id = store.record_run("ask", goal)
        response = model.complete(prompt, max_tokens=config.runtime.resolved_max_output_tokens())
        answer = response.content or "Local model returned an empty response."
        print(f"Run #{run_id}\n")
        print(answer)
        if save and response.ok and response.content.strip():
            note = vault.create_note(
                title=f"Answer - {goal[:60]}",
                body=answer,
                frontmatter={"tags": ["answer", "agent"], "goal": goal},
            )
            store.record_note(title=note.title, path=note.path, kind="answer")
            print(f"\nSaved to: {note.path}")

    @app.command("note")
    def note(
        title: str = typer.Option(..., "--title"),
        body: str = typer.Option(..., "--body"),
        folder: str | None = typer.Option(None, "--folder"),
    ):
        store, vault, _, _, _, _ = _bootstrap()
        n = vault.create_note(title=title, body=body, folder=folder)
        store.record_note(title=title, path=n.path, kind="note")
        print(n.path)

    @app.command("fetch")
    def fetch(
        url: str = typer.Argument(...),
        save: bool = typer.Option(False, "--save"),
    ):
        _, store, vault, _, web, _, _ = _bootstrap_with_config()
        page = web.fetch(url, use_browser=False)
        print(f"Title: {page.title}")
        print(page.text[:1200])
        if save:
            n = vault.create_note(
                title=page.title,
                body=page.text[:8000],
                folder="00 Inbox",
                frontmatter={"source_url": page.url, "tags": ["web", "inbox"]},
            )
            store.record_note(title=page.title, path=n.path, kind="web")
            print(f"\nSaved to: {n.path}")

    @app.command("start-here")
    def start_here():
        print("来财常用入口:")
        print("  laicai           → interactive chat (recommended)")
        print("  laicai chat      → interactive chat (explicit)")
        print("  laicai wiki ...  → preview/build trusted wiki pages")
        print("  laicai doctor    → health check")
        print('  laicai ask "..." → legacy single question with vault context')

    # register sub-apps
    app.add_typer(skill_app, name="skill")
    app.add_typer(vault_app, name="vault")
    app.add_typer(web_app, name="web")
    app.add_typer(ingest_app, name="ingest")
    app.add_typer(task_app, name="task")
    app.add_typer(model_app, name="model")
    app.add_typer(mineru_app, name="mineru")
    app.add_typer(mode_app, name="mode")
    app.add_typer(training_app, name="training")


# ── Skill commands ────────────────────────────────────────────

@skill_app.command("list")
def skill_list():
    _, _, skills, _, _, _ = _bootstrap()
    for skill in skills.list_skills():
        print(f"- {skill.name}: {skill.description}")


@skill_app.command("show")
def skill_show(name: str):
    _, _, skills, _, _, _ = _bootstrap()
    skill = skills.get(name)
    print(f"Name: {skill.name}\nDescription: {skill.description}\nPath: {skill.path}")


@skill_app.command("run")
@skill_app.command("exec")
def skill_exec(
    name: str = typer.Option(..., "--name"),
    goal: str = typer.Option(..., "--goal"),
    url: str | None = typer.Option(None, "--url"),
    vault_query: str | None = typer.Option(None, "--vault-query"),
    save: bool = typer.Option(False, "--save"),
):
    config = load_config()
    store, vault, skills, web, _, model = _bootstrap()
    skill = skills.get(name)
    runner = SkillRunner(vault=vault, web=web, model=model, runtime=config.runtime)
    request = SkillRunRequest(goal=goal, url=url, vault_query=vault_query, save=save)
    result = runner.run(skill, request)
    print(result.output)
    if result.saved_path:
        print(f"Saved to: {result.saved_path}")


@skill_app.command("create")
def skill_create(
    request: str = typer.Option(..., "--request"),
    name: str | None = typer.Option(None, "--name"),
):
    config = load_config()
    author = SkillAuthor()
    root_dir = config.skills.dirs[0]
    draft = author.create_draft(request=request, name=name, root_dir=root_dir)
    created_dir = author.write_skill(root_dir / draft.name, draft)
    print(f"Created skill: {draft.name}")
    print(created_dir)


# ── Vault commands ────────────────────────────────────────────

@vault_app.command("capture")
def vault_capture(
    title: str = typer.Option(..., "--title"),
    body: str = typer.Option(..., "--body"),
    folder: str | None = typer.Option(None, "--folder"),
):
    store, vault, _, _, _, _ = _bootstrap()
    note = vault.create_note(title=title, body=body, folder=folder)
    store.record_note(title=title, path=note.path, kind="note")
    print(note.path)


@vault_app.command("search")
def vault_search(
    query: str = typer.Option(..., "--query"),
    limit: int = typer.Option(5, "--limit"),
):
    _, vault, _, _, _, _ = _bootstrap()
    index = VaultIndex(vault.root)
    matches = index.search(query=query, limit=limit)
    if not matches:
        print("No matches found.")
        return
    for item in matches:
        print(f"{item.path}\n{item.preview}\n")


# ── Web commands ──────────────────────────────────────────────

@web_app.command("fetch")
def web_fetch(
    url: str,
    save: bool = typer.Option(False, "--save"),
    browser: bool = typer.Option(True, "--browser/--http"),
    cdp_url: str | None = typer.Option(None, "--cdp-url"),
):
    _, store, vault, _, web, _, _ = _bootstrap_web(cdp_url=cdp_url)
    page = web.fetch(url, use_browser=browser)
    print(f"Title: {page.title}\n{page.text[:1200]}")
    if save:
        note = vault.create_note(
            title=page.title, body=page.text[:8000], folder="00 Inbox",
            frontmatter={"source_url": page.url, "tags": ["web", "inbox"]},
        )
        store.record_note(title=page.title, path=note.path, kind="web")
        print(f"Saved to: {note.path}")


@web_app.command("doctor")
def web_doctor(cdp_url: str | None = typer.Option(None, "--cdp-url")):
    _, _, _, _, web, _, _ = _bootstrap_web(cdp_url=cdp_url)
    report = web.doctor()
    print(f"Browser enabled: {report.browser_enabled}")
    print(f"Playwright installed: {report.playwright_installed}")


# ── Ingest commands ───────────────────────────────────────────

@ingest_app.command("file")
def ingest_file(path: Path, title: str | None = typer.Option(None, "--title")):
    store, vault, _, _, _, _ = _bootstrap()
    config = load_config()
    pipeline = DocumentPipeline(config=config, store=store, vault=vault)
    result = pipeline.ingest_file(path, title=title)
    print(f"Document ID: {result.document_id}\nChunks: {result.chunks_count}")
    if result.note_path:
        store.record_note(title=(title or result.source_path.stem), path=result.note_path, kind="source")
        print(f"Note: {result.note_path}")


@ingest_app.command("markdown")
def ingest_markdown(path: Path, title: str | None = typer.Option(None, "--title")):
    ingest_file(path=path, title=title)


# ── Task commands ─────────────────────────────────────────────

@task_app.command("plan")
def task_plan(goal: str = typer.Option(..., "--goal")):
    store, _, _, _, planner, _ = _bootstrap()
    plan = planner.plan(goal)
    run_id = store.record_run("plan", goal)
    print(f"Run #{run_id}\nGoal: {plan.goal}")
    for i, step in enumerate(plan.steps, 1):
        print(f"{i}. {step}")


@task_app.command("ask")
def task_ask(
    goal: str = typer.Option(..., "--goal"),
    save: bool = typer.Option(False, "--save"),
):
    config = load_config()
    store, vault, _, _, _, model = _bootstrap()
    index = VaultIndex(vault.root)
    matches = index.search(goal, limit=config.runtime.resolved_vault_context_limit())
    context = "\n\n".join(f"{item.path}:\n{item.preview}" for item in matches)
    context = context[:config.runtime.resolved_vault_context_chars()]
    prompt = (
        "You are answering with help from a local Obsidian vault.\n\n"
        f"User goal:\n{goal}\n\nVault context:\n{context or 'None.'}\n\n"
        "Write a practical answer."
    )
    run_id = store.record_run("ask", goal)
    response = model.complete(prompt, max_tokens=config.runtime.resolved_max_output_tokens())
    print(f"Run #{run_id}\n{response.content or 'Empty response.'}")
    if save and response.ok and response.content.strip():
        note = vault.create_note(
            title=f"Answer - {goal[:60]}",
            body=response.content,
            frontmatter={"tags": ["answer"], "goal": goal},
        )
        store.record_note(title=note.title, path=note.path, kind="answer")
        print(f"Saved to: {note.path}")


# ── Model commands ────────────────────────────────────────────

@model_app.command("prompt")
def model_prompt(prompt: str = typer.Option(..., "--prompt")):
    _, _, _, _, _, model = _bootstrap()
    response = model.complete(prompt)
    print(response.content or "Empty response.")


@model_app.command("doctor")
def model_doctor():
    config = load_config()
    discovered = discover_ollama_models() if config.model.provider in {"local-openai-compatible", "ollama"} else []
    print(f"Provider: {config.model.provider}")
    print(f"Configured model: {config.model.model}")
    print(f"Discovered: {', '.join(discovered) if discovered else 'none'}")


@model_app.command("use-local")
def model_use_local(
    model: str = typer.Option("auto", "--model"),
    endpoint: str = typer.Option("http://127.0.0.1:11434/v1", "--endpoint"),
):
    config = load_config()
    config.model.provider = "local-openai-compatible"
    config.model.endpoint = endpoint
    config.model.model = model
    print(render_config_toml(config))


@model_app.command("use-api")
def model_use_api(
    endpoint: str = typer.Option(..., "--endpoint"),
    model: str = typer.Option(..., "--model"),
    api_key_env: str = typer.Option(..., "--api-key-env"),
):
    config = load_config()
    config.model.provider = "openai-compatible"
    config.model.endpoint = endpoint
    config.model.model = model
    config.model.api_key_env = api_key_env
    print(render_config_toml(config))


@model_app.command("start")
def model_start():
    if shutil.which("ollama"):
        print("Ollama CLI detected. Start the app manually if not running.")
    else:
        print("Ollama CLI not found. Install Ollama.app first.")


# ── MinerU commands ───────────────────────────────────────────

@mineru_app.command("open")
def mineru_open():
    config = load_config()
    open_with_app(config.mineru.app_path)


# ── Mode commands ─────────────────────────────────────────────

@mode_app.command("show")
def mode_show():
    config = load_config()
    print(config.runtime.profile)


@mode_app.command("set")
def mode_set(profile: str = typer.Argument(...)):
    normalized = profile.strip().lower()
    if normalized not in {"quiet", "balanced-lite", "maximal"}:
        raise typer.BadParameter("profile must be: quiet | balanced-lite | maximal")
    config = load_config()
    config.runtime.profile = normalized
    print(render_config_toml(config))


# ── Training commands ─────────────────────────────────────────

@training_app.command("dataset-prep")
def training_dataset_prep(
    source_dir: Path = typer.Argument(...),
    output: Path = typer.Option(Path("data/training/dataset.jsonl"), "--output"),
    system_prompt: str = typer.Option("You are a helpful assistant.", "--system-prompt"),
    min_length: int = typer.Option(50, "--min-length"),
    max_length: int = typer.Option(2048, "--max-length"),
):
    if not source_dir.exists():
        raise typer.BadParameter(f"Source directory does not exist: {source_dir}")
    output.parent.mkdir(parents=True, exist_ok=True)
    count = 0
    with output.open("w", encoding="utf-8") as f:
        for path in source_dir.rglob("*.md"):
            text = path.read_text(encoding="utf-8", errors="ignore").strip()
            if not text or len(text) < min_length or len(text) > max_length:
                continue
            record = {
                "messages": [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": f"Summarize:\n\n{text[:500]}"},
                    {"role": "assistant", "content": text},
                ],
            }
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
            count += 1
    print(f"Dataset: {output} ({count} examples)")


@training_app.command("lora-run")
def training_lora_run(
    dataset: Path = typer.Argument(...),
    base_model: str = typer.Option("llama3", "--base-model"),
    output_dir: Path = typer.Option(Path("data/training/lora-output"), "--output-dir"),
):
    if not dataset.exists():
        raise typer.BadParameter(f"Dataset not found: {dataset}")
    output_dir.mkdir(parents=True, exist_ok=True)
    config_path = output_dir / "lora_config.json"
    config_path.write_text(json.dumps({
        "base_model": base_model,
        "dataset": str(dataset),
        "output_dir": str(output_dir),
    }, indent=2) + "\n")
    print(f"LoRA config: {config_path}")
    print("Install unsloth/axolotl to run training.")
