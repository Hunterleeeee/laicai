# Architecture

## Core idea

This repository is shaped around one simple idea:

`the vault is the durable memory, and 来财 is the runtime`

That gives us a system that stays useful even when no background agents are running.

## Main building blocks

### App and CLI

The macOS app is the primary daily interface. The CLI is the scriptable entrypoint:

- inspect environment health
- run lightweight tasks
- call tools
- load skills
- write artifacts back into the vault

Both entrypoints share the Swift domain and foundation layers.

### Vault adapter

The Obsidian vault is the human-facing memory layer:

- imported source material lands there
- generated notes land there
- wiki notes use `02 Atomic/` for one-concept pages and `03 MOC/` for index pages
- skills and workflows can also live there when the user wants local, versioned automation
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
- workflow checkpoints
- memory summaries

### Wiki and ingest

Wiki generation is source-first:

- search existing Vault notes before writing new pages
- create atomic notes for individual concepts
- create MOC pages for navigation across related concepts
- keep web sources visible in generated Markdown
- sanitize topic names before using them as file paths

Document ingest should follow the same rule: extract stable source notes first, then synthesize wiki pages from those notes.

## Resource strategy

This application is designed for a personal machine:

- few always-on components
- low idle footprint
- file-based integrations first
- heavy tasks run only when asked

That makes it a better fit for local models and quieter day-to-day use.
