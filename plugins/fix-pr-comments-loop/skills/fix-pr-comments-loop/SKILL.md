---
name: fix-pr-comments-loop
description: Autonomous loop that drives a pull request to a clean review state by repeatedly fetching unresolved copilot review threads, fixing them via the pr-comment-fixer skill, hardening the diff via the hardcore-code-reviewer skill, running the project verification sequence detected from the host repo, pushing, resolving the addressed GitHub review threads, re-requesting copilot review, and polling until the reviewer signs off (zero new comments) or hard caps trip. Use this skill when the user wants to run a "fix-pr-comments loop", "address all PR comments and re-request review until clean", run an "autonomous PR fix loop", "drive PR to clean review", "auto-iterate PR comment fixes with hardcore review", or "loop fix-pr-comments until copilot is happy". Trigger proactively whenever the user asks to grind through copilot PR feedback rounds end-to-end, not just one round.
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

Before doing anything else, confirm there is an open PR for the current branch and capture the PR's owner/repo/number for later GraphQL calls:

```bash
gh pr view --json number,state,headRefName,url,baseRepository --jq '.'
```

Parse the result and stash three values for the rest of the loop:

- `OWNER` = `.baseRepository.owner.login`
- `REPO`  = `.baseRepository.name`
- `PR_NUMBER` = `.number`

Use these stashed values in every `gh api graphql -F owner=$OWNER -F repo=$REPO -F pr=$PR_NUMBER ...` call below — do not re-derive them per step.

If the command fails or returns `state != "OPEN"`, **abort immediately** with a message like:

> No open PR found for the current branch (`<branch>`). This skill only operates on open PRs — push the branch and open a PR first, then re-run.

Do not attempt any of the rest of the loop. This is a hard precondition.

## Verification command discovery (configurable per host repo)

This skill must run the host repo's verification sequence before pushing. The verification command is **not hardcoded**. Discover it in this priority order at the start of each run, and reuse the resolved command for every round:

1. **Explicit override (highest priority):** environment variable `FIX_PR_COMMENTS_LOOP_VERIFY` is set → use its value verbatim as the verification command.
2. **Skill argument:** if the caller passed a `verify=<command>` argument, use it.
3. **Project CLAUDE.md:** read the host repo's `CLAUDE.md` (root) and search for an explicit verification sequence (look for sections titled "Verification", "Tests", "Build", or a fenced code block immediately after one of those headers). If found, use that command.
4. **Auto-detect from package manifest:**
   - `package.json` present with a `yarn.lock` → `yarn build && yarn test && yarn lint` (only include subcommands that are present in `scripts`; skip ones that are not defined).
   - `package.json` present with `pnpm-lock.yaml` → equivalent `pnpm` form.
   - `package.json` present with `package-lock.json` → equivalent `npm run` form.
   - `pyproject.toml` with `[tool.pytest.ini_options]` or `pytest.ini` → `pytest` (plus `ruff check .` if `ruff` is configured).
   - `Makefile` with a `test` target → `make test`.
   - No manifest detectable → fall through to step 5.
5. **No-op fallback:** if none of the above resolves a command, set verification to a no-op (`true`) and **emit a one-line warning** in the round status: `[round N/<outer_cap>] step 3: no verification command discovered — skipping (set FIX_PR_COMMENTS_LOOP_VERIFY to enforce one)`.

The resolved command is the value used by step 3 below. **Do not hardcode `yarn ...` anywhere in this skill** — the priority above is the contract.

If the host repo's `CLAUDE.md` explicitly says "no build system, no tests" (markdown-only repos, etc.), the discovery step naturally falls through to the no-op fallback in step 5 — that is the documented behavior, not a bug.

## Caps and bail-outs (load-bearing safety rails)

These caps are NOT decorative — they exist to stop runaway loops on noisy reviewers and on diffs that the hardcore reviewer cannot wrangle to clean.

