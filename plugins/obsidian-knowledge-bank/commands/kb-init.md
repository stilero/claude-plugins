---
name: kb-init
description: Initialize the knowledge bank in this repo. Creates .knowledge-bank/ structure and updates CLAUDE.md.
allowed-tools: ["Skill", "Bash", "Read", "Write", "Edit", "Glob"]
---

# KB Init

Initialize the knowledge bank for this repository.

**FIRST: Load the `knowledge-bank:knowledge-bank` skill** using the Skill tool, then execute **Step 2a (INIT)** from the skill.

This command:
- Creates `.knowledge-bank/` with category subdirectories (`adr/`, `learnings/`, `decisions/`, `context/`, `sessions/`)
- Creates master `INDEX.md` and per-category `INDEX.md` files
- Updates `CLAUDE.md` to reference the knowledge bank (or shows the snippet to add manually)

Run this once per repo before using any other `kb-*` commands.
