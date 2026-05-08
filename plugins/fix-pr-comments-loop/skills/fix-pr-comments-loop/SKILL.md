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
gh pr view --json number,state,headRefName,url,baseRepository
```

Parse the result and stash three values for the rest of the loop:

- `OWNER` = `.baseRepository.owner.login`
- `REPO`  = `.baseRepository.name`
- `PR_NUMBER` = `.number`

Use these stashed values in every `gh api graphql -F owner=$OWNER -F repo=$REPO -F pr=$PR_NUMBER ...` call below — do not re-derive them per step.

If the command fails or returns `state != "OPEN"`, **abort immediately** with a message like:

> No open PR found for the current branch (`<branch>`). This skill only operates on open PRs — push the branch and open a PR first, then re-run.

Do not attempt any of the rest of the loop. This is a hard precondition.

### Limitations: fork PRs

This skill assumes the head and base of the PR are in the same repo. For fork PRs, the just-pushed SHA may not be visible to the upstream API immediately after `git push`; if you need fork-PR support, add a `gh api repos/$OWNER/$REPO/commits/$PUSHED_SHA` poll-for-existence (with a short timeout, e.g. 60s) between steps 4 and 5 before relying on the SHA in upstream GraphQL queries.

### Cross-round state

Skills are stateless across invocations. The executing agent must track `OWNER`, `REPO`, `PR_NUMBER`, `COPILOT_LOGIN`, and the round counter across rounds in TodoWrite or in-memory for the duration of the run. These do not persist across sessions; if the run is interrupted, the next session re-derives them by re-running the fail-fast step above and re-discovering the bot login from the next polled review (see step 7 — initialize `COPILOT_LOGIN=""` on round 1 if no prior copilot review exists).

## Verification command discovery (configurable per host repo)

This skill must run the host repo's verification sequence before pushing. The verification command is **not hardcoded**. Discover it in this priority order at the start of each run, and reuse the resolved command for every round:

1. **Explicit override (highest priority):** environment variable `FIX_PR_COMMENTS_LOOP_VERIFY` is set → use its value verbatim as the verification command.
2. **Skill argument:** if the caller passed a `verify=<command>` argument, use it.
3. **Project CLAUDE.md:** read the host repo's `CLAUDE.md` (root) and search for an explicit verification sequence (look for sections titled "Verification", "Tests", "Build", or a fenced code block immediately after one of those headers). If found, use that command.
4. **Auto-detect from package manifest:**
   - `package.json` present with a `yarn.lock` → `yarn build && yarn test && yarn lint` (see "Script intersection" below — only include subcommands that are defined in `scripts`).
   - `package.json` present with `pnpm-lock.yaml` → equivalent `pnpm` form.
   - `package.json` present with `package-lock.json` → equivalent `npm run` form.
   - `pyproject.toml` with `[tool.pytest.ini_options]` or `pytest.ini` → `pytest` (plus `ruff check .` if `ruff` is configured).
   - `Makefile` with a `test` target → `make test`.
   - No manifest detectable → fall through to step 5.

   **Script intersection (Node.js auto-detect):** Before composing the chain, run `jq -r '.scripts | keys[]' package.json` (or use the Read tool to read `package.json` and parse the `scripts` object) and intersect the keys with `[build, test, lint]`. Compose the chain from only the subcommands present in that intersection, in that order. If the intersection is empty, fall through to step 5 (no-op fallback) — do not invoke `yarn`/`pnpm`/`npm` with no subcommands.

   **Lockfile tie-breaker:** If multiple lockfiles are present in the same repo (e.g. both `yarn.lock` and `package-lock.json`), the host repo's package-manager intent is ambiguous. Fall through to step 5 (no-op fallback) with a one-line warning to the user describing which lockfiles were detected. Do not guess.
5. **No-op fallback:** if none of the above resolves a command, set verification to a no-op (`true`) and **emit a one-line warning** in the round status: `[round N/<outer_cap>] step 3: no verification command discovered — skipping (set FIX_PR_COMMENTS_LOOP_VERIFY to enforce one)`.

The resolved command is the value used by step 3 below. **Do not hardcode `yarn ...` anywhere in this skill** — the priority above is the contract.

If the host repo's `CLAUDE.md` explicitly says "no build system, no tests" (markdown-only repos, etc.), the discovery step naturally falls through to the no-op fallback in step 5 — that is the documented behavior, not a bug.

## Caps and bail-outs (load-bearing safety rails)

These caps are NOT decorative — they exist to stop runaway loops on noisy reviewers and on diffs that the hardcore reviewer cannot wrangle to clean.

| Cap | Default | Meaning | What happens at cap |
|---|---|---|---|
| Inner hardcore-review iterations per round | `3` | How many times the hardcore reviewer can re-run within a single round before giving up | Bail to user with the latest hardcore report and the message "hardcore-reviewer could not reach 0 BLOCKING/IMPORTANT after N inner iterations — likely the change is wrong, not the reviewer" |
| Verification retries per round | `2` | How many times step 3's verification command can be re-attempted (after **purely mechanical** fixes — typos in string literals, missing imports, etc.) before bailing. **Independent** of the hardcore-review iteration cap. If a verification-retry fix touches any logic-bearing code, the retry budget does NOT apply: re-enter step 2 from inner-iteration 1 of THIS round (consuming an inner-loop iteration budget) so the hardcore reviewer re-vets the change. | Bail to user with the failing verification output and the message "verification failed N times this round — manual follow-up required" |
| Outer loop rounds | `8` | How many full fetch→fix→review→push→re-request cycles to run before giving up | Bail to user with a status summary listing per-round counts of comments addressed, hardcore findings, and copilot re-review responses |
| Copilot poll cap (per round) | `60 minutes`, polling every `60s` | How long to wait for copilot to submit a fresh review after `--add-reviewer @copilot` | Bail to user with "copilot reviewer was silent past the 60-min cap; not pushing further". Do not push anything after the cap trips. |

Caps must be **enforced**, not just documented. Do not enter iteration 4 of the inner review — bail at the end of iteration 3 if findings remain. Do not enter round 9 of the outer loop — bail at the end of round 8 if the reviewer is still finding new issues.

> **Note on polling cost:** the per-round cap of `60 minutes` × `60s` interval = up to 60 `gh` API calls per round, ≤ 480 across all 8 rounds in worst case. The interval is a simple constant; future enhancement: exponential backoff. (60s balances rate-limit budget and user-perceived responsiveness; tighter polling burns rate limit, looser polling makes rounds feel sluggish.)
>
> **Rate-limit back-off:** On `gh api` 403 / rate-limit errors during polling or any other GraphQL call in this loop, exponentially back off (60s → 120s → 240s → bail at 480s) and retry. After the final back-off, bail to the user with the raw `gh` error and a "GitHub API rate-limit exhausted; manual follow-up required" message. This is a known failure mode on busy repos with many concurrent automated workflows.

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

Before invoking `pr-comment-fixer:fix-issues`, query the unresolved-thread count. Use the same paginated pattern as step 5 (`reviewThreads(first:100, after:$cursor)` with `pageInfo`) and aggregate across pages so a PR with more than 100 threads is not under-counted:

```bash
gh api graphql -f query='
  query($owner:String!,$repo:String!,$pr:Int!,$cursor:String) {
    repository(owner:$owner, name:$repo) {
      pullRequest(number:$pr) {
        reviewThreads(first:100, after:$cursor) {
          pageInfo { hasNextPage endCursor }
          nodes { isResolved }
        }
      }
    }
  }' -F owner=$OWNER -F repo=$REPO -F pr=$PR_NUMBER -F cursor=$CURSOR \
  --jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)] | length'
