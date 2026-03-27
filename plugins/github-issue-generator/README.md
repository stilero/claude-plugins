# github-issue-generator

Evaluates findings and ideas discovered during a conversation and creates high-value GitHub issues — or updates existing ones with new findings instead of creating duplicates.

## What it does

- **Strict value gating** — only acts on findings that genuinely matter: bugs with real impact, features with clear user benefit, technical debt with measurable cost, or maintainability/reliability risks. Cosmetic, trivial, or speculative items are skipped.
- **Duplicate detection** — searches existing issues before creating. If a related issue already exists, posts a comment with the new findings instead of opening a duplicate.
- **Template-aware** — looks for your repo's `.github/ISSUE_TEMPLATE` first and uses it. Falls back to a sensible built-in template if none is found.

## Installation

```
/plugin marketplace add stilero/claude-plugins
```

## Usage

### Slash command

```
/github-issue-generator
```

Run at any point in a conversation to evaluate recent findings. Optionally pass a description:

```
/github-issue-generator The auth middleware silently swallows 401 errors
```

### Automatic trigger via Stop hook

To have Claude automatically evaluate findings at the end of every session, add the bundled stop hook to your project's `.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/absolute/path/to/plugin/hooks/stop-hook.sh"
          }
        ]
      }
    ]
  }
}
```

Replace the path with the actual location of `hooks/stop-hook.sh` from this plugin after installation.

**How the stop hook works:**

1. When Claude stops, the hook fires and checks a per-session flag file.
2. On first stop in a session, it outputs a block decision that causes Claude to run `/github-issue-generator`.
3. On the next stop (after the skill finishes), the flag file exists and the hook exits cleanly — no infinite loop.

> The hook triggers once per session. If there are no high-value findings, Claude will say so briefly and stop.

## Issue template

When no repo template is found, issues are created with this structure:

```
## Summary
## Problem / Motivation
## Proposed Solution
## Value & Impact
## Acceptance Criteria
## Context
```

All sections are filled from conversation context — no placeholder text is left in the final issue.
