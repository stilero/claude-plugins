---
name: fix-pr-comments-loop
description: Autonomous loop that drives a pull request to a clean review state by repeatedly fetching unresolved copilot review threads, fixing them via the pr-comment-fixer skill, hardening the diff via the hardcore-code-reviewer skill, running the project verification sequence, pushing, resolving the addressed GitHub review threads, re-requesting copilot review, and polling until the reviewer signs off (zero new comments) or hard caps trip. Use this skill when the user wants to run a "fix-pr-comments loop", "address all PR comments and re-request review until clean", run an "autonomous PR fix loop", "drive PR to clean review", "auto-iterate PR comment fixes with hardcore review", or "loop fix-pr-comments until copilot is happy". Trigger proactively whenever the user asks to grind through copilot PR feedback rounds end-to-end, not just one round.
---

# fix-pr-comments-loop

Wraps two existing skills — `pr-comment-fixer:fix-issues` (the per-round fixer) and `hardcore-code-reviewer:hardcore-code-reviewer` (the inner hardening loop) — into one autonomous outer loop that keeps grinding until the PR is review-clean or a hard cap trips.

This skill **does not re-implement** the fix logic or the hardcore review logic. It orchestrates them. If the per-comment fix behavior changes, edit `pr-comment-fixer:fix-issues`. If the hardcore review heuristics change, edit `hardcore-code-reviewer:hardcore-code-reviewer`. This file only encodes the orchestration contract.

## When to use

Trigger phrases the user might say:

- "fix-pr-comments loop"
- "address all PR comments and re-request review until clean"
- "autonomous PR fix loop"
- "drive PR to clean review"
- "keep fixing the PR until copilot is happy"

If the user just wants a single round of fixes (no loop, no re-request), use `pr-comment-fixer:fix-issues` directly instead — this skill is the bigger hammer.

## Prerequisites

- `gh` CLI version `>= 2.88` (needed for `gh pr edit --add-reviewer @copilot`).
- An open PR for the current branch on GitHub.
- The two child skills installed and triggerable: `pr-comment-fixer:fix-issues` and `hardcore-code-reviewer:hardcore-code-reviewer`.
- A clean working tree at the start of every round (the loop will refuse to run with uncommitted changes outside of what it just produced).

## Fail-fast: no open PR

Before doing anything else, confirm there is an open PR for the current branch:

```bash
gh pr view --json number,state,headRefName,url --jq '.'
```

If the command fails or returns `state != "OPEN"`, **abort immediately** with a message like:

> No open PR found for the current branch (`<branch>`). This skill only operates on open PRs — push the branch and open a PR first, then re-run.

Do not attempt any of the rest of the loop. This is a hard precondition.

## Caps and bail-outs (load-bearing safety rails)

These caps are NOT decorative — they exist to stop runaway loops on noisy reviewers and on diffs that the hardcore reviewer cannot wrangle to clean.

| Cap | Default | Meaning | What happens at cap |
|---|---|---|---|
| Inner hardcore-review iterations per round | `3` | How many times the hardcore reviewer can re-run within a single round before giving up | Bail to user with the latest hardcore report and the message "hardcore-reviewer could not reach 0 BLOCKING/IMPORTANT after N inner iterations — likely the change is wrong, not the reviewer" |
| Outer loop rounds | `8` | How many full fetch→fix→review→push→re-request cycles to run before giving up | Bail to user with a status summary listing per-round counts of comments addressed, hardcore findings, and copilot re-review responses |
| Copilot poll cap (per round) | `60 minutes`, polling every `60s` | How long to wait for copilot to submit a fresh review after `--add-reviewer @copilot` | Bail to user with "copilot reviewer was silent past the 60-min cap; not pushing further". Do not push anything after the cap trips. |

Caps must be **enforced**, not just documented. If you find yourself entering iteration 4 of the inner review or round 9 of the outer loop, stop.

### Complexity threshold bail-outs

