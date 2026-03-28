---
name: kb-store
description: Store a learning, decision, or context note in the knowledge bank.
argument-hint: "[category] [title] -- optional: pre-fill category and title"
allowed-tools: ["Skill", "Bash", "Read", "Write", "Glob", "Grep"]
---

# KB Store

Store a new knowledge entry in the knowledge bank.

**FIRST: Load the `knowledge-bank:knowledge-bank` skill** using the Skill tool, then execute **Step 2b (STORE)** from the skill.

**If `$ARGUMENTS` is provided:**
- Parse it as `[category] [title]` — use these to pre-fill the entry.
- Valid categories: `learnings`, `decisions`, `context`, `sessions`

**If `$ARGUMENTS` is empty:**
- Infer what to store from the recent conversation context.
- Ask the user to confirm the title, category, and tags before writing.

The skill will:
1. Gather title, category, tags, and content
2. Create a dated markdown file under `.knowledge-bank/<category>/YYYY-MM/`
3. Append an index entry to the master and category `INDEX.md` files
4. Confirm the file path and assigned ID

For formal Architecture Decision Records, use `/kb-adr` instead.
