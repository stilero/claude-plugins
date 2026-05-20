---
name: fix-pr-comments-loop-round
description: Single-round executor for the fix-pr-comments-loop orchestrator. Runs steps 0–8 of one round (count unresolved threads, fix via pr-comment-fixer, harden via hardcore-code-reviewer, verify, push, resolve threads, re-request copilot, poll) in a fresh subagent context and returns a structured JSON result. Invoked once per round by the fix-pr-comments-loop orchestrator via the Agent tool — not for direct user invocation. Do not trigger this skill on user phrases like "fix PR comments", "drive PR to clean review", or any of the other fix-pr-comments-loop trigger phrases; those go to the orchestrator skill (`fix-pr-comments-loop`) which then dispatches into this one. Advanced users debugging a single round can invoke it explicitly via the Skill tool.
---

# fix-pr-comments-loop-round

Per-round executor for the `fix-pr-comments-loop` orchestrator. The orchestrator dispatches one fresh Agent-tool subagent per round, the subagent loads this skill, runs steps 0–8 against the supplied prompt args, and emits a single fenced ```` ```json ```` block as the last thing in its output so the orchestrator can parse the round's outcome and decide whether to loop, exit clean, or bail.

This skill **does not re-implement** the fix logic or the hardcore review logic. It orchestrates the existing skills `pr-comment-fixer:fix-issues` and `hardcore-code-reviewer:hardcore-code-reviewer` within a single round.

## Prompt args (supplied by orchestrator)

The orchestrator passes the following values via the Agent-tool prompt body. The subagent does NOT re-derive them and does NOT re-validate the open-PR / clean-working-tree preconditions — the orchestrator already did. Reading the orchestrator-supplied args as-is is the contract.

Required:

- `ROUND` — the current round number (1-based integer). Drives the `[round N/<cap>]` status prefix and the deterministic round commit message in step 4.
- `OUTER_CAP` — the configured outer-round cap (default 8). Used purely for the `[round N/<cap>]` status prefix; the subagent does not enforce the cap itself (that lives in the orchestrator).
- `OWNER`, `REPO`, `PR_NUMBER` — used in every `gh api graphql -F owner=$OWNER -F repo=$REPO -F pr=$PR_NUMBER ...` call below.
- `BASE_BRANCH` — used in step 5's `git merge-base "origin/$BASE_BRANCH" HEAD` for the mapping-rule diff.
- `COPILOT_REVIEWER` — the resolved reviewer login (already de-`@`-prefixed by the orchestrator; e.g. `copilot-pull-request-reviewer`). Used in step 6's `gh pr edit "$PR_NUMBER" --add-reviewer "$COPILOT_REVIEWER"`.
- `VERIFY_CMD` — the verification command string the orchestrator resolved at run start (e.g. `npm run build && npm test && npm run lint`, `pytest && ruff check .`, `make test`, or an explicit override). The subagent runs this verbatim in step 3.
- `INNER_ITERATION_CAP` — default `3`. Cap on hardcore-review iterations within this round (step 2).
- `POLL_CAP_MINUTES` — default `60`. Cap on copilot polling duration within this round (step 7).
- `POLL_INTERVAL_SECONDS` — default `60`. Interval between polling attempts.
- `COMPLEXITY_THRESHOLD` — default `3`. Max number of files (in the union `FIX_FILES ∪ INNER_FIX_FILES`) unrelated to the original comment's file before the round bails to the user.
- `RESOLVE_WINDOW` — default `20`. Half-window size (lines on each side) for the strict mapping rule in step 5.

State carried across rounds by the orchestrator:

- `COPILOT_LOGIN` — empty string `""` on the first round (no prior copilot review observed). Once any round observes a copilot review and captures the login, the orchestrator threads it through to subsequent rounds via this arg. The subagent uses the supplied value verbatim and, if it captures a new value during step 7, returns it in the JSON result so the orchestrator can persist it.

Optional (debug / static-check use):

- The subagent may itself be invoked directly (without an orchestrator) for debugging a single round. In that case the caller must supply all required args explicitly. The skill makes no attempt to discover args from the environment when invoked standalone — that is the orchestrator's job.

## Shell execution environment

Every shell pipeline in this skill (especially `gh ... | jq ...` invocations, of which there are many) should run with `set -o pipefail` so an upstream `gh` failure surfaces instead of being silently swallowed by a downstream `jq` that succeeds against empty stdin. The agent harness's bash session does NOT enable `pipefail` by default — set it explicitly at the start of any subshell or function that runs these pipelines.

## Prerequisites (assumed already validated by the orchestrator)

- `gh` CLI version `>= 2.88` (needed for `gh pr edit --add-reviewer "$COPILOT_REVIEWER"`).
- An open PR for the current branch on GitHub (orchestrator confirmed this via fail-fast).
- The two child skills installed and triggerable: `pr-comment-fixer:fix-issues` and `hardcore-code-reviewer:hardcore-code-reviewer`.
- A clean working tree at the start of this round (orchestrator confirmed on round 1; rounds 2..N start clean because the previous round's commit landed cleanly).

### Limitations: fork PRs

This skill assumes the head and base of the PR are in the same repo. For fork PRs, the just-pushed SHA may not be visible to the upstream API immediately after `git push`; if you need fork-PR support, add a `gh api repos/$OWNER/$REPO/commits/$PUSHED_SHA` poll-for-existence (with a short timeout, e.g. 60s) between steps 4 and 5 before relying on the SHA in upstream GraphQL queries.

### Within-round state

Per-round derived state (`PUSHED_SHA`, `PUSH_TS`, `MERGE_BASE`, `FIX_FILES`, `INNER_FIX_FILES`, `THREADS_CLAIMED_ADDRESSED`) is tracked in-memory by the subagent — including the snapshot of `git status --porcelain` taken before invoking `pr-comment-fixer:fix-issues` in step 1. Do **not** write the snapshot or any other per-round scratch state to a file under `/tmp/...` (racy across parallel runs and rarely cleaned up). Hold it in TodoWrite or in-context for the round.

If you must materialize the snapshot to disk for a downstream tool (rare), use a `mktemp`-allocated path with an `EXIT` cleanup trap:

```bash
SNAPSHOT=$(mktemp "${TMPDIR:-/tmp}/fix-pr-comments-loop.XXXXXX")
trap 'rm -f "$SNAPSHOT"' EXIT
git status --porcelain > "$SNAPSHOT"
```

The preferred path is in-memory; the `mktemp` form is a fallback documented for completeness.

## Caps and bail-outs (load-bearing safety rails)

These caps are NOT decorative — they exist to stop runaway loops on noisy reviewers and on diffs that the hardcore reviewer cannot wrangle to clean. The outer-round cap is enforced by the orchestrator, not this skill.

| Cap | Default | Meaning | What happens at cap |
|---|---|---|---|
| Inner hardcore-review iterations per round | `$INNER_ITERATION_CAP` (default `3`) | How many times the hardcore reviewer can re-run within a single round before giving up. **This is the only cap on edit iterations within a round.** Verification failures are NOT a separate retry budget — see "On verification failure" below. | Return `outcome: bail, bail_reason: inner-cap-tripped` with the latest hardcore report excerpt in `artifacts.latest_hardcore_report_excerpt` and the bail message "hardcore-reviewer could not reach 0 BLOCKING/IMPORTANT after N inner iterations — likely the change is wrong, not the reviewer" |
| Copilot poll cap (this round) | `$POLL_CAP_MINUTES` (default `60 minutes`), polling every `$POLL_INTERVAL_SECONDS` (default `60s`) | How long to wait for copilot to submit a fresh review after `--add-reviewer "$COPILOT_REVIEWER"` | Return `outcome: bail, bail_reason: poll-cap` with "copilot reviewer was silent past the 60-min cap; not pushing further". Do not push anything after the cap trips. |

Caps must be **enforced**, not just documented. Do not enter iteration 4 of the inner review — bail at the end of iteration 3 if findings remain.

**On verification failure:** any non-zero exit from step 3's verification command — mechanical (typo, missing import) or structural (real broken behavior) or a pre-commit hook failure — normally re-enters step 2 (the inner hardcore loop) to consume an inner-loop iteration budget so the hardcore reviewer re-vets the fix.

**Flake-detection retry (separate from inner-loop cap):** before re-entering step 2, run a single mechanical retry of the verification command **without** changing any files. If the second attempt also fails AND `git diff` shows no change since the first attempt (i.e. no edits between retries), treat as a flake-OR-real-failure and return `outcome: bail, bail_reason: verification-fail` with the message `[fix-pr-comments-loop] [round N/<cap>] [step 3] verification failed twice with no diff change — flake or real failure; manual investigation required` (a "verification-fail" bail, NOT an "inner-cap-tripped" bail — the two are reported distinctly so the user is not misrouted to the wrong artifact). The flake-retry budget is a hard cap of **2 attempts per step-3 entry** (one initial + one retry) and is independent of the inner-loop cap. Only after the diff has actually changed (i.e. the agent made an edit in step 2) does verification re-enter the inner-loop iteration budget. This replaces the previous mechanical-vs-structural distinction, which was vibes-based; the new test is purely diagnostic ("did the diff change between retries?").

> **Note on polling cost:** the per-round cap of `60 minutes` × `60s` interval = up to 60 `gh` API calls per round. The interval is a simple constant; future enhancement: exponential backoff. (60s balances rate-limit budget and user-perceived responsiveness; tighter polling burns rate limit, looser polling makes rounds feel sluggish.)
>
> **Rate-limit back-off (process-level, shared):** On `gh api` 403 / rate-limit errors during polling or any other GraphQL call in this round, retry with exponentially-spaced waits of `60s`, then `120s`, then `240s` (three retries total — totaling roughly 7 minutes of wall-clock waiting in the worst case). On the **fourth** rate-limit hit, **return `outcome: bail, bail_reason: rate-limit-exhausted`** with the raw `gh` error and a "GitHub API rate-limit exhausted; manual follow-up required" message — do NOT wait an additional 480s. This is a known failure mode on busy repos with many concurrent automated workflows. **Treat the back-off as process-level within the round**: when one `gh api` call (e.g. polling in step 7) hits the rate limit, ALL `gh api` callers in this round (step 0 prelude pagination, step 5 mapping-rule pagination, step 5 `resolveReviewThread` mutations, step 6 reviewer-state queries, step 7 polling) must respect the back-off window. Use a single shared back-off tracker (e.g. an in-memory deadline timestamp the agent threads through every `gh api` invocation) — do not let separate callers each independently incur the back-off.

### Complexity threshold bail-outs

Some fixes cross a complexity threshold where the user MUST be in the loop. When the next step would require any of the following, **return `outcome: bail, bail_reason: complexity-threshold`** instead of applying autonomously:

- Multi-file refactor (the fix touches more than `$COMPLEXITY_THRESHOLD` files unrelated to the original comment's file). The threshold check applies to the **union** `FIX_FILES ∪ INNER_FIX_FILES` evaluated **before staging in step 4** — so a small `pr-comment-fixer` change combined with a sprawling hardcore-loop refactor still trips the gate. Apply the same check at the END of each inner-loop iteration (step 2) so an iteration whose fix balloons the union past the threshold can bail before doing more work.
- Test removal or test-skip additions (`it.skip`, `xit`, `describe.skip`, deleting test cases, deleting whole test files).
- Public-API change (changing exported function signatures, package exports, REST/GraphQL schema, DB schema, or environment variables).
- Anything that would change behavior of a sibling endpoint/feature not mentioned in the original review thread.

These are the places where "address the comment" usually means a design discussion, not a mechanical fix. Return a `bail_detail` containing a one-paragraph summary of what the fix would entail and why it crossed the complexity threshold.

## The 9-step round

The order matters. Every round runs steps 0–8 (9 steps total — step 0 is the per-round prelude, steps 1 through 8 are the main round body) unless an earlier step returns a `bail` outcome. The outer-round cap (step 9 in the old design) lives in the orchestrator now — this skill always handles exactly one round.

### 0. Per-round prelude: count unresolved threads, return clean if zero

Before invoking `pr-comment-fixer:fix-issues`, query the unresolved-thread count. Use the same paginated pattern as step 5 (`reviewThreads(first:100, after:$cursor)` with `pageInfo`) and aggregate across pages so a PR with more than 100 threads is not under-counted.

`gh api`'s `-F` (typed) interpolation does NOT send GraphQL `null` — `-F cursor=null` sends the literal string `"null"` and breaks the cursor variable. Use **two distinct query strings**: one for page 1 (no `after:` argument, no `$cursor` variable in the query string at all), and one for subsequent pages (with the `$cursor` variable bound via `-f cursor="$ENDCURSOR"` — lowercase `-f`, string substitution).

**Page 1 (no cursor variable):**

```bash
gh api graphql -f query='
  query($owner:String!,$repo:String!,$pr:Int!) {
    repository(owner:$owner, name:$repo) {
      pullRequest(number:$pr) {
        reviewThreads(first:100) {
          pageInfo { hasNextPage endCursor }
          nodes { isResolved }
        }
      }
    }
  }' -F owner="$OWNER" -F repo="$REPO" -F pr="$PR_NUMBER" \
  --jq '{ unresolved: ([.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)] | length), hasNextPage: .data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage, endCursor: .data.repository.pullRequest.reviewThreads.pageInfo.endCursor }'
