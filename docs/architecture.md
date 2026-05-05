# Architecture

## Core idea

This repository is shaped around one simple idea:

`the vault is the durable memory, and 来财 is the runtime`

That gives us a system that stays useful even when no background agents are running.

## Main building blocks

### CLI

The CLI is the single entrypoint:

- inspect environment health
- run lightweight tasks
- call tools
- load skills
- write artifacts back into the vault

### Vault adapter

The Obsidian vault is the human-facing memory layer:

- imported source material lands there
- generated notes land there
- future skills and workflows can also live there
- users can edit notes by hand without breaking the system

### Skill loader

Skills are intentionally simple:

- one folder per skill
- `skill.json` for metadata
- `prompt.md` for the behavior template

This keeps authoring friction low and makes it easy to version skills in git.

### Storage

SQLite is enough for the first phase:

- run tracking
- note tracking
- future workflow checkpoints
- future memory summaries

### Ingest

The ingest pipeline is where MinerU belongs:

- copy or stage incoming source files
- extract or summarize into Markdown
- write stable source notes into the vault

The current implementation only scaffolds this path so the project can grow without changing shape later.

## Resource strategy

This scaffold is designed for a personal machine:

- few always-on components
- low idle footprint
- file-based integrations first
- heavy tasks run only when asked

That makes it a better fit for local models and quieter day-to-day use.
