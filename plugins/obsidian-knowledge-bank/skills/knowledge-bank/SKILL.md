---
name: knowledge-bank
description: >
  Use this skill to interact with the repo's persistent knowledge bank (.knowledge-bank/).
  Triggers when the user says: "store this", "remember this", "save a learning", "create an ADR",
  "what do we know about X", "recall X", "search the knowledge bank", "initialize the knowledge bank",
  "kb-init", "kb-store", "kb-recall", "kb-adr", or any request to persist knowledge between sessions.
  Also use this skill automatically at session end to store significant learnings.
---

# Knowledge Bank Skill

## Overview

The knowledge bank is a `.knowledge-bank/` directory inside the repo. It stores markdown files
organized by category, indexed for fast lookups. It survives between Claude sessions and is
committed to git alongside code.

**Categories:**
- `adr/` — Architecture Decision Records (ADR-NNNN-title format)
- `learnings/` — Lessons learned, discoveries, gotchas
- `decisions/` — Technical decisions (lighter-weight than ADRs)
- `context/` — Background info, domain knowledge, system explanations
- `sessions/` — Per-session summaries auto-captured at end of session

**Index system:** Every write updates `.knowledge-bank/INDEX.md` with a single-line comment
entry per record. This allows instant grep-based search across thousands of files without
reading them all.

---

## Step 1: Determine the Operation