Some fixes cross a complexity threshold where the user MUST be in the loop. When the next step would require any of the following, **stop and ask the user** instead of applying autonomously:

- Multi-file refactor (the fix touches more than ~3 files unrelated to the original comment's file).
- Test removal or test-skip additions (`it.skip`, `xit`, `describe.skip`, deleting test cases, deleting whole test files).
- Public-API change (changing exported function signatures, package exports, REST/GraphQL schema, DB schema, or environment variables).
- Anything that would change behavior of a sibling endpoint/feature not mentioned in the original review thread.

These are the places where "address the comment" usually means a design discussion, not a mechanical fix. Hand control back to the user with a one-paragraph summary of what the fix would entail and why it crossed the complexity threshold.

## The 9-step loop

The order matters. Every round runs steps 1–9 unless an earlier step bails out.

### 1. Run `pr-comment-fixer:fix-issues`

Invoke the existing skill — do **not** re-fetch, re-parse, or re-fix manually. Pass the PR number (extracted from `gh pr view`) so the child skill knows which PR to target.

The child skill is responsible for: fetching unresolved review threads, reading the affected files, and applying surgical fixes. When the child skill returns, you should have an in-progress diff staged in the working tree (uncommitted).

If the child skill reports there are no unresolved comments at all on round 1, exit cleanly with "PR has no unresolved review comments — nothing to do". Do not push an empty round.

### 2. Inner loop: run `hardcore-code-reviewer:hardcore-code-reviewer` until clean

Run the hardcore reviewer **on the uncommitted diff** (not on `main..HEAD`):

```text
Invoke hardcore-code-reviewer:hardcore-code-reviewer with scope = uncommitted changes.
```

If the report has any `BLOCKING` or `IMPORTANT` findings, fix them in-place and re-run the reviewer. Repeat up to the inner-iteration cap (default `3`).

- Iteration 1: review → fix BLOCKING/IMPORTANT → re-review.
- Iteration 2: same.
- Iteration 3 (final): same. If the report is still not clean after iteration 3, **bail to the user** (do not push). The cap exists because if hardcore-reviewer cannot reach 0 BLOCKING/IMPORTANT after 3 passes, the underlying change is probably wrong — not the reviewer. Hand control back with the latest report.

`NIT`-level findings do not block the loop — record them but do not iterate further on them.

### 3. Run full project verification

Before pushing, run the project's full verification sequence (per the project's `CLAUDE.md`):

```bash
yarn build && yarn test:unit && yarn test:integration && yarn lint
```

If verification exits non-zero, **do not push**. Either:

- The failure is mechanical (typo, missing import) → fix and re-run the inner hardcore loop from step 2 (this consumes another inner iteration). If the inner cap is already exhausted, bail.
- The failure is structural (real broken behavior) → bail to the user with the failing output.

A failed verification is a hard gate. The skill must never push a commit that fails this sequence.

### 4. Commit and push

Auto-generate a commit message summarizing the round (e.g. `Round N: address copilot feedback (X comments) + hardcore-review fixes (Y findings)`). Commit and push:

```bash
git add -A
git commit -m "<auto-generated round summary>"
git push origin HEAD
```

Capture the SHA of the just-pushed commit and the timestamp of the push — both are needed for the next steps.

### 5. Resolve addressed GitHub review threads

For each unresolved review thread that was addressed by code changes in the just-pushed commit, resolve it via the GraphQL `resolveReviewThread` mutation.

First, fetch the unresolved thread IDs:

```bash
gh api graphql -f query='
  query($owner:String!,$repo:String!,$pr:Int!) {
    repository(owner:$owner, name:$repo) {
      pullRequest(number:$pr) {
        reviewThreads(first:100) {
          nodes {
            id
            isResolved
            comments(first:1) { nodes { path body } }
          }
        }
      }
    }
  }' -F owner=<OWNER> -F repo=<REPO> -F pr=<PR_NUMBER>
```