```

**Page N (N > 1, cursor variable bound as a string):**

```bash
gh api graphql -f query='
  query($owner:String!,$repo:String!,$pr:Int!,$cursor:String!) {
    repository(owner:$owner, name:$repo) {
      pullRequest(number:$pr) {
        reviewThreads(first:100, after:$cursor) {
          pageInfo { hasNextPage endCursor }
          nodes { isResolved }
        }
      }
    }
  }' -F owner="$OWNER" -F repo="$REPO" -F pr="$PR_NUMBER" -f cursor="$ENDCURSOR" \
  --jq '{ unresolved: ([.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)] | length), hasNextPage: .data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage, endCursor: .data.repository.pullRequest.reviewThreads.pageInfo.endCursor }'
```

Loop: start by running the page-1 query; while `hasNextPage` is `true`, set `ENDCURSOR=<endCursor>` and run the page-N query. Sum the per-page `unresolved` counts to get the round's total.

If the total is `0`, return `outcome: clean` immediately. The orchestrator decides what to print to the user (round 1 → "PR has no unresolved review comments — nothing to do"; rounds 2..N → the standard end-of-loop summary). This prevents wasting a full round on an empty PR.

### 1. Run `pr-comment-fixer:fix-issues`

Invoke the existing skill — do **not** re-fetch, re-parse, or re-fix manually. Pass the PR number from `$PR_NUMBER` (orchestrator-supplied) so the child skill knows which PR to target.

The child skill is responsible for: fetching unresolved review threads, reading the affected files, and applying surgical fixes. When the child skill returns, the working tree should contain its uncommitted edits.

`pr-comment-fixer:fix-issues` does **not** define a structured "files I edited" return value. Do not rely on it to enumerate edited files. Instead, derive `FIX_FILES` from the working tree directly:

1. **Before** invoking the child skill, snapshot the working tree state by running `git status --porcelain` and holding the result in-memory (TodoWrite or in-context). Skill state is in-memory by contract — do NOT write the snapshot to `/tmp/...` or any other on-disk path (racy across parallel runs and rarely cleaned up). If you must materialize it for a downstream tool, allocate a portable `mktemp "${TMPDIR:-/tmp}/fix-pr-comments-loop.XXXXXX"` path (positional template — BSD/macOS `mktemp -t prefix` differs from GNU `mktemp -t prefix.XXXXXX`, so avoid the `-t` form) and emit `trap 'rm -f "$SNAPSHOT"' EXIT` immediately to guarantee cleanup.
2. **After** the child skill returns, run `git status --porcelain` again and diff against the in-memory snapshot. Any path whose status entry differs (new, modified, deleted, or appearing-only-in-the-after-snapshot) is part of `FIX_FILES`.
3. Classify each path in `FIX_FILES` by porcelain code:
   - Added (` ?A` / `??` for untracked / `A ` for already-staged-add) and modified (` M`, `M `, `MM`) → stage with `git add -- "$path"` in step 4.
   - Deleted (` D`, `D `) → stage the deletion with `git add --update -- "$path"` (equivalent to `git rm --cached -- "$path"` for an already-tracked file).
   - Renamed (`R `) → treat both old and new path entries as part of `FIX_FILES`.
4. Use the resulting `FIX_FILES` list as **one input** to step 4 staging — it is **combined with** `INNER_FIX_FILES` (the files edited during the hardcore-review inner loop in step 2 of this round; see step 4 for the union staging rule).

Also record `THREADS_CLAIMED_ADDRESSED` — used for the commit-message `X` in step 4. `pr-comment-fixer` does not expose a structured "threads addressed" count, so derive it from the agent's own state rather than parsing child-skill output:

`THREADS_CLAIMED_ADDRESSED = (unresolved-thread count from the step-0 prelude on this round) − (a fresh post-step-1 unresolved-thread count, computed by re-running the same paginated query as step 0)`.

Equivalently: `count(threads where isResolved == false at the end of step 1) − count(threads where isResolved == false at start of step 0)` (negated). Both forms are computed directly from the GraphQL response. If the post-step-1 count is greater than or equal to the prelude count (no thread changed state — `pr-comment-fixer` may have only edited code without resolving anything), `THREADS_CLAIMED_ADDRESSED = 0`.

### 2. Inner loop: run `hardcore-code-reviewer:hardcore-code-reviewer` until clean

The scope passed to the hardcore reviewer is the **uncommitted working-tree diff produced by step 1 of THIS round**. Committed previous-round work is not re-reviewed; only the current round's not-yet-committed fixes are in scope.

Concretely, after step 1 completes, invoke the hardcore reviewer skill via the Skill tool. Tool-invocation example:

```text
Skill tool call: hardcore-code-reviewer:hardcore-code-reviewer
  args: scope = uncommitted-changes
        (i.e. the working-tree diff produced by step 1 of THIS round)
