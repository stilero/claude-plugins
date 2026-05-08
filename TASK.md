---
task_id: PRODUKT-1384
source: linear
url: https://linear.app/weekly-revolt/issue/PRODUKT-1384/skill-autonomous-fix-pr-comments-loop-with-hardcore-review-copilot-re
title: "Skill: autonomous /fix-pr-comments loop with hardcore review + copilot re-request"
fetched: 2026-05-08T13:37:39Z
---

# Task: Skill: autonomous /fix-pr-comments loop with hardcore review + copilot re-request

## Description
## Goal

Build a Claude Code skill that turns the manual PR-review-fix loop (just executed against [PRODUKT-1344](<https://linear.app/weekly-revolt/issue/PRODUKT-1344>) over 7 rounds) into a single command. The skill runs autonomously until the PR is review-clean.

## Background

The <issue id="43221855-4602-4715-b8fa-07c9086bc6ac">PRODUKT-1344</issue> PR went through 7 review rounds with `copilot-pull-request-reviewer`. Each round was: fetch unresolved threads → fix → run hardcore review → fix more → push → request re-review → wait → repeat. Most of the steps were mechanical and would benefit from automation; the only real human input is approving fixes when they cross a complexity bar.

## Loop the skill should automate

```
1. Run existing /fix-pr-comments skill
   - fetch unresolved threads
   - read affected files
   - apply surgical fixes
2. Run /hardcore-code-reviewer (--uncommitted) iteratively
   - fix BLOCKING + IMPORTANT findings
   - re-run until report is clean (no BLOCKING/IMPORTANT)
   - cap iterations (e.g. 3) to avoid infinite loops
3. Run full verification: yarn build && yarn test:unit && yarn test:integration && yarn lint
4. Commit (auto-generated message summarising round) and push
5. Resolve all addressed GitHub threads (resolveReviewThread mutation)
6. Re-request copilot review: gh pr edit <PR> --add-reviewer @copilot
7. Poll PR for new copilot activity (review submitted after our push)
8. If new comments → goto step 1. If review submitted with zero new comments → exit clean.
9. Cap total rounds (e.g. 8) to avoid runaway loops on noisy reviewers.
```

## Implementation notes

* Use the `skill-creator` skill to scaffold.
* Wraps existing skills: `fix-pr-comments`, `hardcore-code-reviewer:hardcore-code-reviewer`.
* Uses GitHub CLI: `gh pr view`, `gh api graphql` (for `reviewThreads` + `resolveReviewThread`), `gh pr edit --add-reviewer @copilot` (requires gh ≥ 2.88).
* Polling: check PR every 60s for new copilot review (`reviews(last:5).submittedAt > pushTime`). 60-min cap per round; surface to user if reviewer is silent past cap.
* Confirmation prompts: for any fix that crosses a complexity threshold (e.g. multi-file refactor, test removal, public-API change) bail to user — don't apply autonomously.
* Hard exit: stop the loop and ping the user if hardcore review cannot reach 0 BLOCKING/IMPORTANT after N inner iterations (probably means the change is wrong, not that the reviewer is wrong).

## Acceptance criteria

- [ ] Skill created at `~/.claude/skills/fix-pr-comments-loop/` (or chosen name) with proper frontmatter description that triggers on phrases like "fix-pr-comments loop", "address all PR comments and re-request review until clean", etc.
- [ ] Skill body documents the full loop above with the exact `gh` and graphql commands.
- [ ] Skill respects the user's CLAUDE.md verification sequence (build + test:unit + test:integration + lint) on every push.
- [ ] Skill never pushes a commit that fails verification.
- [ ] Skill never resolves a thread that wasn't addressed by code changes.
- [ ] Manual smoke test: run on a fresh PR with a deliberately-buggy diff, confirm the skill drives it to a clean state and exits.
- [ ] README/usage example added (so it shows up cleanly in `Skill` tool picker).

## Out of scope

* Building a new code reviewer (we're wrapping the existing `hardcore-code-reviewer`).
* Triggering reviewers other than copilot (extension can add later).
* Handling PRs without an open PR for the current branch (fail fast with a message).

## Reference: round-by-round breakdown that motivated this

<issue id="43221855-4602-4715-b8fa-07c9086bc6ac">PRODUKT-1344</issue> PR #372 — 7 rounds, [final state mergeable](<https://github.com/weeklyrevolt/weekly-revolt-be/pull/372>).

| Round | Trigger | Findings | Fix scope |
| -- | -- | -- | -- |
| 1 | initial copilot review | 5 inline comments | log truncation, SSE closeStream-in-finally, NODE_ENV-guarded test seam, etc. |
| 2 | post-push auto | 5 new (scaffolding files + types + naming) | drop [PLAN.md/TASK.md](<http://PLAN.md/TASK.md>), type tightening, challengeId rename |
| 3 | post-merge auto | 5 (single-flight init + EventPayload type lies) | subjectInitPromise, snake_case row types |
| 4 | (internal hardcore-review pass A) | 2 IMPORTANT (purchases inconsistency, unverified id) | producer-level payload validation |
| 5 | (internal hardcore-review pass B–D) | 2 IMPORTANT (asymmetry + null-payload crash) | lift validation to producer; remove redundant consumer guards |
| 6 | post-push copilot | 1 (listener leak on pg.Pool reuse) | client.off() before release |
| 7 | post-push copilot | 1 (pool leak on getSubject() catch path) | hoist client + release in catch |

The mechanical bits (fetch, fix, push, request, wait, repeat) are exactly what this skill should automate.

## Comments
_No comments._