```

Sum the per-page unresolved counts to get the round's total. Drive `CURSOR` exactly as in step 5.

If the count is `0`:

- On round 1: exit cleanly with "PR has no unresolved review comments — nothing to do".
- On rounds 2..N: exit cleanly with the standard end-of-loop summary (this is the success terminator on subsequent rounds, equivalent to copilot returning zero new comments).

This prevents wasting a full round on an empty PR.

### 1. Run `pr-comment-fixer:fix-issues`

Invoke the existing skill — do **not** re-fetch, re-parse, or re-fix manually. Pass the PR number (the stashed `$PR_NUMBER` from the fail-fast step) so the child skill knows which PR to target.

The child skill is responsible for: fetching unresolved review threads, reading the affected files, and applying surgical fixes. When the child skill returns, the working tree should contain its uncommitted edits.

`pr-comment-fixer:fix-issues` does **not** define a structured "files I edited" return value. Do not rely on it to enumerate edited files. Instead, derive `FIX_FILES` from the working tree directly:

1. **Before** invoking the child skill, snapshot the working tree state: `git status --porcelain > /tmp/pre-fix-status.txt`.
2. **After** the child skill returns, run `git status --porcelain` again and diff against the snapshot. Any path whose status entry differs (new, modified, or appearing-only-in-the-after-snapshot) is part of `FIX_FILES`.
3. Use the resulting `FIX_FILES` list in step 4 staging.

Also separately record the count of distinct review threads `pr-comment-fixer` reported as addressed in this round (call this `THREADS_CLAIMED_ADDRESSED`) — used for the commit-message `X` in step 4.

### 2. Inner loop: run `hardcore-code-reviewer:hardcore-code-reviewer` until clean

On every round (round 1 and rounds 2..N alike), the scope passed to the hardcore reviewer is the **uncommitted working-tree diff produced by step 1 of THIS round**. There is no per-round variation — committed previous-round work is not re-reviewed; only the current round's not-yet-committed fixes are in scope.

Concretely, on each round, after step 1 completes, invoke:

```text
Invoke hardcore-code-reviewer:hardcore-code-reviewer with scope = uncommitted-changes (i.e. the working-tree diff produced by step 1 of THIS round).
```

If the report has any `BLOCKING` or `IMPORTANT` findings, fix them in-place and re-run the reviewer. Repeat up to the inner-iteration cap (default `3`). Record the list of files edited by these inner-loop fixes as `INNER_FIX_FILES` for use in step 4 staging.

- Iteration 1: review → fix BLOCKING/IMPORTANT → re-review.
- Iteration 2: same.
- Iteration 3 (final): same. If the report is still not clean after iteration 3, **bail to the user** (do not push). The cap exists because if hardcore-reviewer cannot reach 0 BLOCKING/IMPORTANT after 3 passes, the underlying change is probably wrong — not the reviewer. Hand control back with the latest report.

`MINOR`-level findings do not block the loop — record them but do not iterate further on them.

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

**Recovery when this gate fails.** The skill will NOT silently include or exclude unexpected entries. The user has three explicit options to make progress on the next run:

- (a) Add the unexpected entries to `.gitignore` and re-run, if they are local artifacts that should never be committed.
- (b) `git stash -u` them and re-run, if they are unrelated work-in-progress that the user wants to preserve but exclude from this PR.
- (c) `git rm --cached <path>` them (then commit that as a separate hygiene change) if they were accidentally tracked at some prior point and should leave the tree.

Pick exactly one. The skill does not have enough context to decide which is right.

Auto-generate the round commit message. The message is **deterministic**:

```text
Round N: address copilot feedback (X comments) + hardcore-review fixes (Y findings)
```

Where:

- `N` = the current round number (1-based).
- `X` = `THREADS_CLAIMED_ADDRESSED` — the count of distinct review threads `pr-comment-fixer:fix-issues` reported as addressed in step 1 of THIS round. This is the value committed in the message; the authoritative resolution count from step 5 may differ slightly (the strict mapping rule may resolve fewer or, in rare cases, more) and is reported separately in the round status output, not in the commit subject.
- `Y` = the count of `BLOCKING + IMPORTANT` findings the inner hardcore-review loop fixed this round, defined as `(BLOCKING+IMPORTANT count on iteration 1's first report) - (BLOCKING+IMPORTANT count on the final iteration's report)`. If the inner loop ran only 1 iteration (clean on first pass), `Y = 0`.

Commit and push. Before pushing, fetch + rebase to avoid a silent race with concurrent pushes (other automation, or the user pushing manually from another terminal):

```bash
git commit -m "<deterministic round summary computed above>"

