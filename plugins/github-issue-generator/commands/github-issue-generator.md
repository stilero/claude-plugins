---
name: github-issue-generator
description: Evaluate a finding or idea and create or update a GitHub issue if it's high value. Checks for duplicates first.
argument-hint: "Optional: describe the finding or idea to evaluate"
allowed-tools: ["Skill", "AskUserQuestion", "TodoWrite"]
---

# GitHub Issue Generator

**FIRST: Load the `github-issue-generator:github-issue-generator` skill** using the Skill tool and follow its instructions exactly.

**If $ARGUMENTS is provided:**
- The user has described the finding or idea: `$ARGUMENTS`
- Use this as the input for the value assessment in Step 2 of the skill
- Do not ask the user to re-describe it

**If $ARGUMENTS is empty:**
- Review the recent conversation to identify any finding, bug, idea, or improvement that has come up
- If nothing stands out as potentially valuable, ask the user what they'd like to track