```

If the report has any `BLOCKING` or `IMPORTANT` findings, fix them in-place and re-run the reviewer. Repeat up to `$INNER_ITERATION_CAP` (default `3`). Record the list of files edited by these inner-loop fixes as `INNER_FIX_FILES` for use in step 4 staging.

- Iteration 1: review → fix BLOCKING/IMPORTANT → re-review.
- Iteration 2: same.
- Iteration 3 (final, when the cap is the default 3): same. If the report is still not clean after iteration `$INNER_ITERATION_CAP`, **return `outcome: bail, bail_reason: inner-cap-tripped`** (do not push). The cap exists because if hardcore-reviewer cannot reach 0 BLOCKING/IMPORTANT after that many passes, the underlying change is probably wrong — not the reviewer. Include the latest hardcore report excerpt in `artifacts.latest_hardcore_report_excerpt`.

After **every** iteration's fixes are applied, **re-evaluate the complexity-threshold gate against the union `FIX_FILES ∪ INNER_FIX_FILES`** (see "Complexity threshold bail-outs" above). If the union exceeds `$COMPLEXITY_THRESHOLD` (default `3` files unrelated to the original comment's file), or any other complexity-threshold rule is tripped, return `outcome: bail, bail_reason: complexity-threshold` immediately — do not enter another iteration, do not push.

`MINOR`-level findings do not block the loop — record them but do not iterate further on them.

A failed step 3 verification re-enters this step (step 2) and consumes another inner-loop iteration. Pre-commit hook failures during step 4 are treated the same way (re-enter step 2). The inner-iteration cap is the only cap on edit iterations within a round.

Track the count of BLOCKING+IMPORTANT findings on the **first** hardcore report of this round versus the **final** report — the difference is the `Y` value used in the round-summary commit message in step 4, and is also returned as `counts.findings_fixed` in the JSON result.

### 3. Run host-repo verification

Run `$VERIFY_CMD` (orchestrator-supplied — e.g. `npm run build && npm test && npm run lint`, `pytest && ruff check .`, `make test`, or an explicit `FIX_PR_COMMENTS_LOOP_VERIFY` override). Do **not** improvise a chain or hardcode a sequence — use the orchestrator-supplied string verbatim.

If verification exits non-zero, **do not push**. Apply the **flake-retry** rule first (see "On verification failure" in the Caps section) — one mechanical retry, no edits between attempts; if both fail with no diff change, return `outcome: bail, bail_reason: verification-fail` with the failing output tail in `artifacts.latest_verification_output_tail` (NOT "inner-cap-tripped"). Only after the diff has actually changed (i.e. the agent made an edit in step 2) does verification re-enter the inner-loop iteration budget. The flake-retry budget is small and separate (2 attempts per step-3 entry); the inner-iteration cap remains the only cap on edit iterations within a round.

Once step 2 declares the inner loop clean again, re-run step 3 from the top. If the inner-iteration cap trips before verification can pass, return `outcome: bail, bail_reason: inner-cap-tripped` with BOTH the latest hardcore report excerpt and the latest failing verification output in the artifacts.

A failed verification is a hard gate. The round must never push a commit that fails this sequence.

### 4. Commit and push (explicit-path staging only)

Stage **only the files actually edited by this round**. Do not use `git add -A` or `git add .` — those can sweep in `.env`, credentials, build artifacts, or harness scratch files (e.g. `PLAN.md`, `TASK.md`, `.harness-state.md`) that the user did not intend to push to a public PR.

The list of files to stage is the **union** of:

- `FIX_FILES` — the files edited by `pr-comment-fixer:fix-issues` in step 1 of this round.
- `INNER_FIX_FILES` — the files edited during the hardcore-review inner loop in step 2 of this round.

The complexity-threshold gate (see "Complexity threshold bail-outs") is evaluated against this union BEFORE any staging happens. If the union trips the gate, return `outcome: bail, bail_reason: complexity-threshold` — do not stage, do not commit, do not push.

Stage them by explicit path. For each entry in the union, classify by porcelain code (see step 1's classification step) and stage with the matching command:

```bash
# Added or modified file:
git add -- "$file1" "$file2"

