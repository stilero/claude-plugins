# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A Claude Code plugin marketplace repository (`stilero/claude-plugins`). Contains multiple independent plugins distributed via `/plugin marketplace add stilero/claude-plugins`. There is no build system, package manager, or test suite — plugins are pure markdown/JSON.

## Repository Structure

```
plugins/
  <plugin-name>/
    .claude-plugin/
      plugin.json        # Required manifest (name, description, version, author)
    commands/            # Slash commands (markdown files)
    agents/              # Subagent definitions (markdown files)
    skills/              # Skill definitions (SKILL.md with YAML frontmatter)
      <skill-name>/
        SKILL.md
        references/      # Optional supporting docs
    .mcp.json            # Optional MCP server config
    README.md
```

## Current Plugins

- **pr-comment-fixer** — Fetches and fixes unresolved GitHub PR review comments. Has a skill and a slash command.
- **hardcore-code-reviewer** — Strict code reviewer that spawns 12 parallel subagents (bug-hunter, security-reviewer, architecture-reviewer, test-reviewer, silent-failure-hunter, performance-reviewer, complexity-reviewer, observability-reviewer, api-contract-reviewer, data-migration-reviewer, accessibility-reviewer, type-safety-reviewer). Has a skill, a command, and 12 agent definitions.
- **shopify-apps** — Guidance for Shopify app development. Has a skill with reference docs.
- **github-issue-generator** — Evaluates conversation findings and creates/updates GitHub issues with duplicate checking.
- **obsidian-knowledge-bank** — Persistent indexed knowledge bank for learnings, ADRs, technical context, and session notes.
- **tech-debt-audit** — Spawns 11 parallel agents to audit a codebase for technical debt, groups findings into actionable issues, and offers GitHub issue creation.

## Plugin Conventions

- `plugin.json` is the only required file — it lives in `.claude-plugin/`.
- Skills use YAML frontmatter (`name`, `description`) in `SKILL.md`. The `description` field is critical for triggering — it must clearly describe when the skill should activate.
- Agent markdown files define subagent behavior with YAML frontmatter specifying tools, model, and description.
- Commands are markdown files with YAML frontmatter (`description`, optional `allowed-tools`).
- No code compilation or dependencies. All plugin logic is expressed as markdown prompts.

## Version Bumps

Always bump the version in `plugin.json` when modifying a plugin. Use semver: patch for fixes, minor for new features or expanded coverage, major for breaking changes.

## Adding a New Plugin

1. Create `plugins/<name>/.claude-plugin/plugin.json` with name, description, version, author.
2. Add components (commands/, agents/, skills/) as needed.
3. Each component is a standalone markdown file with YAML frontmatter.
4. **Add the plugin to `.claude-plugin/marketplace.json`** — this is required for the plugin to appear in the marketplace. Without an entry here, the plugin exists in the repo but is invisible to users.
