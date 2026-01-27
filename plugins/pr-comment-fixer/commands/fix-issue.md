---
name: pr-comment-fixer
description: Fix issues mentioned in Pull Request
argument-hint: Optional specific Pull Request to Fix
allowed-tools: ["Read", "Write", "AskUserQuestion", "Task", "Grep", "TodoWrite", "Skill"]
---

# PR Comment Fixer

**FIRST: Load the pr-comment-fixer:fix-issues skill** using the Skill tool to understand what you are expected to do and follow the instructions.

**If $ARGUMENTS is provided:**
- User has given specific instructions: `$ARGUMENTS`
- Use this Pull Request number for further processing