# Deleted file (already-tracked path that's gone from the working tree):
git add --update -- "$file_deleted"

# One path per item, no globs. Variable substitution is unambiguous because each
# variable holds exactly one path string.
```

After staging, **gate** with `git status --short` and verify only the expected paths are staged. If anything unexpected appears (untracked secrets, unrelated edits), return `outcome: bail, bail_reason: staging-gate-failed` with the unexpected entries listed in `bail_detail` — do not push.

**Recovery when this gate fails.** The skill will NOT silently include or exclude unexpected entries. The user has three explicit options to make progress on the next run:

- (a) Add the unexpected entries to `.gitignore` and re-run, if they are local artifacts that should never be committed.
- (b) `git stash -u` them and re-run, if they are unrelated work-in-progress that the user wants to preserve but exclude from this PR.
- (c) `git rm --cached <path>` them (then commit that as a separate hygiene change) if they were accidentally tracked at some prior point and should leave the tree.

Pick exactly one. The skill does not have enough context to decide which is right.

> **Footnote on `git stash -u`:** `git stash -u` (`--include-untracked`) does NOT stash files that are already covered by `.gitignore`. If your unexpected files are harness scratch (e.g. `PLAN.md`, `TASK.md`, `.harness-state.md`) covered by the agent-harness `.gitignore` rules, they're already preserved on disk and excluded from commits — no stash needed. If unexpected files are NOT in `.gitignore`, `git stash -u` will stash them. To stash even ignored files, use `git stash --all` (use with caution — it removes ignored files from the working tree until popped).

Auto-generate the round commit message. The message is **deterministic**:

```text
Round N: address copilot feedback (X comments) + hardcore-review fixes (Y findings)
```

Where:

- `N` = `$ROUND` (orchestrator-supplied).
- `X` = `THREADS_CLAIMED_ADDRESSED` — the count of distinct review threads `pr-comment-fixer:fix-issues` reported as addressed in step 1 of THIS round. This is the value committed in the message; the authoritative resolution count from step 5 may differ slightly (the strict mapping rule may resolve fewer or, in rare cases, more) and is returned separately as `counts.threads_resolved` in the JSON result.
- `Y` = the count of `BLOCKING + IMPORTANT` findings the inner hardcore-review loop fixed this round, defined as `(BLOCKING+IMPORTANT count on iteration 1's first report) - (BLOCKING+IMPORTANT count on the final iteration's report)`. If the inner loop ran only 1 iteration (clean on first pass), `Y = 0`.

Commit and push. If the commit fails because of a pre-commit hook (`git commit` non-zero exit), treat the failure exactly like a step 3 verification failure: re-enter step 2's inner hardcore loop so the reviewer re-vets whatever the hook flagged, and re-attempt the commit after the inner loop is clean. Pre-commit hook failures consume an inner-loop iteration budget — there is no separate "commit retry" cap.

Before pushing, fetch + rebase to avoid a silent race with concurrent pushes (other automation, or the user pushing manually from another terminal). Capture the local SHA before rebase and assert it is unchanged afterwards — `git rebase` can reorder hunks if auto-resolution succeeds, which silently invalidates `PUSHED_SHA` and the step-5 mapping-rule diff:

```bash
git commit -m "<deterministic round summary computed above>"

