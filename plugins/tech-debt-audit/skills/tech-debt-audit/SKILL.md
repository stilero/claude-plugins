---
name: tech-debt-audit
description: "Full codebase technical debt audit using 11 parallel specialized agents. Identifies dependency issues, code smells, architecture problems, test gaps, error handling flaws, performance bottlenecks, security vulnerabilities, documentation gaps, type safety issues, API inconsistencies, and over-engineering. Groups findings into actionable GitHub issues. Use when the user asks to audit the codebase, find tech debt, assess code quality, check for technical debt, or run a codebase health check."
---

# Tech Debt Audit

This skill runs a comprehensive technical debt audit by spawning 11 specialized agents in parallel, each examining the codebase from a different angle.

## How It Works

1. **Context gathering** — reads CLAUDE.md, package.json, tsconfig.json, file tree, and git churn to understand the project
2. **Parallel audit** — launches 11 agents simultaneously, each focused on one category of technical debt
3. **Aggregation** — merges findings, deduplicates overlapping issues, boosts severity when multiple agents converge
4. **Report** — presents grouped issues ranked by severity
5. **Issue creation** — offers to create GitHub issues for selected findings

## The 11 Audit Agents

| Agent | Focus | Model |
| --- | --- | --- |
| dependency-auditor | Outdated deps, CVEs, unused packages | haiku |
| code-quality-analyzer | Code smells, complexity, duplication, dead code | sonnet |
| architecture-reviewer | Circular deps, layer violations, pattern inconsistencies | sonnet |
| test-coverage-analyzer | Untested modules, test quality, integration gaps | sonnet |
| error-handling-auditor | Swallowed errors, missing error handling, resilience | sonnet |
| performance-analyzer | N+1 queries, missing indexes, unbounded queries | sonnet |
| security-scanner | Secrets, injection, validation, auth gaps | sonnet |
| documentation-auditor | Missing API docs, stale docs, missing ADRs | haiku |
| type-safety-auditor | any usage, unsafe assertions, strict mode gaps | sonnet |
| api-design-reviewer | Endpoint naming, pagination, error consistency | sonnet |
| complexity-reviewer | Over-engineering, unnecessary abstractions, YAGNI | sonnet |

## Severity Boosting

When multiple agents flag the same area or pattern, severity is bumped one level:
- An issue found by 1 agent keeps its original severity
- An issue found by 2+ agents gets bumped (LOW→MEDIUM, MEDIUM→HIGH, HIGH→CRITICAL)

## Issue Grouping

Related findings are merged into single actionable issues:
- 8 endpoints missing pagination → one issue
- 15 files using `any` type → one issue
- 3 circular dependency chains → one issue

## Usage

Run `/tech-debt-audit` to start a full codebase audit. The command handles everything automatically — context gathering, agent spawning, aggregation, and reporting.