| Cap | Default | Meaning | What happens at cap |
|---|---|---|---|
| Inner hardcore-review iterations per round | `3` | How many times the hardcore reviewer can re-run within a single round before giving up | Bail to user with the latest hardcore report and the message "hardcore-reviewer could not reach 0 BLOCKING/IMPORTANT after N inner iterations — likely the change is wrong, not the reviewer" |
| Verification retries per round | `2` | How many times step 3's verification command can be re-attempted (after mechanical fixes) before bailing. **Independent** of the hardcore-review iteration cap. | Bail to user with the failing verification output and the message "verification failed N times this round — manual follow-up required" |
| Outer loop rounds | `8` | How many full fetch→fix→review→push→re-request cycles to run before giving up | Bail to user with a status summary listing per-round counts of comments addressed, hardcore findings, and copilot re-review responses |
| Copilot poll cap (per round) | `60 minutes`, polling every `60s` | How long to wait for copilot to submit a fresh review after `--add-reviewer @copilot` | Bail to user with "copilot reviewer was silent past the 60-min cap; not pushing further". Do not push anything after the cap trips. |

Caps must be **enforced**, not just documented. Do not enter iteration 4 of the inner review — bail at the end of iteration 3 if findings remain. Do not enter round 9 of the outer loop — bail at the end of round 8 if the reviewer is still finding new issues.

> **Note on polling cost:** the per-round cap of `60 minutes` × `60s` interval = up to 60 `gh` API calls per round, ≤ 480 across all 8 rounds in worst case. The interval is a simple constant; future enhancement: exponential backoff.

### Complexity threshold bail-outs

Some fixes cross a complexity threshold where the user MUST be in the loop. When the next step would require any of the following, **stop and ask the user** instead of applying autonomously:

