# Obsidian Knowledge Bank

A persistent, indexed knowledge bank that lives inside your repo. Stores learnings,
Architecture Decision Records (ADRs), technical decisions, and context notes as
markdown files — surviving between Claude sessions and committed to git alongside your code.

Inspired by Obsidian's vault approach: everything is plain markdown, human-readable,
and git-diffable. The index system scales to thousands of files with millisecond grep lookups.

---

## Features

- **Persistent across sessions** — committed to git, never lost between Claude conversations
- **Scalable index** — a grep-optimised `INDEX.md` means fast lookups across thousands of files
- **Structured categories** — ADRs, learnings, decisions, context, session summaries
- **ADR support** — numbered Architecture Decision Records with full Michael Nygard format
- **Hook integration** — a Stop hook that prompts Claude to save session learnings automatically
- **Shell script** — `store-knowledge.sh` for writing entries from hooks, CI, or the terminal
- **CLAUDE.md integration** — init updates your CLAUDE.md so Claude always checks the bank first

---

## Installation

```bash
/plugin marketplace add stilero/claude-plugins
```

Then install the plugin:

```
/plugin add obsidian-knowledge-bank
```

---

## Quick Start

### 1. Initialize the knowledge bank

```
/kb-init
```

This creates `.knowledge-bank/` in your repo root and updates `CLAUDE.md` to reference it.
Commit the generated files to git.

### 2. Store a learning

```
/kb-store
```

Claude will extract key learnings from the current conversation, prompt for confirmation,
and write a dated markdown file with a searchable index entry.

```
/kb-store learnings "Always validate JWT expiry in long jobs"
```

### 3. Create an ADR

```
/kb-adr "Use PostgreSQL as primary database"
```

Generates `ADR-0001-use-postgresql-as-primary-database.md` with status, context, decision,
and consequences — auto-numbered and indexed.

### 4. Recall knowledge

```
/kb-recall jwt
/kb-recall category=adr
/kb-recall tags=auth,security
```

Searches `INDEX.md` with grep and presents matches. Claude reads the full content of
selected entries.

---

## Knowledge Bank Structure

After `/kb-init`, your repo contains:

```
.knowledge-bank/
├── INDEX.md                          ← Master index (grep this for fast lookup)
├── adr/
│   ├── INDEX.md                      ← ADR-only index
│   ├── ADR-0001-use-postgresql.md
│   └── ADR-0002-adopt-ssr.md
├── learnings/
│   ├── INDEX.md
│   └── 2026-03/
│       └── 2026-03-28-jwt-expiry-gotcha.md
├── decisions/
│   ├── INDEX.md
│   └── 2026-03/
│       └── 2026-03-28-use-zod-validation.md
├── context/
│   ├── INDEX.md
│   └── 2026-03/
│       └── 2026-03-01-payment-pipeline-overview.md
└── sessions/
    ├── INDEX.md
    └── 2026-03/
        └── 2026-03-28-session-refactor-auth.md
```

### Category Guide

| Category    | Use for                                                       |
|-------------|---------------------------------------------------------------|
| `adr`       | Formal Architecture Decision Records with options considered  |
| `learnings` | Gotchas, discoveries, "I wish I'd known this" moments         |
| `decisions` | Lighter-weight technical choices that don't need full ADR     |
| `context`   | Background info, domain knowledge, system explanations        |
| `sessions`  | End-of-session summaries capturing work done and next steps   |

---

## Index Format

Every entry is a single HTML comment line in `INDEX.md`:

```
<!-- KB: id=0042 date=2026-03-28 category=learnings tags=auth,jwt title=JWT Token Expiry Handling file=learnings/2026-03/2026-03-28-jwt-token-expiry.md -->
```

This format supports fast grep-based queries:

```bash
# All ADRs
grep 'category=adr' .knowledge-bank/INDEX.md

# Entries tagged with "auth"
grep 'tags=.*auth' .knowledge-bank/INDEX.md

# Case-insensitive title search
grep -i 'title=.*cache' .knowledge-bank/INDEX.md

# Entries from March 2026
grep 'date=2026-03' .knowledge-bank/INDEX.md

# Combined filter
grep 'category=learnings' .knowledge-bank/INDEX.md | grep 'tags=.*database'
```

With 10,000 entries, `INDEX.md` is ~1–2 MB. Grep runs in milliseconds.
Individual files are only read when displaying a specific result.

---

## CLAUDE.md Integration

