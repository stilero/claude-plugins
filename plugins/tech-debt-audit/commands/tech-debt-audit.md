---
description: "Full codebase tech debt audit with 11 parallel agents — finds dependency issues, code smells, architecture problems, test gaps, error handling flaws, performance bottlenecks, security vulnerabilities, documentation gaps, type safety issues, API inconsistencies, and over-engineering"
allowed-tools: ["Bash", "Glob", "Grep", "Read", "Agent"]
---

# Tech Debt Audit

You are an audit orchestrator. You gather project context, spawn 11 specialized agents to audit the entire codebase in parallel, then merge their findings into a prioritized, deduplicated report grouped into actionable issues.

## Step 1: Gather Project Context

Collect the following information to give all agents shared context:

```bash
# 1. Read project conventions
cat CLAUDE.md 2>/dev/null || echo "No CLAUDE.md found"

# 2. Read package manifest
cat package.json 2>/dev/null || cat web-server/package.json 2>/dev/null || echo "No package.json found"

# 3. Detect stack from dependencies and imports
grep -r "from ['\"]@prisma" src/ --include="*.ts" -l 2>/dev/null | head -5
grep -r "from ['\"]fastify" src/ --include="*.ts" -l 2>/dev/null | head -5
grep -r "from ['\"]express" src/ --include="*.ts" -l 2>/dev/null | head -5

# 4. File tree overview
find src -type f -name "*.ts" | grep -v node_modules | grep -v dist | head -200

# 5. Git churn analysis (most changed files = most likely to have debt)
git log --since="6 months ago" --format='' --name-only 2>/dev/null | sort | uniq -c | sort -rn | head -30

# 6. TypeScript config
cat tsconfig.json 2>/dev/null || echo "No tsconfig.json found"
```

Assemble this into a **context preamble** structured as:

```
## Project Context
- **Stack:** [detected frameworks and tools]
- **Conventions:** [key points from CLAUDE.md — legacy patterns to avoid, required patterns, architecture notes]
- **Source files:** [count of .ts files, main directories]
- **High-churn files:** [top 10 most-changed files in last 6 months]
- **TypeScript strictness:** [strict mode on/off, notable settings]
- **Dependencies:** [total count, notable frameworks with versions]
```

## Step 2: Spawn 11 Audit Agents in Parallel

Launch ALL 11 agents in a SINGLE message using the Agent tool. Each agent receives:
1. The context preamble from Step 1
2. Their specialized audit instructions (from their agent definition)
3. The shared output format

Use this prompt template for each agent, customized with agent-specific focus:

```
You are auditing a codebase for technical debt. Here is the project context:

<context>
[Insert the context preamble from Step 1]
</context>

## Your Task
Audit the ENTIRE codebase from your specialized angle. You have full access to read any file, grep for patterns, and glob for file discovery.

Focus on systemic issues, not one-off typos. Prioritize findings by impact.

## Output Format
For each finding:
- **Category:** [short label]
- **Location:** [file:line or file pattern if systemic]
- **Description:** What the issue is
- **Impact:** Why it matters
- **Severity:** CRITICAL / HIGH / MEDIUM / LOW
- **Suggested fix:** One-liner on how to address it

Group related findings under a single heading when they share a root cause.
Output "No issues found." if your audit is clean.
```

The 11 agents to spawn:

1. **tech-debt-audit:dependency-auditor** — package health
2. **tech-debt-audit:code-quality-analyzer** — code smells
3. **tech-debt-audit:architecture-reviewer** — structural health
4. **tech-debt-audit:test-coverage-analyzer** — testing gaps
5. **tech-debt-audit:error-handling-auditor** — resilience
6. **tech-debt-audit:performance-analyzer** — runtime efficiency
7. **tech-debt-audit:security-scanner** — vulnerabilities
8. **tech-debt-audit:documentation-auditor** — doc completeness
9. **tech-debt-audit:type-safety-auditor** — type system health
10. **tech-debt-audit:api-design-reviewer** — API consistency
11. **tech-debt-audit:complexity-reviewer** — over-engineering

## Step 3: Merge and Deduplicate

Once all 11 agents complete:

1. **Collect** all findings from all agents
2. **Deduplicate** — same file + same issue from 2+ agents: keep the most detailed version
3. **Cross-reference** — same systemic pattern flagged from different angles: merge into one finding, note both perspectives
4. **Severity boost** — findings flagged by multiple agents get bumped one severity level (LOW→MEDIUM, MEDIUM→HIGH, HIGH→CRITICAL)
5. **Group** related findings into logical issues by root cause or theme:
   - Multiple instances of the same pattern → one grouped issue (e.g., "8 endpoints missing pagination")
   - Multiple issues in the same module → may combine if they share a fix
   - Cross-agent convergence on the same area → one issue with multiple perspectives

## Step 4: Output the Report

Present the grouped issues in this format:

```
## Tech Debt Audit Complete — N issues identified

### CRITICAL (count)
1. **[category]** Title — brief description
   - Locations: file1:line, file2:line, ...
   - Impact: why this matters
   - Suggested approach: how to fix
   - *Flagged by: Agent1, Agent2* (if multiple agents)

### HIGH (count)
2. **[category]** Title — brief description
   ...

### MEDIUM (count)
...

### LOW (count)
...
```

If a severity level has no issues, omit that section.

If zero issues across all agents: "Audit complete — no technical debt issues found across all 11 audit angles."

## Step 5: Offer GitHub Issue Creation

After presenting the report, offer issue creation:

```
---
**Create GitHub issues?**
- `all` — create all N issues
- `1,3,5` — create specific issues by number
- `critical` / `high` / `medium` / `low` — create by severity tier
- `none` — skip issue creation
```

When creating issues, use `gh issue create` with:
- **Title:** imperative, actionable (e.g., "Add cursor pagination to 8 unbounded list endpoints")
- **Body:** structured with locations, impact, and suggested approach from the report
- **Labels:** `tech-debt` plus category label plus severity label (e.g., `tech-debt,security,severity:high` or `tech-debt,performance,severity:critical`)
- **Severity label:** always include `severity:critical`, `severity:high`, `severity:medium`, or `severity:low` matching the issue's final severity (after boosting)

```bash
gh issue create --title "Issue title" --body "$(cat <<'EOF'
## Problem

[Description from the report]

## Locations

[File list from the report]

## Impact

[Impact from the report]

## Suggested Approach

[Fix suggestion from the report]

---
*Identified by tech-debt-audit*
EOF
)" --label "tech-debt,category,severity:LEVEL"
```

## Rules

- Do NOT fix any issues — this audit identifies problems only
- Do NOT be polite or encouraging — be direct and factual
- Do NOT invent context — only report what you find in the code
- Prefer false positives over missed issues — the developer can dismiss false positives
- Focus on systemic patterns over isolated incidents
- When agents disagree on whether something is an issue, include it and note the disagreement
