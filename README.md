# 来财 (Laicai)

A local-first AI agent workspace for a single machine.

- Local model routing (Ollama)
- Obsidian-backed knowledge storage
- Web access and custom skills
- CLI entrypoint (`laicai`)
- SQLite state store
- Tools, workflows, and future RAG

## Quick start

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
cp examples/config.example.toml .harness.toml
laicai doctor
laicai skill list
```