After `/kb-init`, your `CLAUDE.md` will contain a knowledge bank section like:

```markdown
## Knowledge Bank

This repo has a persistent knowledge bank at `.knowledge-bank/`. Before starting work on
any non-trivial task, check for relevant context:

- **All entries index:** `.knowledge-bank/INDEX.md`
- **ADRs:** `.knowledge-bank/adr/INDEX.md`
- **Learnings:** `.knowledge-bank/learnings/INDEX.md`
- **Decisions:** `.knowledge-bank/decisions/INDEX.md`
- **Context:** `.knowledge-bank/context/INDEX.md`

Search the index first: `grep -i 'title=.*<keyword>' .knowledge-bank/INDEX.md`
Then read the specific file referenced in the `file=` field.
```

This ensures Claude checks the knowledge bank at the start of every session before
writing new code — so it doesn't repeat past mistakes or re-litigate settled decisions.

---

## Hook Integration (Auto Session Capture)

### Stop Hook — Automatic end-of-session save

Add to `.claude/settings.json` in your repo (or `~/.claude/settings.json` globally):

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash .knowledge-bank/../plugins/obsidian-knowledge-bank/hooks/session-end.sh"
          }
        ]
      }
    ]
  }
}
```

Or copy `hooks/session-end.sh` to `.claude/hooks/` in your repo and reference it there.

When a session ends, this hook fires and blocks exit until Claude has run the
`knowledge-bank:knowledge-bank` skill to store session learnings. It fires only once per
session and is a no-op if `.knowledge-bank/` doesn't exist.

### Shell Script — Direct writes from bash

Use `scripts/store-knowledge.sh` anywhere you need to write knowledge without Claude:

```bash
# Simple entry
bash scripts/store-knowledge.sh learnings \
  "Deploy requires DEPLOY_TOKEN in CI secrets" \
  "Without it the push step exits 0 but nothing is deployed." \
  "ci,deploy,secrets"

# Multi-line content
content=$(cat <<'EOF'
The payment webhook can deliver the same event multiple times.
Always check idempotency before updating state.
EOF
)
bash scripts/store-knowledge.sh learnings "Stripe webhooks are idempotent" "$content" "stripe,webhooks,payments"
```

This script is suitable for:
- PostToolUse hooks that capture tool outputs
- CI/CD pipelines storing build/deploy outcomes
- Shell aliases for quick capture from the terminal
- Other automation that produces knowledge worth saving

---

## Commands

| Command      | Description                                                   |
|--------------|---------------------------------------------------------------|
| `/kb-init`   | Initialize `.knowledge-bank/` and update `CLAUDE.md`         |
| `/kb-store`  | Store a learning, decision, or context note                   |
| `/kb-adr`    | Create a formal Architecture Decision Record                  |
| `/kb-recall` | Search and retrieve knowledge by keyword, tag, or category    |

---

## Skills

The plugin exposes one skill: `knowledge-bank:knowledge-bank`

It handles all operations: init, store, adr, recall, list, and session capture.
Commands are thin wrappers around this skill.

The skill can also be invoked directly when Claude needs to look up or store knowledge
as part of another task — for example, before writing a migration, Claude might recall
all ADRs tagged `database` to ensure the new migration is consistent with past decisions.

---

## Entry File Format

All entries use YAML frontmatter for metadata and markdown for content:

```markdown
---
id: "0042"
title: "JWT Tokens Silently Expire During Long Operations"
date: "2026-03-28T14:30:00"
category: learnings
tags: [auth, jwt, async, gotcha]
---

## Summary
...

## Details
...

## Related
...
```

ADRs follow the extended format with `adr`, `status`, `supersedes`, and `superseded_by` fields.
See `skills/knowledge-bank/references/adr-template.md` for the full ADR format.

---

## Tips

- **Commit the knowledge bank to git.** It's meant to be part of the repo history.
- **Review session summaries in PRs.** A session entry is a useful PR description source.
- **Tag consistently.** Consistent tags (e.g., `auth`, `database`, `performance`) make
  recall much more powerful than title search alone.
- **ADRs for architecture, decisions for everything else.** Not every choice needs a full ADR —
  use `decisions` for lighter-weight captures and `adr` for things that shape the system.
- **Link related entries.** Each entry has a `## Related` section — use it to cross-reference
  ADRs, learnings, and context entries. This creates an Obsidian-style knowledge graph in plain markdown.
