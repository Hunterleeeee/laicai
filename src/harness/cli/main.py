"""来财 CLI entry point.

Primary command: `laicai` or `laicai chat` → interactive agent REPL.
Legacy sub-commands (skill, vault, web, ingest, model, etc.) are in legacy.py.
"""

from __future__ import annotations

import asyncio
import typer


app = typer.Typer(
    help="来财: local-first AI assistant. Run `laicai` to start chatting.",
    invoke_without_command=True,
    no_args_is_help=False,
)


@app.callback()
def _default(ctx: typer.Context) -> None:
    """Enter chat when no subcommand is given."""
    if ctx.invoked_subcommand is None:
        chat()


@app.command()
def chat(
    base_url: str = typer.Option(None, "--base-url", help="LLM API base URL"),
    model: str = typer.Option(None, "--model", "-m", help="Model name"),
    api_key: str = typer.Option(None, "--api-key", "-k", help="API key"),
    vault: str = typer.Option(None, "--vault", "-v", help="Vault root path"),
) -> None:
    """Start interactive chat with 来财 agent."""
    from harness.cli.chat import run_chat
    run_chat(base_url=base_url, model=model, api_key=api_key, vault_path=vault)


@app.command()
def wiki(
    topic: str = typer.Argument(..., help="Topic to build into an Obsidian wiki page."),
    base_url: str = typer.Option(None, "--base-url", help="LLM API base URL"),
    model: str = typer.Option(None, "--model", "-m", help="Model name"),
    api_key: str = typer.Option(None, "--api-key", "-k", help="API key"),
    vault: str = typer.Option(None, "--vault", "-v", help="Vault root path"),
    use_web: bool = typer.Option(True, "--web/--no-web", help="Automatically search the web to enrich the wiki page."),
    web_results: int = typer.Option(3, "--web-results", help="How many web pages to fetch for enrichment."),
    save: bool = typer.Option(False, "--save/--preview", help="Write the generated wiki page instead of previewing it."),
) -> None:
    """Build or update a canonical Obsidian wiki page for a topic."""
    from harness.adapters.bootstrap import create_llm_from_config, resolve_vault_root
    from harness.adapters.embedding import create_embedding_adapter
    from harness.wiki import build_wiki_topic, wiki_diff

    vault_root = resolve_vault_root(vault)
    if not vault_root:
        raise typer.BadParameter("No vault configured. Pass --vault or configure vault.path.")

    async def _run() -> None:
        llm = create_llm_from_config(base_url=base_url, model=model, api_key=api_key)
        embedding = None
        try:
            embedding = create_embedding_adapter()
        except Exception:
            embedding = None
        result = await build_wiki_topic(
            llm=llm,
            vault_root=vault_root,
            topic=topic,
            embedding_adapter=embedding,
            use_web=use_web,
            web_max_results=web_results,
            save=save,
        )
        print(f"{'Built' if result.saved else 'Prepared'} wiki page: {result.note_path}")
        print(f"Search mode: {result.search_mode}")
        print(f"Change type: {'new page' if result.previous_markdown is None else 'update'}")
        if result.source_notes:
            print("Source notes:")
            for note in result.source_notes:
                print(f"- {note}")
        if result.web_sources:
            print("Web sources:")
            for source in result.web_sources:
                print(f"- {source}")
        diff = wiki_diff(result)
        if diff:
            print("Diff:")
            print(diff)
        elif result.previous_markdown is not None:
            print("Diff: no content changes")
        if not result.saved:
            print("Preview:")
            print(result.rendered_markdown)
            print("Preview only. Re-run with --save to write it.")
        await llm.close()

    asyncio.run(_run())


# ── Register legacy commands (lazy import avoids loading old deps at startup) ──

try:
    from harness.cli.legacy import register_legacy_commands
    register_legacy_commands(app)
except ImportError:
    pass  # legacy deps not installed — only chat is available


def main() -> None:
    app()


if __name__ == "__main__":
    main()