# Fetch + rebase to detect concurrent pushes BEFORE pushing.
BRANCH=$(git rev-parse --abbrev-ref HEAD)
git fetch origin "$BRANCH"
git rebase "origin/$BRANCH" || {
  echo "concurrent push detected; manual resolution required"
  # Bail: do NOT auto-merge, do NOT --skip, do NOT --abort silently.
  # The user must resolve the conflict, re-run the loop afterwards.
  exit 1
}

git push origin HEAD
```

If the `rebase` step exits non-zero (real conflict between concurrent pushes), bail to the user with a "concurrent push detected; manual resolution required" message and do not auto-merge, do not force-push, do not `--skip` rebase commits. Hand control back so the user can resolve the conflict before re-running the loop.

Capture the SHA of the just-pushed commit (`PUSHED_SHA`) and the timestamp of the push (`PUSH_TS`) — both are needed for step 5 (mapping rule) and step 7 (review-attached-to-commit filter).

### 5. Resolve addressed GitHub review threads

For each unresolved review thread that was addressed by code changes in the just-pushed commit, resolve it via the GraphQL `resolveReviewThread` mutation.

First, fetch the unresolved threads with the metadata needed to apply the strict mapping rule below. **Paginate** the `reviewThreads` connection — `first:100` silently caps a noisy PR — by looping with `after: $cursor` until `pageInfo.hasNextPage` is false. The query template:

```bash
gh api graphql -f query='
  query($owner:String!,$repo:String!,$pr:Int!,$cursor:String) {
    repository(owner:$owner, name:$repo) {
      pullRequest(number:$pr) {
        reviewThreads(first:100, after:$cursor) {
          pageInfo { hasNextPage endCursor }
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
  }' -F owner=$OWNER -F repo=$REPO -F pr=$PR_NUMBER -F cursor=$CURSOR
```

Drive a loop in the executing agent: start with `CURSOR=null`, accumulate `nodes`, then re-run with `CURSOR=<endCursor>` until `hasNextPage` is `false`. As a safety check, if a single page returns `length(nodes) >= 100` and pagination has not yet been implemented end-to-end (e.g. dry-run mode), emit a one-line warning to the user that the page cap was hit so a missed thread is visible rather than silent.

**Strict mapping rule** (replaces vibes-based "the change must plausibly answer the comment"):

A thread is eligible for resolution iff **all** of the following hold:

1. The thread's `path` appears in `git diff --name-only $PUSHED_SHA^..$PUSHED_SHA` (i.e. the just-pushed commit modified that file).
2. The just-pushed commit's diff modifies at least one line in `$thread.path` within the range `[ (startLine ?? line) - 5, line + 5 ]` (i.e. within ±5 lines of the comment's **current-coordinate** anchor on the latest commit).

   **Coordinate space.** `git diff $PUSHED_SHA^..$PUSHED_SHA` produces line numbers in current (post-edit) coordinate space. GitHub's `line` / `startLine` fields on a `PullRequestReviewThread` are also in current coordinate space — anchored to the latest commit on the PR. The `originalLine` / `originalStartLine` fields are anchored to the commit the review was originally posted against (pre-edit space). Comparing a current-coordinate diff against pre-edit anchors is wrong and drifts after every push.

   Use `line` / `startLine` for the comparison. Fall back to `originalLine` / `originalStartLine` ONLY when `line` is null (which can happen when GitHub has not yet recomputed the anchor — rare but possible immediately after a push). The fallback is best-effort; if both are null, leave the thread unresolved.

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

**Bot login discovery (do once, reuse across rounds):** the copilot bot's `login` is not a fixed string. To avoid false positives on user accounts whose login happens to start with `copilot` (e.g. `copilotAdvocate`), the bot filter requires BOTH `author.__typename == "Bot"` AND `(author.login | ascii_downcase | startswith("copilot"))`.

On round 1, query the existing reviews and capture the login of the first review whose author satisfies that combined filter. Stash this as `COPILOT_LOGIN`. Reuse it on subsequent rounds.

If round 1 has no prior copilot review, **explicitly initialize `COPILOT_LOGIN=""`** before entering the polling loop. While `COPILOT_LOGIN` is empty, the polling filter relies entirely on the `__typename == "Bot"` AND login-prefix filter (the equality clause `author.login == $login` is dead-weight when `$login` is empty and is intentionally OR'd with the bot filter so polling still works). Once the first copilot review is observed in any round, capture its login into `COPILOT_LOGIN` and reuse on later rounds.

Polling query — note the jq filter is a single shell-interpolated expression (passed as a single argument to `--jq`); `--arg` is not a flag accepted by `gh`'s `--jq`, so the shell variables `$PUSHED_SHA` and `$COPILOT_LOGIN` are interpolated into the jq filter string with proper escaping of the inner double-quotes:

```bash
gh api graphql -f query='
  query($owner:String!,$repo:String!,$pr:Int!) {
    repository(owner:$owner, name:$repo) {
      pullRequest(number:$pr) {
        reviews(last:50) {
          nodes {
            id
            author { __typename login }
            state
            submittedAt
            commit { oid }
            comments(first:0) { totalCount }
          }
        }
      }
    }
  }' -F owner=$OWNER -F repo=$REPO -F pr=$PR_NUMBER \
  --jq "
    .data.repository.pullRequest.reviews.nodes
    | map(select(
        (
          (.author.__typename == \"Bot\" and (.author.login | ascii_downcase | startswith(\"copilot\")))
          or (.author.login == \"$COPILOT_LOGIN\" and \"$COPILOT_LOGIN\" != \"\")
        )
        and (((.commit.oid // \"\") == \"$PUSHED_SHA\") or (.submittedAt > \"$PUSH_TS\"))
      ))
    | sort_by(.submittedAt) | last
  "
```

If you prefer not to interpolate inside a quoted jq filter, the alternative is to fetch the raw JSON without `--jq` and pipe through a separate `jq --arg sha "$PUSHED_SHA" --arg login "$COPILOT_LOGIN" '...'` invocation — both are correct; pick one and stick to it.

A round is complete when a copilot review for the just-pushed `$PUSHED_SHA` is observed. **Filter on `commit.oid == $PUSHED_SHA`** — but `commit.oid` can be `null` for some bot review paths, so coalesce to empty string (`(.commit.oid // "") == $sha`) before comparing, and additionally accept reviews with `submittedAt > $PUSH_TS` as a defense-in-depth fallback. This dual-criterion is intentional: the OID filter is the primary signal, and the timestamp filter catches review-types where GitHub does not populate `commit.oid` for bots. A delayed previous-round review submitted before `$PUSH_TS` is excluded by the timestamp half; a same-round review with `commit.oid` populated is caught by the OID half.

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
