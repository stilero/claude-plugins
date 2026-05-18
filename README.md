# Claude Code Plugins

A curated collection of high-leverage plugins for [Claude Code](https://code.claude.com) — add them to supercharge your workflow with autonomous code review, PR automation, knowledge management, and more.

> **Security note:** Only install plugins you trust. This repository does not audit the contents of plugins for malicious behavior. Review each plugin's source before installation.

## Quick Start

Add the full marketplace to Claude Code:
```
/plugin marketplace add stilero/claude-plugins
```

Install a specific plugin:
```
/plugin install <plugin-name>@stilero-tools
```

---

## Plugins

- [hardcore-code-reviewer](#hardcore-code-reviewer) — 12 parallel agents reviewing your code from every angle
- [fix-pr-comments-loop](#fix-pr-comments-loop) — Autonomous loop that fixes PR review comments until the PR is clean
- [pr-comment-fixer](#pr-comment-fixer) — Single-pass fixer for PR review comments
- [tech-debt-audit](#tech-debt-audit) — 11-agent full-codebase technical debt audit
- [github-issue-generator](#github-issue-generator) — Converts conversation findings into tracked GitHub issues
- [obsidian-knowledge-bank](#obsidian-knowledge-bank) — Persistent, searchable knowledge base that lives in your repo
- [shopify-apps](#shopify-apps) — Expert patterns and guidance for building Shopify apps

---

## hardcore-code-reviewer

**The most thorough automated code review you'll ever get.**

Most code reviews look at correctness and style. This plugin simultaneously deploys **12 specialized subagents** — each an expert in a different failure mode — and runs them all in parallel against your diff. Bug hunter, security reviewer, architecture reviewer, test coverage reviewer, silent failure hunter, performance reviewer, complexity reviewer, observability reviewer, API contract reviewer, data & migration reviewer, accessibility reviewer, and type safety reviewer. Each agent gets a structured inventory of exactly what changed (files by purpose, added/modified symbols, HTTP surface, trust boundaries) so nothing slips through due to scope creep.

Issues are ranked BLOCKING → IMPORTANT → MINOR. When multiple agents flag the same area independently, severity is bumped up — that cross-validation signal is high-confidence. The report closes with a **Fix Roadmap** that orders issues by dependency and severity so you know what to tackle first.

**Install:**
```
/plugin install hardcore-code-reviewer@stilero-tools
```

**Use:**
> "review this PR" / "find bugs in this diff" / `/hardcore-code-review`

---

## fix-pr-comments-loop

**Set it and forget it PR fixing.**

You get review comments. You fix them. You push. You get more review comments. You repeat this for hours. This plugin automates that entire cycle.

It runs an autonomous loop: fetch unresolved comments → fix them with `pr-comment-fixer` → harden the diff with `hardcore-code-reviewer` (up to 3 inner passes) → run your repo's test/lint/build suite → commit and push → resolve only the threads actually addressed by the new code (strict ±20-line window check, no false resolutions) → re-request Copilot review → wait for the new review → repeat. It continues until there are zero unresolved comments or hard caps trip (8 outer rounds, 60-minute Copilot poll timeout per round).

It automatically discovers your verification command from your `CLAUDE.md`, `package.json`, `pyproject.toml`, or `Makefile` — it will not push without passing tests first. It escalates to you when a fix would require touching more than 3 unrelated files, removing tests, or changing a public API.

**Install:**
```
/plugin install fix-pr-comments-loop@stilero-tools
```

**Use:**
> "fix PR comments loop" / "drive this PR to a clean review" / "address all comments and re-request review until clean"

*Requires `hardcore-code-reviewer` and `pr-comment-fixer` to also be installed.*

---

## pr-comment-fixer

**One-shot PR comment resolution.**

Takes a PR number, fetches all review comments, filters for the actionable ones (code changes, bugs, security, performance — not open-ended discussions or compliments), reads each affected file, applies the fixes, and creates a single clean commit with a summary. Handles ambiguous comments by asking for clarification rather than guessing.

Use this when you want a single focused pass rather than the full autonomous loop. It's also the engine that `fix-pr-comments-loop` calls internally.

**Install:**
```
/plugin install pr-comment-fixer@stilero-tools
```

**Use:**
> "fix PR comments on #42" / "address PR feedback for PR #42"

---

## tech-debt-audit

**A full-codebase health check in one command.**

Technical debt accumulates invisibly. This plugin deploys **11 parallel audit agents** against your entire codebase — not just recent diffs — each scanning for a different category of debt: outdated dependencies with CVEs, code smells and duplication, circular dependencies, untested modules, swallowed errors, N+1 queries, security gaps, missing API docs, unsafe type assertions, inconsistent endpoint design, and over-engineered abstractions.

Findings are deduplicated across agents (a security issue caught by both the security scanner and the error handling auditor is one finding, not two, with boosted severity). Related findings are grouped into single actionable issues ("15 files using `any` type" becomes one issue, not 15). The report ends with a severity-ordered fix roadmap, and you can choose to push selected findings directly to GitHub as tracked issues.

**Install:**
```
/plugin install tech-debt-audit@stilero-tools
```

**Use:**
> "audit the codebase" / "find tech debt" / "codebase health check" / `/tech-debt-audit`

---

## github-issue-generator

**Only the issues worth tracking, with no manual writing.**

Every conversation with Claude surfaces findings — bugs, improvement ideas, risks, tech debt. This plugin evaluates those findings against a strict quality bar (real bugs with measurable impact, features with clear user value, debt with a quantifiable cost) and turns the ones that pass into well-structured GitHub issues. It searches for duplicates first and updates existing issues with new context rather than creating clutter.

Issues are created from your repo's own issue templates if they exist, or from a built-in template that fills every section with real content — no placeholder text, no "TODO: fill this in."

**Install:**
```
/plugin install github-issue-generator@stilero-tools
```

**Use:**
> "create an issue for this" / "log this finding" / "this should be a GitHub issue" / "track this"

---

## obsidian-knowledge-bank

**The memory that survives between sessions.**

Claude Code is stateless between sessions. Every time you start a new session, context about your architecture decisions, discovered gotchas, and past choices is gone. This plugin creates a `.knowledge-bank/` directory in your repo — committed to git — that stores learnings, architecture decision records (ADRs), technical context, and session summaries in structured, grep-friendly markdown files.

The index system uses single-line HTML comments (`<!-- KB: id=0042 date=2026-03-28 category=learnings tags=auth,jwt title=... -->`) so lookups are fast even at thousands of entries — no vector database, no external service, just `grep`. Hook it into Claude's session-end event to automatically capture key decisions and discoveries from every session.

**Install:**
```
/plugin install obsidian-knowledge-bank@stilero-tools
```

**Use:**
> "store this learning" / "create an ADR for this decision" / "what do we know about the auth system" / "kb-init"

---

## shopify-apps

**Build Shopify apps without hunting through documentation.**

Expert guidance for every part of the Shopify app development stack: OAuth flow and session tokens, GraphQL Admin and Storefront API patterns (including query cost awareness to avoid rate limits), checkout UI extensions, theme extensions, POS UI extensions, App Bridge and Polaris for the embedded UI, webhook registration and HMAC validation, subscription and usage-based billing flows, GDPR compliance webhook handlers, metafields, bulk operations, and app proxy setup.

Rather than generic advice, this plugin knows the patterns that actually work — how to handle per-shop secure token storage, how to structure async webhook processing, how to test locally with `shopify app dev`, and which Remix patterns to use for modern app development.

**Install:**
```
/plugin install shopify-apps@stilero-tools
```

**Use:**
> "build a Shopify app" / "how do I implement webhooks" / "Shopify billing setup" / "create a checkout extension"

---

## Plugin Structure

Each plugin follows a standard layout:

```
plugin-name/
├── .claude-plugin/
│   └── plugin.json     # metadata (required)
├── skills/             # trigger-based skill definitions
├── commands/           # slash commands
├── agents/             # subagent definitions
├── .mcp.json           # MCP server config (optional)
└── README.md
```

For more on building your own plugins, see the [Claude Code plugin documentation](https://code.claude.com/docs/en/plugins).