- Multi-file refactor (the fix touches more than ~3 files unrelated to the original comment's file).
- Test removal or test-skip additions (`it.skip`, `xit`, `describe.skip`, deleting test cases, deleting whole test files).
- Public-API change (changing exported function signatures, package exports, REST/GraphQL schema, DB schema, or environment variables).
- Anything that would change behavior of a sibling endpoint/feature not mentioned in the original review thread.

These are the places where "address the comment" usually means a design discussion, not a mechanical fix. Hand control back to the user with a one-paragraph summary of what the fix would entail and why it crossed the complexity threshold.

## The 9-step loop

The order matters. Every round runs steps 1–9 unless an earlier step bails out.

### 0. Per-round prelude: count unresolved threads, bail if zero

Before invoking `pr-comment-fixer:fix-issues`, query the unresolved-thread count:

```bash
gh api graphql -f query='
  query($owner:String!,$repo:String!,$pr:Int!) {
    repository(owner:$owner, name:$repo) {
      pullRequest(number:$pr) {
        reviewThreads(first:100) {
          nodes { isResolved }
        }
      }
    }
  }' -F owner=$OWNER -F repo=$REPO -F pr=$PR_NUMBER \
  --jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)] | length'
```

If the count is `0`:

- On round 1: exit cleanly with "PR has no unresolved review comments — nothing to do".
- On rounds 2..N: exit cleanly with the standard end-of-loop summary (this is the success terminator on subsequent rounds, equivalent to copilot returning zero new comments).

This prevents wasting a full round on an empty PR.

### 1. Run `pr-comment-fixer:fix-issues`

Invoke the existing skill — do **not** re-fetch, re-parse, or re-fix manually. Pass the PR number (the stashed `$PR_NUMBER` from the fail-fast step) so the child skill knows which PR to target.

The child skill is responsible for: fetching unresolved review threads, reading the affected files, and applying surgical fixes. When the child skill returns, you should have an in-progress diff staged in the working tree (uncommitted) and a list of files it edited — record this list as `FIX_FILES` for use in step 4 staging.

### 2. Inner loop: run `hardcore-code-reviewer:hardcore-code-reviewer` until clean

Run the hardcore reviewer with a **scope that depends on the round**:

- **Round 1:** scope = uncommitted changes (the fixes from step 1 are not yet committed).
- **Rounds 2..N:** scope = `HEAD~1..HEAD` (the just-pushed commit from the previous round may have rolled in already; on the current round, uncommitted changes from this round's step 1 are still in the working tree, so the scope is still uncommitted changes — but be explicit when invoking).

Concretely, on each round, after step 1 completes, invoke:

```text
Invoke hardcore-code-reviewer:hardcore-code-reviewer with scope = uncommitted-changes (i.e. the working-tree diff produced by step 1 of THIS round).
```

If the report has any `BLOCKING` or `IMPORTANT` findings, fix them in-place and re-run the reviewer. Repeat up to the inner-iteration cap (default `3`). Record the list of files edited by these inner-loop fixes as `INNER_FIX_FILES` for use in step 4 staging.

- Iteration 1: review → fix BLOCKING/IMPORTANT → re-review.
- Iteration 2: same.
- Iteration 3 (final): same. If the report is still not clean after iteration 3, **bail to the user** (do not push). The cap exists because if hardcore-reviewer cannot reach 0 BLOCKING/IMPORTANT after 3 passes, the underlying change is probably wrong — not the reviewer. Hand control back with the latest report.

`NIT`-level findings do not block the loop — record them but do not iterate further on them.

Track the count of BLOCKING+IMPORTANT findings on the **first** hardcore report of this round versus the **final** report — the difference is the `Y` value used in the round-summary commit message in step 4.

### 3. Run host-repo verification

Run the verification command resolved by the discovery rules in the "Verification command discovery" section above. Examples (depending on host repo):

```bash
# explicit override
$FIX_PR_COMMENTS_LOOP_VERIFY

# yarn project (auto-detected)
yarn build && yarn test && yarn lint

# python project (auto-detected)
pytest && ruff check .

# markdown-only repo (no-op fallback) → skip with warning
true
```

If verification exits non-zero, **do not push**. Decision tree:

- The failure is mechanical (typo, missing import) → fix and re-run **only the verification command** (not the inner hardcore loop). This counts toward the **verification-retries cap** (default 2), not the hardcore-review iteration cap. After the fix, re-run step 3 from the top.
- The failure is structural (real broken behavior) → bail to the user with the failing output.
- Verification has now bounced more times than the cap allows → bail to the user with the failing output and the message "verification failed N times this round — manual follow-up required".

A failed verification is a hard gate. The skill must never push a commit that fails this sequence.

### 4. Commit and push (explicit-path staging only)

Stage **only the files actually edited by this round**. Do not use `git add -A` or `git add .` — those can sweep in `.env`, credentials, build artifacts, or harness scratch files (e.g. `PLAN.md`, `TASK.md`, `.harness-state.md`) that the user did not intend to push to a public PR.

The list of files to stage is the **union** of:

- `FIX_FILES` — the files edited by `pr-comment-fixer:fix-issues` in step 1 of this round.
- `INNER_FIX_FILES` — the files edited during the hardcore-review inner loop in step 2 of this round.

Stage them by explicit path:

```bash
git add -- "<file1>" "<file2>" ...   # one path per item, no globs
```

After staging, **gate** with `git status --short` and verify only the expected paths are staged. If anything unexpected appears (untracked secrets, unrelated edits), **bail to the user** with the unexpected entries listed — do not push.

Auto-generate the round commit message. The message is **deterministic**:

```text
Round N: address copilot feedback (X comments) + hardcore-review fixes (Y findings)
```

Where:

- `N` = the current round number (1-based).
- `X` = the count of unresolved threads addressed in this round, defined as the number of distinct review threads for which a `resolveReviewThread` mutation was issued in step 5 of this round (computed at end of step 5 — for the commit message in step 4, use the count of threads that pr-comment-fixer reported as addressed in step 1).
- `Y` = the count of `BLOCKING + IMPORTANT` findings the inner hardcore-review loop fixed this round, defined as `(BLOCKING+IMPORTANT count on iteration 1's first report) - (BLOCKING+IMPORTANT count on the final iteration's report)`. If the inner loop ran only 1 iteration (clean on first pass), `Y = 0`.

Commit and push:

```bash
git commit -m "<deterministic round summary computed above>"
git push origin HEAD
```

Capture the SHA of the just-pushed commit (`PUSHED_SHA`) and the timestamp of the push (`PUSH_TS`) — both are needed for step 5 (mapping rule) and step 7 (review-attached-to-commit filter).

### 5. Resolve addressed GitHub review threads

For each unresolved review thread that was addressed by code changes in the just-pushed commit, resolve it via the GraphQL `resolveReviewThread` mutation.

First, fetch the unresolved threads with the metadata needed to apply the strict mapping rule below:

```bash
gh api graphql -f query='
  query($owner:String!,$repo:String!,$pr:Int!) {
    repository(owner:$owner, name:$repo) {
      pullRequest(number:$pr) {
        reviewThreads(first:100) {
          nodes {
            id
            isResolved
            path
            line
            originalLine
            startLine
            originalStartLine
            comments(first:1) { nodes { body } }
          }
        }
      }
    }
  }' -F owner=$OWNER -F repo=$REPO -F pr=$PR_NUMBER
```

**Strict mapping rule** (replaces vibes-based "the change must plausibly answer the comment"):

A thread is eligible for resolution iff **all** of the following hold:

1. The thread's `path` appears in `git diff --name-only $PUSHED_SHA^..$PUSHED_SHA` (i.e. the just-pushed commit modified that file).
2. The just-pushed commit's diff modifies at least one line in `$thread.path` within the range `[ (originalStartLine ?? originalLine) - 5, originalLine + 5 ]` (i.e. within ±5 lines of the comment's anchor). Use `originalLine` / `originalStartLine` (the line in the version reviewed), not `line` (which may have shifted).

Threads that do not satisfy both conditions stay unresolved. **On uncertainty, leave unresolved** and let copilot decide on re-review.

For each thread that **does** pass the mapping rule, resolve it:

```bash
gh api graphql -f query='
  mutation($threadId:ID!) {
    resolveReviewThread(input:{threadId:$threadId}) {
      thread { id isResolved }
    }
  }' -F threadId=<THREAD_ID>
```

Record the count of threads resolved this round — this is the authoritative `X` for the round summary (recompute and prepare it for the round status report; the commit-message `X` was a forward estimate from step 1 and is acceptable to be slightly off in either direction).

### 6. Re-request copilot review

```bash
gh pr edit $PR_NUMBER --add-reviewer @copilot
```

This re-triggers a fresh copilot review against the just-pushed HEAD. **Error-handling rule** (the command can fail benignly):

- If `stderr` contains `already requested`, `already added`, `already a reviewer`, or similar idempotency phrasing → treat as **success** and continue to step 7.
- If `stderr` contains `not assignable`, `permission`, `not found`, or similar **fatal** phrasing → **bail to the user**: likely the repo doesn't have copilot reviews enabled or `gh` is too old (`< 2.88`).
- Any other non-zero exit → bail to the user with the raw `stderr`.

### 7. Poll for new copilot activity (commit-anchored, not timestamp-anchored)

Poll the PR every `60s` for a copilot review **attached to the commit pushed in step 4** (`$PUSHED_SHA`), not just any review submitted after `$PUSH_TS`. Cap polling at `60 minutes` per round.

**Bot login discovery (do once, reuse across rounds):** the copilot bot's `login` is not a fixed string. On round 1, query the existing reviews and capture the login of the first review whose author looks like a copilot bot (case-insensitive `startswith("copilot")` or matches regex `(?i)copilot`). Stash this as `COPILOT_LOGIN`. Reuse it on subsequent rounds. If round 1 has no prior copilot review and `COPILOT_LOGIN` is not yet known, fall back to matching any author whose login satisfies `(.author.login | ascii_downcase | startswith("copilot"))` until a concrete login is observed.

Polling query:

```bash
gh api graphql -f query='
  query($owner:String!,$repo:String!,$pr:Int!) {
    repository(owner:$owner, name:$repo) {
      pullRequest(number:$pr) {
        reviews(last:50) {
          nodes {
            id
            author { login }
            state
            submittedAt
            commit { oid }
            comments(first:0) { totalCount }
          }
        }
      }
    }
  }' -F owner=$OWNER -F repo=$REPO -F pr=$PR_NUMBER \
  --jq --arg sha "$PUSHED_SHA" --arg login "$COPILOT_LOGIN" '
    .data.repository.pullRequest.reviews.nodes
    | map(select(
        ((.author.login | ascii_downcase | startswith("copilot"))
         or (.author.login == $login))
        and .commit.oid == $sha
      ))
    | sort_by(.submittedAt) | last'
```

A round is complete when a copilot review for the just-pushed `$PUSHED_SHA` is observed. **Filter by `commit.oid == $PUSHED_SHA`**, not by `submittedAt > $PUSH_TS` — a delayed previous-round review can satisfy a timestamp filter and falsely terminate the round; the commit OID can't.

If the 60-min cap trips before that happens, bail to the user with: "copilot reviewer was silent past the 60-min cap on round N; manual follow-up required". Do not push anything else in that case.

### 8. Decide: continue, exit clean, or bail

Inspect the new copilot review fetched in step 7. To count "new comments", count unresolved review threads anchored to `$PUSHED_SHA` (or, equivalently, count comments on the just-fetched review) — not all unresolved threads on the PR (some may have been intentionally left unresolved by step 5's strict mapping rule and would otherwise spin the loop forever).

- If the latest copilot review on `$PUSHED_SHA` submitted with **zero new unresolved comments**, exit clean. Print a final summary: rounds run, total comments addressed across rounds, total hardcore findings fixed, total threads resolved, final PR URL.
- If it submitted with new comments, increment the round counter and goto **step 0** (the prelude).

### 9. Cap total rounds

If incrementing the round counter in step 8 would exceed the outer-round cap (default `8`), do not loop again. Bail to the user with a status summary describing why the cap tripped (most often: the reviewer keeps finding new issues round after round, which is a signal that the diff is too ambitious for an autonomous loop and needs human steering).

## Status reporting

On every transition between steps, log a one-line status update so the user can follow along. The `<cap>` placeholder is the configured outer cap (default 8) — **do not hardcode the literal "8"** so that operators changing the cap see consistent output.

- `[round N/<cap>] step 0: 12 unresolved threads → continuing`
- `[round N/<cap>] step 1: invoking pr-comment-fixer:fix-issues for PR #1234`
- `[round N/<cap>] step 2: hardcore review iteration 1/3 — 3 BLOCKING, 5 IMPORTANT`
- `[round N/<cap>] step 3: <resolved verification command> → PASS`
- `[round N/<cap>] step 4: pushed commit abc1234`
- `[round N/<cap>] step 5: resolved 4/5 review threads (1 left for copilot judgment)`
- `[round N/<cap>] step 6: re-requested @copilot review`
- `[round N/<cap>] step 7: polling every 60s, cap 60m`
- `[round N/<cap>] step 8: copilot returned 2 new comments on $PUSHED_SHA → looping`

On bail-out, print the cap that tripped and the artifacts the user needs to inspect (latest hardcore report, last failing verification output, last copilot review URL).

## What this skill is NOT

- Not a code reviewer. It calls `hardcore-code-reviewer:hardcore-code-reviewer`.
- Not a per-comment fixer. It calls `pr-comment-fixer:fix-issues`.
- Not a generic PR automation. It only wraps the copilot review feedback loop and only fast-fails on missing PRs.
- Not a way to bypass the host-repo verification sequence — the verification command resolved by the discovery rules above is mandatory before every push (or, if no command can be discovered, a one-line warning is logged and the verification step becomes a no-op).
- Not a way to mass-resolve review threads — the mapping rule for `resolveReviewThread` is strict on purpose.

## Out of scope

- Triggering reviewers other than copilot (could be added later via a `--reviewer` flag).
- Handling branches without an open PR (fail fast — see "Fail-fast" above).
- Building a new reviewer (we wrap the existing hardcore-code-reviewer).
