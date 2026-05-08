---
name: fix-pr-comments-loop
description: Run the autonomous fix-pr-comments-loop on the current branch's PR (or a specified PR) until the reviewer signs off or hard caps trip
argument-hint: Optional Pull Request number to drive to a clean review
allowed-tools: ["Read", "Write", "Edit", "Glob", "AskUserQuestion", "Grep", "TodoWrite", "Skill", "Bash"]
---

# Fix PR Comments Loop

**FIRST: Load the `fix-pr-comments-loop` skill** using the Skill tool to understand what you are expected to do and follow the instructions exactly.

This command is a thin wrapper around the `fix-pr-comments-loop` skill. The skill orchestrates `pr-comment-fixer:fix-issues` and `hardcore-code-reviewer:hardcore-code-reviewer` into a single autonomous outer loop that drives a PR to a clean review state.

**If $ARGUMENTS is provided:**
- User has given a specific Pull Request number: `$ARGUMENTS`
- Use this Pull Request number when running the `fix-pr-comments-loop` skill instead of inferring it from the current branch.

**If $ARGUMENTS is empty:**
- Infer the PR from the current branch as documented in the `fix-pr-comments-loop` skill.
- If no open PR exists for the current branch, fail fast with a clear message (per the skill's no-open-PR contract).
