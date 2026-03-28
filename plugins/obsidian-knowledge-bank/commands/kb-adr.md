---
name: kb-adr
description: Create a formal Architecture Decision Record (ADR) in the knowledge bank.
argument-hint: "[title] -- optional: pre-fill the ADR title"
allowed-tools: ["Skill", "Bash", "Read", "Write", "Glob", "Grep"]
---

# KB ADR

Create a formal Architecture Decision Record.

**FIRST: Load the `knowledge-bank:knowledge-bank` skill** using the Skill tool, then execute **Step 2c (ADR)** from the skill.

**If `$ARGUMENTS` is provided:**
- Use as the ADR title. The skill will gather the remaining fields.

**If `$ARGUMENTS` is empty:**
- The skill will ask for the decision title and walk through the ADR fields.

The skill will:
1. Auto-number the ADR (ADR-0001, ADR-0002, …)
2. Gather: status, context, decision, consequences, options considered, tags
3. Write to `.knowledge-bank/adr/ADR-<NNNN>-<slug>.md`
4. Update the master index and ADR category index

ADR statuses: `Proposed` | `Accepted` | `Deprecated` | `Superseded by ADR-NNNN`

For lighter-weight technical decisions that don't need the full ADR format, use `/kb-store decisions` instead.