Read `$ARGUMENTS` or the conversation context and classify the request as one of:
- **init** — User wants to set up the knowledge bank in this repo for the first time
- **store** — User wants to save a learning, decision, or context note
- **adr** — User wants to create a formal Architecture Decision Record
- **recall** — User wants to search or retrieve knowledge
- **list** — User wants to see recent or category-filtered entries
- **session** — End-of-session capture (store a summary of this session's key learnings)

Then jump to the matching step below.

---

## Step 2a: INIT — Initialize the Knowledge Bank

**When:** User runs `/kb-init` or says "set up the knowledge bank".

1. Check if `.knowledge-bank/` already exists with the Read or Glob tool.
   - If it exists, inform the user and skip to the CLAUDE.md update check (step 2a-4).

2. Create the directory structure using the Bash tool:
   ```bash
   mkdir -p .knowledge-bank/{adr,learnings,decisions,context,sessions}
   ```

3. Create `.knowledge-bank/INDEX.md` with this exact content:
   ```markdown
   # Knowledge Bank Index

   This file is the master index for `.knowledge-bank/`. Each entry is a single-line HTML
   comment in a grep-friendly format. Never edit entries manually — use the kb commands.

   Search examples:
   - All ADRs: `grep 'category=adr' .knowledge-bank/INDEX.md`
   - By tag: `grep 'tags=.*auth' .knowledge-bank/INDEX.md`
   - By keyword in title: `grep -i 'title=.*cache' .knowledge-bank/INDEX.md`
   - Recent entries: `tail -20 .knowledge-bank/INDEX.md`

   ## Entries

   ```

4. Create category-level INDEX.md files for each of: `adr/`, `learnings/`, `decisions/`, `context/`, `sessions/`.
   Each should contain:
   ```markdown
   # [Category Name] Index

   <!-- KB entries for this category are listed below. One line per entry. -->

   ```

5. Create `.knowledge-bank/.gitkeep` so empty directories commit cleanly.

6. Check if `CLAUDE.md` exists in the repo root using the Read tool.
   - If it exists, append the following block at the end (only if it doesn't already contain `knowledge-bank`):
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
   - If `CLAUDE.md` does not exist, tell the user to add this block to their CLAUDE.md manually,
     or offer to create a CLAUDE.md with the block.

7. Tell the user the knowledge bank is initialized and explain what was created. Show the
   CLAUDE.md snippet if applicable.

---

## Step 2b: STORE — Store a Knowledge Entry

**When:** User wants to save a learning, discovery, decision, or context note.

1. Gather the following information. If not provided in `$ARGUMENTS`, extract from conversation context.
   Ask the user only if genuinely ambiguous:
   - **title** — concise title (5–10 words)
   - **category** — one of: `learnings`, `decisions`, `context`, `sessions`
     (for formal ADRs use the ADR flow in Step 2c)
   - **tags** — comma-separated keywords (3–6 tags recommended)
   - **content** — the full content to store

2. Compute the next entry ID:
   ```bash
   grep -c '^<!-- KB:' .knowledge-bank/INDEX.md 2>/dev/null || echo 0
   ```
   Increment by 1 and zero-pad to 4 digits (e.g., `0042`).

3. Build the file path:
   - Date: `YYYY-MM-DD` (today)
   - Year-month: `YYYY-MM`
   - Slug: lowercase title, spaces → hyphens, strip non-alphanumeric
   - Path: `.knowledge-bank/<category>/YYYY-MM/YYYY-MM-DD-<slug>.md`
   - Create the year-month subdirectory if needed:
     ```bash
     mkdir -p .knowledge-bank/<category>/YYYY-MM
     ```

4. Write the file with this frontmatter format. Read `references/learning-template.md` for the full template:
   ```markdown
   ---
   id: "0042"
   title: "Your Title Here"
   date: "2026-03-28T14:30:00"
   category: learnings
   tags: [tag1, tag2, tag3]
   ---

   ## Summary

   One paragraph summary.

   ## Details

   Full content here.

   ## Related
   - Any related KB entries or external links
   ```

5. Append the index entry to **both** `.knowledge-bank/INDEX.md` and
   `.knowledge-bank/<category>/INDEX.md`:
   ```
   <!-- KB: id=0042 date=2026-03-28 category=learnings tags=tag1,tag2,tag3 title=Your Title Here file=learnings/2026-03/2026-03-28-your-title-here.md -->
   ```
   The entry **must** be a single line starting with `<!-- KB:` and ending with `-->`.

6. Confirm to the user: file path created, ID assigned, tags indexed.

---

## Step 2c: ADR — Architecture Decision Record

**When:** User says "create an ADR", "record an architecture decision", or runs `/kb-adr`.

1. Gather:
   - **title** — short decision title
   - **status** — one of: `Proposed`, `Accepted`, `Deprecated`, `Superseded`
   - **context** — the situation and forces at play
   - **decision** — what was decided
   - **consequences** — what changes as a result (positive and negative)
   - **tags** — comma-separated keywords

2. Compute the next ADR number by counting existing ADR files:
   ```bash
   ls .knowledge-bank/adr/ADR-*.md 2>/dev/null | wc -l
   ```
   Increment by 1, zero-pad to 4 digits: `ADR-0001`.

3. Build the file path: `.knowledge-bank/adr/ADR-<NNNN>-<slug>.md`

4. Write the ADR file. Read `references/adr-template.md` for the exact format.

5. Compute the next global ID and append to both index files (same as Step 2b-5 but `category=adr`).

6. Confirm to the user: ADR number, file path, status.

---

## Step 2d: RECALL — Search and Retrieve Knowledge

**When:** User asks "what do we know about X", "recall X", or runs `/kb-recall <query>`.

1. Parse the query from `$ARGUMENTS` or conversation context.

2. Search the master index using the Grep tool (do NOT read individual files yet):
   ```
   pattern: (case-insensitive) title=.*<query> OR tags=.*<query>
   file: .knowledge-bank/INDEX.md
   ```
   Also try category-specific indexes if the user specified a category.

3. If no results, try a broader search:
   ```bash
   grep -ri "<query>" .knowledge-bank/INDEX.md
   ```

4. If still no results, inform the user and suggest related terms.

5. Present the matching index entries as a numbered list: ID, date, category, title, tags.
   Ask the user which entries they want to read in full (or read all if ≤ 3 results).

6. For each requested entry, extract the `file=` field from the index line and read that file
   using the Read tool.

7. Present the content clearly. If there are multiple results, group by category.

---

## Step 2e: LIST — Browse Recent or Filtered Entries

**When:** User asks "list knowledge", "show recent learnings", "list ADRs", or runs `/kb-recall` with no query.

1. Determine the filter:
   - No filter: show last 20 entries from master INDEX.md (`tail -20` equivalent using Grep)
   - Category filter: read the category-specific INDEX.md
   - Date filter: grep for `date=YYYY-MM`

2. Parse the matching lines and present as a formatted table:
   ```
   ID     Date        Category   Title
   ──────────────────────────────────────────────────────────
   0042   2026-03-28  learning   JWT Token Expiry Handling
   0041   2026-03-27  adr        ADR-0003 Use PostgreSQL for...
   ```

3. Offer to read any entry in full.

---

## Step 2f: SESSION — End-of-Session Capture

**When:** Triggered by the session-end hook, or user says "save session notes", "store what we learned today".

1. Review the conversation history. Identify:
   - Key decisions made
   - Problems solved and how
   - Gotchas or surprises encountered
   - Patterns or approaches that worked well
   - Things to watch out for next time

2. If there are 3 or more significant insights, create a session summary entry:
   - category: `sessions`
   - title: `Session YYYY-MM-DD: <1-line summary of main theme>`
   - tags: derived from the topics covered
   - content: structured list of learnings from Step 2f-1

3. For any individual learning significant enough to stand alone, create separate `learnings` entries.

4. For any architectural decisions made during the session, prompt the user: "This session included
   an architectural decision about X. Should I create a formal ADR?"

5. Confirm what was stored.

---

## Rules

- Always check if `.knowledge-bank/` exists before storing. If it doesn't, prompt the user to run `/kb-init` first.
- Never truncate content to fit — store the full detail.
- Index entries must always be single-line HTML comments starting with `<!-- KB:` — this is what makes grep work.
- Tags must be lowercase, no spaces, comma-separated without spaces (e.g., `auth,jwt,security`).
- File slugs must be lowercase alphanumeric with hyphens only, max 60 chars.
- ADR files must follow the standard format from `references/adr-template.md`.
- When in doubt about category, prefer `learnings` for discoveries and `decisions` for choices made.
- Do not store trivial or obvious information. Ask yourself: "Would a new team member benefit from this in 6 months?"