LOCAL_SHA_BEFORE_REBASE=$(git rev-parse HEAD)

# Fetch + rebase to detect concurrent pushes BEFORE pushing.
BRANCH=$(git rev-parse --abbrev-ref HEAD)
git fetch origin "$BRANCH"
git rebase "origin/$BRANCH"
# If `git rebase` exits non-zero: return outcome: bail, bail_reason: concurrent-push
# with "concurrent push detected; manual resolution required". Do NOT
# `exit 1` from the shell, since SKILL.md runs inside the agent's bash
# session and `exit 1` would sever it. Do NOT auto-merge, do NOT --skip,
# do NOT --abort silently. The user must resolve the conflict and re-run.

LOCAL_SHA_AFTER_REBASE=$(git rev-parse HEAD)
# If $LOCAL_SHA_BEFORE_REBASE != $LOCAL_SHA_AFTER_REBASE: the rebase succeeded
# but rewrote the commit (auto-resolved hunks reordered). The mapping-rule
# diff in step 5 would be computed against a different commit than the one
# we authored — return outcome: bail, bail_reason: rebase-rewrote-commit
# with "rebase rewrote commit; manual resolution required".
# Same agent-control bail discipline as above (no shell exit).

git push origin HEAD
```

If the `rebase` step exits non-zero (real conflict between concurrent pushes), return `outcome: bail, bail_reason: concurrent-push` with a "concurrent push detected; manual resolution required" message and do not auto-merge, do not force-push, do not `--skip` rebase commits. If the rebase succeeded but the SHA changed (auto-resolved hunks were reordered), return `outcome: bail, bail_reason: rebase-rewrote-commit` — the mapping-rule diff in step 5 cannot be trusted to anchor on the originally-authored commit. The orchestrator will surface either bail to the user.

Capture the SHA of the just-pushed commit (`PUSHED_SHA`) and the timestamp of the push (`PUSH_TS`) — both are needed for step 5 (mapping rule) and step 7 (review-attached-to-commit filter). Return `PUSHED_SHA` in the JSON result regardless of outcome (the orchestrator surfaces it on bail too).

### 5. Resolve addressed GitHub review threads

For each unresolved review thread that was addressed by code changes in the just-pushed commit, resolve it via the GraphQL `resolveReviewThread` mutation.

**Compute the mapping-rule diff first.** `git diff $PUSHED_SHA^..$PUSHED_SHA` fails on the first commit on a branch (no parent) and is also wrong for a multi-commit branch where you only want this round's diff against the merge base. Compute the diff against the PR's merge base instead:

```bash
MERGE_BASE=$(git merge-base "origin/$BASE_BRANCH" HEAD)
# Files this round changed (relative to the PR's merge base):
git diff --name-only "$MERGE_BASE..$PUSHED_SHA"
# Per-file diff with line numbers (consumed below for the line-window match):
git diff "$MERGE_BASE..$PUSHED_SHA"
```

`BASE_BRANCH` was provided by the orchestrator. If `MERGE_BASE` cannot be computed (e.g. the local clone is missing the base branch ref), return `outcome: bail, bail_reason: merge-base-unresolved` with "could not derive merge base; ensure `origin/$BASE_BRANCH` is fetched".

Next, fetch the unresolved threads with the metadata needed to apply the strict mapping rule below. **Paginate** the `reviewThreads` connection — `first:100` silently caps a noisy PR — by looping until `pageInfo.hasNextPage` is false. As with step 0, use TWO query strings (one for page 1, one for page N>1) because `gh api`'s `-F cursor=null` does NOT send GraphQL `null` (it sends the literal string `"null"`). The mapping rule only consults `path` / `line` / `originalLine` / `startLine` / `originalStartLine`, so the queries do not request comment bodies — keep payloads small.

**Page 1 (no cursor variable, no `after:` argument):**

```bash
gh api graphql -f query='
  query($owner:String!,$repo:String!,$pr:Int!) {
    repository(owner:$owner, name:$repo) {
      pullRequest(number:$pr) {
        reviewThreads(first:100) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id
            isResolved
            path
            line
            originalLine
            startLine
            originalStartLine
          }
        }
      }
    }
  }' -F owner="$OWNER" -F repo="$REPO" -F pr="$PR_NUMBER"
```

**Page N (N > 1, cursor variable bound as a string with lowercase `-f`):**

```bash
gh api graphql -f query='
  query($owner:String!,$repo:String!,$pr:Int!,$cursor:String!) {
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
          }
        }
      }
    }
  }' -F owner="$OWNER" -F repo="$REPO" -F pr="$PR_NUMBER" -f cursor="$ENDCURSOR"
