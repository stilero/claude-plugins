---
name: github-issue-generator
description: >
  Evaluates findings, bugs, ideas, and improvement opportunities discovered during conversation and decides whether to create or update a GitHub issue. Triggers when the user says "create an issue", "log this", "track this", "open an issue for this", "file a ticket", "this should be a GitHub issue", or "add this to the backlog". Also triggers proactively when a finding in the conversation is clearly high-value (significant bug, missing feature, meaningful technical debt, or maintainability concern) and the user asks Claude to track it. Only creates issues that will genuinely add value — skips trivial, cosmetic, or low-impact items. When a similar issue already exists, updates it with the new finding instead of creating a duplicate.
---

# GitHub Issue Generator

Evaluate findings and ideas from the current conversation, then decide whether to create a new GitHub issue or update an existing one.

## Core Principle

**Only act on high-value findings.** Not every observation warrants an issue. Be a strict gatekeeper. The goal is a clean, actionable backlog — not a dumping ground.

## Step 1: Identify the Finding

Extract the finding, idea, or improvement opportunity from the conversation. Clarify:

- **What**: What is the problem, feature, or improvement?
- **Where**: Which area of the codebase or system is affected?
- **Why**: What is the impact or motivation?

If the finding is vague, ask the user for clarification before proceeding.

## Step 2: Value Assessment

Score the finding against these criteria. A high-value issue must satisfy **at least one** of the following and must NOT be trivially small:

### High-Value Criteria
- **Bug with real impact**: A defect that causes incorrect behavior, data loss, crashes, or security exposure. Minor cosmetic glitches do not qualify.
- **Feature with clear user benefit**: A capability that meaningfully improves the product experience or unlocks important workflows. "Nice to have" ideas that don't change core value don't qualify.
- **Technical debt with measurable cost**: Code that actively slows development, creates repeated bugs, or makes the system fragile. General "this could be cleaner" thoughts don't qualify.
- **Maintainability or reliability risk**: A structural issue that will cause problems at scale or make the system hard to operate. Speculative future concerns don't qualify.
- **Developer experience improvement with broad impact**: Something that significantly speeds up common workflows or reduces cognitive load for the whole team.

### Disqualifying Signals (skip these)
- The change is a one-liner with no architectural significance
- It's purely cosmetic (rename, formatting, style preference)
- It's already obvious and likely tracked elsewhere
- The impact is limited to a single rarely-used path
- It's speculative ("maybe someday we could...")
- The user is just thinking out loud, not requesting tracking

**If the finding does not clear the high-value bar, do NOT create or update an issue. Tell the user why it doesn't meet the threshold and stop.**

## Step 3: Determine the Issue Type

Classify the finding:

- `bug` — Defect in existing behavior
- `feature` — New capability or enhancement
- `technical-debt` — Code quality, architecture, or structural problem that incurs ongoing cost
- `maintainability` — Observability, reliability, testability, or operational concern
- `documentation` — Missing or incorrect docs that cause meaningful confusion

## Step 4: Search for Existing Issues

Before creating anything, search for similar or duplicate issues.

Use `mcp__github__search_issues` to search the repository. Run at least two searches:
1. Search using the core problem keywords
2. Search using the affected area or component name

Also fetch open issues with `mcp__github__list_issues` if the repo has few issues, and scan for relevant ones.

**Duplicate detection rules:**
- If an existing issue covers the same root cause or goal, treat it as a duplicate even if the title differs
- If an existing issue is partially related but the new finding adds meaningfully new information, update the existing issue
- Only create a new issue if no existing issue covers this problem or goal

## Step 5a: Update Existing Issue (if duplicate/related found)

If a related issue exists:

1. Read the existing issue body with `mcp__github__issue_read` (method: `get`)
2. Read its existing comments with `mcp__github__issue_read` (method: `get_comments`)
3. Determine what new information the current finding adds
4. Post a comment using `mcp__github__add_issue_comment` that includes:
   - A brief summary of the new finding
   - Any new context, reproduction steps, or impact data
   - Reference to where in the conversation this came up
5. Tell the user which issue was updated and why it was treated as related

## Step 5b: Create New Issue (if no duplicate found)

### Discover the Issue Template

Before composing the issue body, look for an existing issue template in the target repository. Check these locations in order using `mcp__github__get_file_contents`:

1. `.github/ISSUE_TEMPLATE.md` — single-file template
2. `.github/ISSUE_TEMPLATE/bug_report.md`, `.github/ISSUE_TEMPLATE/feature_request.md`, or any `.md` file inside `.github/ISSUE_TEMPLATE/` — pick the one that best matches the issue type
3. `.github/ISSUE_TEMPLATE/` — list the directory to discover available templates

**If a matching template is found in the repo:**
- Use that template's structure and sections as the body format
- Fill in all placeholder sections with real content from the conversation
- Preserve any YAML frontmatter checklist items or section headers from the repo's template

**If no template is found in the repo:**
- Fall back to the default template defined in this plugin's `references/default-issue-template.md`
- Use the structure below

### Default Issue Template (fallback)

**Title format:** `[Type] Short, actionable description (imperative, <70 chars)`

Examples:
- `[Bug] Skill trigger description ignored when name conflicts`
- `[Feature] Add per-plugin MCP server scoping`
- `[Technical Debt] Plugin loader does not validate plugin.json schema`
- `[Maintainability] No integration tests for skill activation triggers`

**Body:**

```markdown
## Summary

<!-- One or two sentences describing what this is and why it matters. -->

## Problem / Motivation

<!-- What is broken, missing, or costly? Be concrete. What happens today vs. what should happen? -->

## Proposed Solution

<!-- What would a good fix or implementation look like? Can be high-level. -->

## Value & Impact

<!-- Why is this worth doing? Who is affected? What gets better? -->

## Acceptance Criteria

- [ ] <!-- Specific, testable condition 1 -->
- [ ] <!-- Specific, testable condition 2 -->
- [ ] <!-- Add more as needed -->

## Context

<!-- Any relevant links, references, code snippets, or conversation context. -->

---
*Issue generated from conversation context.*
```

Fill every section with real content derived from the conversation. Do not leave template placeholders in the final issue.

**Labels:** Apply relevant labels if they exist in the repo. Use `mcp__github__get_label` to check. Common labels to try: `bug`, `enhancement`, `technical-debt`, `documentation`, `good first issue`.

## Step 6: Report to User

After creating or updating:

- State what action was taken (created issue #N or updated issue #N)
- Give the issue title and a one-sentence rationale for why it met the value bar
- If you skipped creating an issue, explain clearly why it didn't qualify

## Rules

- Never create an issue without completing Steps 1–4 first
- Never create a duplicate — always search first
- Never use placeholder text in the issue body
- Never create issues for findings that don't clear the high-value bar
- Always use the exact issue template structure from Step 5b
- Keep issue titles concise and in imperative form
- One issue per distinct problem — do not bundle unrelated findings
