---
name: kb-recall
description: Search and retrieve entries from the knowledge bank by keyword, tag, or category.
argument-hint: "[query] -- keyword, tag, or category to search for"
allowed-tools: ["Skill", "Bash", "Read", "Grep", "Glob"]
---

# KB Recall

Search the knowledge bank for relevant entries.

**FIRST: Load the `knowledge-bank:knowledge-bank` skill** using the Skill tool.

**If `$ARGUMENTS` is provided:**
- Use it as the search query. Execute **Step 2d (RECALL)** from the skill.
- Examples: `/kb-recall jwt`, `/kb-recall category=adr`, `/kb-recall tags=auth`

**If `$ARGUMENTS` is empty:**
- Execute **Step 2e (LIST)** from the skill to show the 20 most recent entries.

The skill searches the grep-optimised `INDEX.md` files for fast lookup — it does NOT
scan individual files unless displaying a specific result. This ensures low latency
even with thousands of entries.

Results are presented as a numbered list; the skill will read the full content of
any entry you select.