```

Drive a loop in the executing agent: start by running the page-1 query and accumulate its `nodes`; while `hasNextPage` is `true`, set `ENDCURSOR=<endCursor>` and run the page-N query, accumulating its `nodes`. As a safety check, if a single page returns `length(nodes) >= 100` and pagination has not yet been implemented end-to-end (e.g. dry-run mode), emit a one-line warning to the user that the page cap was hit so a missed thread is visible rather than silent.

**Strict mapping rule** (replaces vibes-based "the change must plausibly answer the comment"):

A thread is eligible for resolution iff **all** of the following hold:

1. The thread's `path` appears in `git diff --name-only "$MERGE_BASE..$PUSHED_SHA"` (i.e. the just-pushed commit modified that file relative to the merge base).
2. The just-pushed commit's diff modifies at least one line in `$thread.path` within the range `[ ((.startLine // .line) - W), (.line + W) ]` (i.e. within ±W lines of the comment's **current-coordinate** anchor on the latest commit). The expression `(.startLine // .line)` is jq syntax (alternative-operator: use `.startLine` if non-null, else `.line`); it is NOT shell arithmetic and not JS nullish coalescing — quote it inside a `jq --arg` invocation, not a shell expression.

   The window `W = $RESOLVE_WINDOW` (default `20`, lines on each side). Tradeoff: a tight window (e.g. `5`) misses real refactors that move code around; a loose window (e.g. `50`) increases the chance of false-positive resolutions where the just-pushed commit happened to edit nearby code without addressing the thread. `20` is a reasonable default for typical refactor-shaped fixes; tighten for highly localized comment patterns; loosen for diffs with significant whitespace/formatting churn.

   **Coordinate space.** `git diff` produces line numbers in current (post-edit) coordinate space. GitHub's `line` / `startLine` fields on a `PullRequestReviewThread` are also in current coordinate space — anchored to the latest commit on the PR. The `originalLine` / `originalStartLine` fields are anchored to the commit the review was originally posted against (pre-edit space). Comparing a current-coordinate diff against pre-edit anchors is wrong and drifts after every push.

   Use `line` / `startLine` for the comparison. Fall back to `originalLine` / `originalStartLine` ONLY when `line` is null (which can happen when GitHub has not yet recomputed the anchor — rare but possible immediately after a push). The fallback is best-effort; if both are null, leave the thread unresolved.

Threads that do not satisfy both conditions stay unresolved. **On uncertainty, leave unresolved** and let copilot decide on re-review.

For each thread that **does** pass the mapping rule, resolve it:

```bash
gh api graphql -f query='
  mutation($threadId:ID!) {
    resolveReviewThread(input:{threadId:$threadId}) {
      thread { id isResolved }
    }
  }' -F threadId="$THREAD_ID"
```

Record the count of threads resolved this round — this is the authoritative `counts.threads_resolved` for the JSON result (recompute and prepare it for the round status report; the commit-message `X` was a forward estimate from step 1 and is acceptable to be slightly off in either direction).

### 6. Re-request copilot review

`gh pr edit --add-reviewer` rejects `@`-prefixed handles ("not found"). Always pass the **bare login** supplied as `$COPILOT_REVIEWER` (orchestrator-resolved; default `copilot-pull-request-reviewer`, overridable via `FIX_PR_COMMENTS_LOOP_REVIEWER`).

Before adding the reviewer, query the existing reviewer requests to avoid relying on locale/version-dependent stderr strings to detect idempotency. `gh`'s `--jq` passthrough does NOT accept `--arg`; fetch the raw JSON and pipe through a separate `jq --arg` invocation:

```bash
ALREADY_REQUESTED=$(gh pr view "$PR_NUMBER" --json reviewRequests \
  | jq --arg login "$COPILOT_REVIEWER" \
       '[.reviewRequests[]
          # Skip Team entries — a Team named like the bot would otherwise
          # false-positive the already-requested check.
          | select((.__typename // "") != "Team")
          | (.login // .name // .slug) | ascii_downcase]
        | any(. == ($login | ascii_downcase))')

if [ "$ALREADY_REQUESTED" = "true" ]; then
  # Already in the request list — no edit needed; continue to step 7.
  :
else
  gh pr edit "$PR_NUMBER" --add-reviewer "$COPILOT_REVIEWER"
fi
```

This re-triggers a fresh copilot review against the just-pushed HEAD.

**Error-handling rule:** if `gh pr edit` exits non-zero, **log the stderr verbatim and return `outcome: bail, bail_reason: gh-pr-edit-failed`** with the stderr in `bail_detail` — do not interpret error messages, do not maintain an allowlist of "benign" or "fatal" phrases (locale and `gh` version drift make string-matching unreliable). The pre-check above already handles the "already requested" case structurally; any non-zero exit from the actual `gh pr edit` call is treated as a real failure.

### 7. Poll for new copilot activity (commit-anchored, not timestamp-anchored)

Poll the PR every `$POLL_INTERVAL_SECONDS` (default `60s`) for a copilot review **attached to the commit pushed in step 4** (`$PUSHED_SHA`), not just any review submitted after `$PUSH_TS`. Cap polling at `$POLL_CAP_MINUTES` (default `60 minutes`) for this round.

**Bot login filter (case-insensitive substring match):** the copilot bot's `login` is not a fixed string. Bot logins observed in the wild include `copilot-pull-request-reviewer`, `github-copilot[bot]`, and `copilot[bot]`; some have `copilot` at the start of the login, others have it embedded as a substring. A `startswith("copilot")` filter would miss `github-copilot[bot]`. The bot filter therefore requires BOTH:

- `author.__typename == "Bot"` (rejects user accounts with copilot in their handle, such as `copilotAdvocate`).
- `(author.login | ascii_downcase | contains("copilot"))` (case-insensitive substring match, accepts `github-copilot[bot]`, `copilot-pull-request-reviewer`, `copilot[bot]`, etc.).

Both conditions are required — `__typename == "Bot"` AND `contains("copilot")`. Document any deviation if a future GitHub change changes the bot typename.

**`COPILOT_LOGIN` (received from orchestrator, may be empty on round 1):** the orchestrator threads `COPILOT_LOGIN` through every round. On round 1 with no prior copilot review, it is the empty string `""`. While `COPILOT_LOGIN` is empty, the polling filter relies entirely on the `__typename == "Bot"` AND `contains("copilot")` filter (the equality clause `author.login == $login` is dead-weight when `$login` is empty and is intentionally OR'd with the bot filter so polling still works). Once this round observes a copilot review whose author satisfies the combined filter, capture its login and return it in the JSON result as `copilot_login` — the orchestrator persists it and threads it through to later rounds.

**Polling query — fetch raw JSON, then filter via `jq --arg`:** to avoid the fragility of shell-interpolating `$COPILOT_LOGIN` and `$PUSHED_SHA` inside a single quoted `--jq` expression (escape-character drift, login values that contain shell metacharacters, etc.), fetch the raw GraphQL response **without** `--jq`, then pipe through a separate `jq --arg login "$COPILOT_LOGIN" --arg sha "$PUSHED_SHA" '<filter>'` invocation:

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
            comments { totalCount }
          }
        }
      }
    }
  }' -F owner="$OWNER" -F repo="$REPO" -F pr="$PR_NUMBER" \
| jq --arg login "$COPILOT_LOGIN" \
     --arg sha "$PUSHED_SHA" \
     --arg pushTs "$PUSH_TS" \
  '
    # A review is the "current round''s copilot review" iff:
    #   (1) author is the copilot bot (__typename Bot AND login contains "copilot",
    #       OR login matches the previously-captured $login when non-empty); AND
    #   (2) submittedAt > $pushTs AND EITHER commit.oid equals $sha
    #       OR commit.oid is null/missing.
    .data.repository.pullRequest.reviews.nodes
    | map(select(
        (
          (.author.__typename == "Bot" and (.author.login | ascii_downcase | contains("copilot")))
          or (.author.login == $login and $login != "")
        )
        and (.submittedAt > $pushTs)
        and (
          ((.commit.oid // "") == $sha)
          or (.commit.oid == null or .commit.oid == "")
        )
      ))
    | sort_by(.submittedAt) | last
  '
```

`comments(first:0)` is a GraphQL error (minimum is `1`). Use `comments { totalCount }` as above when you only need the count (no `first:` argument required).

The shell-inline-interpolation form (`--jq "..."` with `\"$VAR\"` escapes) is intentionally removed from this skill — too fragile in practice; use the raw-fetch + `jq --arg` form above.

**Constraint on `reviews(last:50)`:** the `last:50` cap is hardcoded above. On extremely busy PRs that accumulate more than 50 reviews per polling window (rare in practice), this can silently under-fetch a fresh copilot review. If you hit that case, paginate the `reviews` connection using the same two-query-string pattern (`reviews(first:N, after:$cursor)`) as step 0 / step 5.

**Why the dual criterion (`commit.oid == $sha` OR `commit.oid == null`, both gated by `submittedAt > $pushTs`):** the OID filter is the primary signal — it precisely identifies a review attached to the just-pushed commit. The null-OID case is a fallback for review types where GitHub does not populate `commit.oid` for bots. We accept these false positives (extremely rare in practice — a delayed previous-round bot review with null `commit.oid` is almost never seen, and the `submittedAt > $pushTs` gate rejects most of them anyway) in exchange for **never falsely failing to terminate the loop**. An earlier "tightened" form of this filter rejected null-OID reviews on rounds 2+ and silently broke the multi-round case — that rejection is intentionally removed. Documented trade-off: very rare false-positive termination is preferable to a guaranteed silent failure to terminate.

A round is complete when a copilot review for the just-pushed `$PUSHED_SHA` is observed (the filter above returns a non-null result). If the `$POLL_CAP_MINUTES` cap trips before that happens, return `outcome: bail, bail_reason: poll-cap` with: "copilot reviewer was silent past the 60-min cap on round N; manual follow-up required" and include the latest copilot review URL (if any) in `artifacts.latest_copilot_review_url`. Do not push anything else in that case.

### 8. Decide: clean, continue, or already-bailed

Inspect the new copilot review fetched in step 7. To count "new comments", count unresolved review threads anchored to `$PUSHED_SHA` (or, equivalently, count comments on the just-fetched review) — not all unresolved threads on the PR (some may have been intentionally left unresolved by step 5's strict mapping rule and would otherwise spin the loop forever).

- If the latest copilot review on `$PUSHED_SHA` submitted with **zero new unresolved comments**, return `outcome: clean`. The orchestrator handles the final summary.
- If it submitted with new comments, return `outcome: continue` with `counts.new_copilot_comments` set to the count. The orchestrator increments the round counter and dispatches the next round (subject to the outer-round cap, which the orchestrator enforces).

This skill never decides whether to spawn another round — that is the orchestrator's exclusive responsibility. Return the round outcome and let the orchestrator decide.

## Status reporting

On every transition between steps, log a one-line status update to the subagent's stdout so it appears in the dump the Agent tool relays back to the orchestrator at round end. **Every status line is prefixed with the structured tag `[fix-pr-comments-loop] [round N/<cap>] [step K] <message>`** — that format is grep-friendly and lets a downstream tool (or the user reading the orchestrator's per-round dump) parse the round transcript without ambiguity. `N` is the orchestrator-supplied `$ROUND`, `<cap>` is the orchestrator-supplied `$OUTER_CAP` (do not hardcode the literal "8"), and `K` is the step number (`0` through `8`).

Example status lines:

- `[fix-pr-comments-loop] [round N/<cap>] [step 0] 12 unresolved threads → continuing`
- `[fix-pr-comments-loop] [round N/<cap>] [step 1] invoking pr-comment-fixer:fix-issues for PR #1234`
- `[fix-pr-comments-loop] [round N/<cap>] [step 2] hardcore review iteration 1/3 — 3 BLOCKING, 5 IMPORTANT`
- `[fix-pr-comments-loop] [round N/<cap>] [step 3] <resolved verification command> → PASS`
- `[fix-pr-comments-loop] [round N/<cap>] [step 4] pushed commit abc1234`
- `[fix-pr-comments-loop] [round N/<cap>] [step 5] resolved 4/5 review threads (1 left for copilot judgment)`
- `[fix-pr-comments-loop] [round N/<cap>] [step 6] re-requested copilot reviewer (login=$COPILOT_REVIEWER)`
- `[fix-pr-comments-loop] [round N/<cap>] [step 7] polling every 60s, cap 60m`
- `[fix-pr-comments-loop] [round N/<cap>] [step 8] copilot returned 2 new comments on $PUSHED_SHA → continue`

Because the Agent tool buffers subagent output until the round completes, these lines reach the user as a single block when the round returns — not as a live stream. The orchestrator separately emits its own per-round summary line; the bracketed-tag prefix lets `grep '\[step 5\]'` isolate every round's resolution-step output across all rounds even when the orchestrator's stdout is `tee`'d to a log file.

## Return value contract

Before terminating (whether on `clean`, `continue`, or any `bail` outcome), the subagent MUST emit a single fenced ```` ```json ```` block as the LAST thing in its output. The orchestrator parses by extracting the last ` ```json ... ``` ` block in the relayed transcript. Schema:

```json
{
  "round": 3,
  "outcome": "clean | continue | bail",
  "bail_reason": "inner-cap-tripped | verification-fail | poll-cap | complexity-threshold | rate-limit-exhausted | concurrent-push | rebase-rewrote-commit | gh-pr-edit-failed | staging-gate-failed | merge-base-unresolved | null",
  "bail_detail": "<one-line message to surface to user, or null on non-bail outcomes>",
  "pushed_sha": "<sha of the commit pushed in step 4, or null if no push happened>",
  "copilot_login": "<bot login captured during step 7, or empty string if no copilot review was observed in this round>",
  "counts": {
    "threads_addressed": 4,
    "findings_fixed": 2,
    "threads_resolved": 4,
    "new_copilot_comments": 1
  },
  "artifacts": {
    "latest_hardcore_report_excerpt": "<string or null>",
    "latest_verification_output_tail": "<string or null>",
    "latest_copilot_review_url": "<string or null>"
  }
}
```

Rules:

- `outcome: clean` → set `bail_reason: null` and `bail_detail: null`. `counts.new_copilot_comments` MUST be `0`.
- `outcome: continue` → set `bail_reason: null` and `bail_detail: null`. `counts.new_copilot_comments` MUST be `> 0`.
- `outcome: bail` → set `bail_reason` to one of the documented identifiers above and `bail_detail` to a one-line user-facing message. `counts.new_copilot_comments` is `0` if step 7/8 was not reached.
- `copilot_login` is the empty string `""` whenever no copilot review was observed in this round (typical for poll-cap bails on round 1 with no prior login captured).
- `artifacts.*` fields are best-effort and may be `null` if the corresponding step never produced an artifact. Truncate each to roughly 2000 characters to keep the orchestrator's context bounded.

If the subagent crashes or otherwise fails to emit this block, the orchestrator bails to the user with the raw subagent output AND two recovery-hint commands (`git log --oneline -5` and `gh pr view --json statusCheckRollup,reviewRequests`) so the user can quickly tell whether the failed round partially pushed.

## What this skill is NOT

- Not a code reviewer. It calls `hardcore-code-reviewer:hardcore-code-reviewer`.
- Not a per-comment fixer. It calls `pr-comment-fixer:fix-issues`.
- Not a multi-round driver. It runs exactly one round. The `fix-pr-comments-loop` orchestrator drives multiple rounds.
- Not a way to bypass the host-repo verification sequence — `$VERIFY_CMD` is supplied by the orchestrator and is mandatory.
- Not a way to mass-resolve review threads — the mapping rule for `resolveReviewThread` is strict on purpose.

## Out of scope

- Outer-loop cap enforcement (orchestrator).
- Cross-round state persistence beyond what the JSON result carries back (orchestrator).
- Fail-fast / clean-tree validation at run start (orchestrator).
- Verification command discovery (orchestrator).
- Triggering reviewers other than the orchestrator-supplied `$COPILOT_REVIEWER`.

## Verification (static checks an implementer can run without a live PR)

There is no automated unit-test harness for this skill yet — the orchestration runs against live GitHub APIs. As a partial substitute, the implementer can run these **static** checks against the SKILL.md content to catch common breakage:

- **GraphQL query strings parse:** copy each `gh api graphql -f query='...'` block out of SKILL.md and pipe through a GraphQL parser (e.g. `graphql-js`'s `parse()` or `gh api graphql --dry-run` if a future `gh` version supports it). The six query strings to validate are: step 0 page-1 prelude, step 0 page-N prelude, step 5 page-1 reviewThreads, step 5 page-N reviewThreads, step 5 `resolveReviewThread` mutation, and step 7 polling. None should reference `comments(first:0)` (GraphQL minimum is `1`); none should reference `-F cursor=null` (sends literal string `"null"`); page-1 queries must omit the `$cursor` variable entirely.
- **jq filter syntax:** copy each `--jq '...'` and `jq --arg ... '...'` filter out of SKILL.md and pipe through `jq -n '<filter>'` against an empty input — syntax errors will surface immediately. The polling filter (step 7) and reviewer-existence check (step 6) are the most likely to drift.
- **gh field-name correctness:** every `gh pr view --json <fields>` invocation should be cross-checked against `gh pr view --help` for valid field names. Common drifts: `reviewRequests.login` vs `reviewRequests.name` vs `reviewRequests.slug` (use `(.login // .name // .slug)`).
- **No hardcoded verification chains:** `grep -E '(yarn|pnpm|npm) (build|test|lint|run) (&&|build|test|lint)' SKILL.md` should match only inside the example list (not as an instruction to run a literal chain). The actual command is `$VERIFY_CMD`, supplied by the orchestrator.
- **No `@`-prefixed reviewer handles in invocations:** `grep '\-\-add-reviewer @' SKILL.md` should produce no matches in command examples (only in the explanatory note that says "never `@copilot`"). The reviewer is `$COPILOT_REVIEWER`.
- **No orphan step-9 references:** `grep -E '\[step 9\]|step 9|Step 9' SKILL.md` should produce no matches — step 9 (outer-cap enforcement) lives in the orchestrator skill.
- **JSON return-value contract block:** `grep '"outcome"' SKILL.md` should match at least once (the schema documentation block).