The `reviewThreads` field gives you the thread IDs, the file paths, and the comment bodies. Map each thread to whether the just-pushed commit actually changed code in that file at a relevant location. **Critical mapping rule:** never resolve a thread that was not addressed by a code change in the just-pushed commit. Specifically:

- The thread's file path must appear in the just-pushed commit's diff.
- The change must plausibly answer the comment (not a coincidental edit). When in doubt, leave the thread unresolved and let copilot decide on re-review.

For each thread that **was** addressed, resolve it:

```bash
gh api graphql -f query='
  mutation($threadId:ID!) {
    resolveReviewThread(input:{threadId:$threadId}) {
      thread { id isResolved }
    }
  }' -F threadId=<THREAD_ID>
```

Record the count of threads resolved this round.

### 6. Re-request copilot review

```bash
gh pr edit <PR_NUMBER> --add-reviewer @copilot
```

This re-triggers a fresh copilot review against the just-pushed HEAD. If the command errors with "Copilot is not assignable" or similar, surface the error to the user — likely the repo doesn't have copilot reviews enabled or `gh` is too old (`< 2.88`).

### 7. Poll for new copilot activity

Poll the PR every `60s` for a copilot review submitted **after** the push timestamp from step 4. Cap polling at `60 minutes` per round.

```bash
gh pr view <PR_NUMBER> --json reviews --jq \
  '.reviews | map(select(.author.login == "copilot-pull-request-reviewer[bot]")) | sort_by(.submittedAt) | last'
```

A round is complete when the latest copilot review's `submittedAt` is greater than the push timestamp from step 4. If the 60-min cap trips before that happens, bail to the user with: "copilot reviewer was silent past the 60-min cap on round N; manual follow-up required". Do not push anything else in that case.

### 8. Decide: continue, exit clean, or bail

Inspect the new copilot review fetched in step 7:

- If it submitted with **zero new unresolved comments**, exit clean. Print a final summary: rounds run, total comments addressed across rounds, total hardcore findings fixed, total threads resolved, final PR URL.
- If it submitted with new comments, increment the round counter and goto **step 1**.

### 9. Cap total rounds

If incrementing the round counter in step 8 would exceed the outer-round cap (default `8`), do not loop again. Bail to the user with a status summary describing why the cap tripped (most often: the reviewer keeps finding new issues round after round, which is a signal that the diff is too ambitious for an autonomous loop and needs human steering).

## Status reporting

On every transition between steps, log a one-line status update so the user can follow along:

- `[round N/8] step 1: invoking pr-comment-fixer:fix-issues for PR #1234`
- `[round N/8] step 2: hardcore review iteration 1/3 — 3 BLOCKING, 5 IMPORTANT`
- `[round N/8] step 3: yarn build && yarn test:unit && yarn test:integration && yarn lint → PASS`
- `[round N/8] step 4: pushed commit abc1234`
- `[round N/8] step 5: resolved 4/5 review threads (1 left for copilot judgment)`
- `[round N/8] step 6: re-requested @copilot review`
- `[round N/8] step 7: polling every 60s, cap 60m`
- `[round N/8] step 8: copilot returned 2 new comments → looping`

On bail-out, print the cap that tripped and the artifacts the user needs to inspect (latest hardcore report, last failing verification output, last copilot review URL).

## What this skill is NOT

- Not a code reviewer. It calls `hardcore-code-reviewer:hardcore-code-reviewer`.
- Not a per-comment fixer. It calls `pr-comment-fixer:fix-issues`.
- Not a generic PR automation. It only wraps the copilot review feedback loop and only fast-fails on missing PRs.
- Not a way to bypass the project verification sequence — `yarn build && yarn test:unit && yarn test:integration && yarn lint` is mandatory before every push.
- Not a way to mass-resolve review threads — the mapping rule for `resolveReviewThread` is strict on purpose.

## Out of scope

- Triggering reviewers other than copilot (could be added later via a `--reviewer` flag).
- Handling branches without an open PR (fail fast — see "Fail-fast" above).
- Building a new reviewer (we wrap the existing hardcore-code-reviewer).
