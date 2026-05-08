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

- `gh` CLI version `>= 2.88` (needed for `gh pr edit --add-reviewer "$COPILOT_REVIEWER"` — the bare bot login, not `@copilot`; see "Reviewer login (configurable)" below).
- An open PR for the current branch on GitHub.
- The two child skills installed and triggerable: `pr-comment-fixer:fix-issues` and `hardcore-code-reviewer:hardcore-code-reviewer`.
- A clean working tree at the start of every round (the loop will refuse to run with uncommitted changes outside of what it just produced).

## Fail-fast: no open PR

Before doing anything else, confirm there is an open PR for the current branch, then capture the **current repo's** owner/name (NOT the PR's `baseRepository`) and the PR number. `gh pr view --json` does NOT accept a `baseRepository` field — valid base-repository fields are limited to `baseRefName` / `baseRefOid`. Derive owner and repo from the current repo instead.

Run these two commands:

```bash
# Confirm an open PR exists for the current branch and capture its number.
gh pr view --json number,state,headRefName,url

# Capture OWNER/REPO from the current repo (the branch's repo).
gh repo view --json owner,name -q '.owner.login + " " + .name'
```

Parse and stash the three values for the rest of the loop:

- `OWNER` — first whitespace-separated token from the `gh repo view` output (e.g. `stilero`).
- `REPO`  — second whitespace-separated token from the `gh repo view` output (e.g. `claude-plugins`).
- `PR_NUMBER` — `gh pr view --json number,state,headRefName,url --jq '.number'`.

Also assert the PR is open: `gh pr view --json state --jq '.state'` must equal `OPEN`.

In addition, capture the PR's base branch for the mapping-rule diff in step 5:

```bash
BASE_BRANCH=$(gh pr view --json baseRefName --jq '.baseRefName')
```

Use the stashed `OWNER` / `REPO` / `PR_NUMBER` in every `gh api graphql -F owner=$OWNER -F repo=$REPO -F pr=$PR_NUMBER ...` call below — do not re-derive them per step. Quote `$PR_NUMBER` in `gh pr edit "$PR_NUMBER"` and similar invocations to keep the variable substitution unambiguous.

If the `gh pr view` command fails or returns `state != "OPEN"`, **abort immediately** with a message like:

> No open PR found for the current branch (`<branch>`). This skill only operates on open PRs — push the branch and open a PR first, then re-run.

Do not attempt any of the rest of the loop. This is a hard precondition.

After confirming the open PR, **also** verify the working tree is clean:

```bash
test -z "$(git status --short)" || { echo "working tree not clean — commit, stash, or discard before running"; exit 1; }
```

This avoids mixing pre-existing local edits into a round's `FIX_FILES` snapshot diff.

### Limitations: fork PRs

This skill assumes the head and base of the PR are in the same repo. For fork PRs, the just-pushed SHA may not be visible to the upstream API immediately after `git push`; if you need fork-PR support, add a `gh api repos/$OWNER/$REPO/commits/$PUSHED_SHA` poll-for-existence (with a short timeout, e.g. 60s) between steps 4 and 5 before relying on the SHA in upstream GraphQL queries.

### Cross-round state

Skills are stateless across invocations. The executing agent must track `OWNER`, `REPO`, `PR_NUMBER`, `BASE_BRANCH`, `COPILOT_LOGIN`, and the round counter across rounds in TodoWrite or in-memory for the duration of the run. These do not persist across sessions; if the run is interrupted, the next session re-derives them by re-running the fail-fast step above and re-discovering the bot login from the next polled review (see step 7 — initialize `COPILOT_LOGIN=""` on round 1 if no prior copilot review exists).

Per-round derived state (`PUSHED_SHA`, `PUSH_TS`, `MERGE_BASE`, `FIX_FILES`, `INNER_FIX_FILES`, `THREADS_CLAIMED_ADDRESSED`) is also tracked in-memory by the agent — including the snapshot of `git status --porcelain` taken before invoking `pr-comment-fixer:fix-issues` in step 1. Do **not** write the snapshot or any other per-round scratch state to a file under `/tmp/...` (racy across parallel runs and rarely cleaned up). Hold it in TodoWrite or in-context for the round.

If you must materialize the snapshot to disk for a downstream tool (rare), use a `mktemp`-allocated path with an `EXIT` cleanup trap:

```bash
SNAPSHOT=$(mktemp -t fix-pr-comments-loop.XXXXXX)
trap 'rm -f "$SNAPSHOT"' EXIT
git status --porcelain > "$SNAPSHOT"
```

The preferred path is in-memory; the `mktemp` form is a fallback documented for completeness.

### Reviewer login (configurable)

The default GitHub Copilot reviewer login on most repos is `copilot-pull-request-reviewer` (the app slug; sometimes surfaced as `github-copilot[bot]`). If your repo's copilot reviewer has a different login (visible in `gh pr view --json reviewRequests`), set the environment variable `FIX_PR_COMMENTS_LOOP_REVIEWER=<login>` and use that value as the reviewer handle in step 6.

`gh pr edit --add-reviewer` rejects `@`-prefixed handles ("not found"). Always pass the **bare login** — never `@copilot`.

Stash the resolved reviewer handle once at the start of the run:

```bash
COPILOT_REVIEWER="${FIX_PR_COMMENTS_LOOP_REVIEWER:-copilot-pull-request-reviewer}"
```

Use `$COPILOT_REVIEWER` for every `gh pr edit "$PR_NUMBER" --add-reviewer "$COPILOT_REVIEWER"` call below.

## Verification command discovery (configurable per host repo)

This skill must run the host repo's verification sequence before pushing. The verification command is **not hardcoded**. Discover it in this priority order at the start of each run, and reuse the resolved command for every round:

1. **Explicit override (highest priority):** environment variable `FIX_PR_COMMENTS_LOOP_VERIFY` is set → use its value verbatim as the verification command.
2. **Skill argument:** if the caller passed a `verify=<command>` argument, use it.
3. **Project CLAUDE.md:** read the host repo's `CLAUDE.md` (root) and search for an explicit verification sequence. **Heading priority** (deterministic order — first match wins):
   1. A heading whose text matches `Verification` (case-insensitive).
   2. Otherwise, a heading whose text matches `Tests` (case-insensitive).
   3. Otherwise, a heading whose text matches `Build` (case-insensitive).

   Once a heading is matched at the highest available priority, take the **first fenced code block** immediately under it as the verification command. This rule is deterministic across CLAUDE.md files that have multiple matching headings (e.g. both a `## Verification` and a `## Tests` section). Document any deviation in the host repo's `CLAUDE.md` if a different priority is desired.

4. **Auto-detect from package manifest:** compose the verification command from intersected scripts and configured tools — never from a hardcoded chain.
   - `package.json` present with `yarn.lock` (and only `yarn.lock`) → `yarn` invocation built from the intersection of (scripts in `package.json`) and `[build, test, lint]` (see "Script intersection" below).
   - `package.json` present with `pnpm-lock.yaml` (and no other JS lockfile) → equivalent `pnpm` form, same script-intersection logic.
   - `package.json` present with `package-lock.json` (and no other JS lockfile) → equivalent `npm run` form, same script-intersection logic.
   - `pyproject.toml` with `[tool.pytest.ini_options]` or `pytest.ini` → `pytest`. Also append `&& ruff check .` if any of: `pyproject.toml` contains a `[tool.ruff]` section, OR `.ruff.toml` exists in repo root, OR `ruff.toml` exists in repo root.
   - `Makefile` with a `test` target → `make test`.
   - No manifest detectable → fall through to step 5.

   **Script intersection (Node.js auto-detect):** Before composing the chain, run `jq -r '.scripts | keys[]' package.json` (or use the Read tool to read `package.json` and parse the `scripts` object) and intersect the keys with `[build, test, lint]`. Compose the chain from **only the subcommands present in that intersection**, in that order — for example, if the intersection is `{build, test}` (no `lint` script), the resolved command is `<package_manager> build && <package_manager> test`, NOT a hardcoded `<package_manager> build && <package_manager> test && <package_manager> lint`. If the intersection is empty, fall through to step 5 (no-op fallback) — do not invoke `yarn`/`pnpm`/`npm` with no subcommands.

   **Lockfile tie-breaker:** If multiple JS lockfiles are present in the same repo (e.g. both `yarn.lock` and `package-lock.json`), check `package.json` for a `packageManager` field (or `engines.packageManager`). If that field declares `yarn@...`, prefer yarn; if `pnpm@...`, prefer pnpm; if `npm@...`, prefer npm. If neither field is present and multiple lockfiles still match, fall through to step 5 (no-op fallback) with a one-line warning describing which lockfiles were detected and that no `packageManager` declaration could disambiguate them. Do not guess.
5. **No-op fallback:** if none of the above resolves a command, set verification to a no-op (`true`) and **emit a one-line warning** in the round status: `[fix-pr-comments-loop] [round N/<outer_cap>] [step 3] no verification command discovered — skipping (set FIX_PR_COMMENTS_LOOP_VERIFY to enforce one)`.

The resolved command is the value used by step 3 below. **Do not hardcode any specific verification chain anywhere in this skill** — the priority above is the contract.

If the host repo's `CLAUDE.md` explicitly says "no build system, no tests" (markdown-only repos, etc.), the discovery step naturally falls through to the no-op fallback in step 5 — that is the documented behavior, not a bug.

## Caps and bail-outs (load-bearing safety rails)

These caps are NOT decorative — they exist to stop runaway loops on noisy reviewers and on diffs that the hardcore reviewer cannot wrangle to clean.

| Cap | Default | Meaning | What happens at cap |
|---|---|---|---|
| Inner hardcore-review iterations per round | `3` | How many times the hardcore reviewer can re-run within a single round before giving up. **This is the only cap on edit iterations within a round.** Verification failures are NOT a separate retry budget — see "On verification failure" below. | Bail to user with the latest hardcore report and the message "hardcore-reviewer could not reach 0 BLOCKING/IMPORTANT after N inner iterations — likely the change is wrong, not the reviewer" |
| Outer loop rounds | `8` | How many full fetch→fix→review→push→re-request cycles to run before giving up | Bail to user with a status summary listing per-round counts of comments addressed, hardcore findings, and copilot re-review responses |
| Copilot poll cap (per round) | `60 minutes`, polling every `60s` | How long to wait for copilot to submit a fresh review after `--add-reviewer "$COPILOT_REVIEWER"` | Bail to user with "copilot reviewer was silent past the 60-min cap; not pushing further". Do not push anything after the cap trips. |

Caps must be **enforced**, not just documented. Do not enter iteration 4 of the inner review — bail at the end of iteration 3 if findings remain. Do not enter round 9 of the outer loop — bail at the end of round 8 if the reviewer is still finding new issues.

**On verification failure:** any non-zero exit from step 3's verification command — mechanical (typo, missing import) or structural (real broken behavior) or a pre-commit hook failure — re-enters step 2 (the inner hardcore loop). This consumes an inner-loop iteration budget rather than a separate verification-retry budget. The mechanical-vs-structural distinction was previously vibes-based and removed; the inner-iteration cap is the only cap on edit iterations within a round, and the hardcore reviewer re-vets every fix before another verification attempt. There is no longer a "verification-retries cap".

> **Note on polling cost:** the per-round cap of `60 minutes` × `60s` interval = up to 60 `gh` API calls per round, ≤ 480 across all 8 rounds in worst case. The interval is a simple constant; future enhancement: exponential backoff. (60s balances rate-limit budget and user-perceived responsiveness; tighter polling burns rate limit, looser polling makes rounds feel sluggish.)
>
> **Rate-limit back-off (process-level, shared):** On `gh api` 403 / rate-limit errors during polling or any other GraphQL call in this loop, exponentially back off (60s → 120s → 240s → bail at 480s) and retry. After the final back-off, bail to the user with the raw `gh` error and a "GitHub API rate-limit exhausted; manual follow-up required" message. This is a known failure mode on busy repos with many concurrent automated workflows. **Treat the back-off as process-level**: when one `gh api` call (e.g. polling in step 7) hits the rate limit, ALL `gh api` callers in the orchestrator (step 0 prelude pagination, step 5 mapping-rule pagination, step 5 `resolveReviewThread` mutations, step 6 reviewer-state queries, step 7 polling, step 8 follow-up review fetches) must respect the back-off window. Use a single shared back-off tracker (e.g. an in-memory deadline timestamp the agent threads through every `gh api` invocation) — do not let separate callers each independently incur the back-off.

### Complexity threshold bail-outs

Some fixes cross a complexity threshold where the user MUST be in the loop. When the next step would require any of the following, **stop and ask the user** instead of applying autonomously:

- Multi-file refactor (the fix touches more than `3` files unrelated to the original comment's file). The threshold check applies to the **union** `FIX_FILES ∪ INNER_FIX_FILES` evaluated **before staging in step 4** — so a small `pr-comment-fixer` change combined with a sprawling hardcore-loop refactor still trips the gate. Apply the same check at the END of each inner-loop iteration (step 2) so an iteration whose fix balloons the union past the threshold can bail before doing more work.
- Test removal or test-skip additions (`it.skip`, `xit`, `describe.skip`, deleting test cases, deleting whole test files).
- Public-API change (changing exported function signatures, package exports, REST/GraphQL schema, DB schema, or environment variables).
- Anything that would change behavior of a sibling endpoint/feature not mentioned in the original review thread.

These are the places where "address the comment" usually means a design discussion, not a mechanical fix. Hand control back to the user with a one-paragraph summary of what the fix would entail and why it crossed the complexity threshold.

## The 10-step loop

The order matters. Every round runs steps 0–9 (10 steps total — step 0 is the per-round prelude, steps 1 through 9 are the main loop body) unless an earlier step bails out.

### 0. Per-round prelude: count unresolved threads, bail if zero

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

If the total is `0`:

- On round 1: exit cleanly with "PR has no unresolved review comments — nothing to do".
- On rounds 2..N: exit cleanly with the standard end-of-loop summary (this is the success terminator on subsequent rounds, equivalent to copilot returning zero new comments).

This prevents wasting a full round on an empty PR.

### 1. Run `pr-comment-fixer:fix-issues`

Invoke the existing skill — do **not** re-fetch, re-parse, or re-fix manually. Pass the PR number (the stashed `$PR_NUMBER` from the fail-fast step) so the child skill knows which PR to target.

The child skill is responsible for: fetching unresolved review threads, reading the affected files, and applying surgical fixes. When the child skill returns, the working tree should contain its uncommitted edits.

`pr-comment-fixer:fix-issues` does **not** define a structured "files I edited" return value. Do not rely on it to enumerate edited files. Instead, derive `FIX_FILES` from the working tree directly:

1. **Before** invoking the child skill, snapshot the working tree state by running `git status --porcelain` and holding the result in-memory (TodoWrite or in-context). Skill state is in-memory by contract — do NOT write the snapshot to `/tmp/...` or any other on-disk path (racy across parallel runs and rarely cleaned up). If you must materialize it for a downstream tool, allocate a `mktemp -t fix-pr-comments-loop.XXXXXX` path and emit `trap 'rm -f "$SNAPSHOT"' EXIT` immediately to guarantee cleanup.
2. **After** the child skill returns, run `git status --porcelain` again and diff against the in-memory snapshot. Any path whose status entry differs (new, modified, deleted, or appearing-only-in-the-after-snapshot) is part of `FIX_FILES`.
3. Classify each path in `FIX_FILES` by porcelain code:
   - Added (` ?A` / `??` for untracked / `A ` for already-staged-add) and modified (` M`, `M `, `MM`) → stage with `git add -- "$path"` in step 4.
   - Deleted (` D`, `D `) → stage the deletion with `git add --update -- "$path"` (equivalent to `git rm --cached -- "$path"` for an already-tracked file).
   - Renamed (`R `) → treat both old and new path entries as part of `FIX_FILES`.
4. Use the resulting `FIX_FILES` list as **one input** to step 4 staging — it is **combined with** `INNER_FIX_FILES` (the files edited during the hardcore-review inner loop in step 2 of this round; see step 4 for the union staging rule).

Also separately record the count of distinct review threads `pr-comment-fixer` reported as addressed in this round (call this `THREADS_CLAIMED_ADDRESSED`) — used for the commit-message `X` in step 4.

### 2. Inner loop: run `hardcore-code-reviewer:hardcore-code-reviewer` until clean

On every round (round 1 and rounds 2..N alike), the scope passed to the hardcore reviewer is the **uncommitted working-tree diff produced by step 1 of THIS round**. There is no per-round variation — committed previous-round work is not re-reviewed; only the current round's not-yet-committed fixes are in scope.

Concretely, on each round, after step 1 completes, invoke the hardcore reviewer skill via the Skill tool. Tool-invocation example:

```text
Skill tool call: hardcore-code-reviewer:hardcore-code-reviewer
  args: scope = uncommitted-changes
        (i.e. the working-tree diff produced by step 1 of THIS round)
```

If the report has any `BLOCKING` or `IMPORTANT` findings, fix them in-place and re-run the reviewer. Repeat up to the inner-iteration cap (default `3`). Record the list of files edited by these inner-loop fixes as `INNER_FIX_FILES` for use in step 4 staging.

- Iteration 1: review → fix BLOCKING/IMPORTANT → re-review.
- Iteration 2: same.
- Iteration 3 (final): same. If the report is still not clean after iteration 3, **bail to the user** (do not push). The cap exists because if hardcore-reviewer cannot reach 0 BLOCKING/IMPORTANT after 3 passes, the underlying change is probably wrong — not the reviewer. Hand control back with the latest report.

After **every** iteration's fixes are applied, **re-evaluate the complexity-threshold gate against the union `FIX_FILES ∪ INNER_FIX_FILES`** (see "Complexity threshold bail-outs" above). If the union exceeds the threshold (default `3` files unrelated to the original comment's file, configurable via `FIX_PR_COMMENTS_LOOP_COMPLEXITY_THRESHOLD`), or any other complexity-threshold rule is tripped, bail to the user immediately — do not enter another iteration, do not push.

`MINOR`-level findings do not block the loop — record them but do not iterate further on them.

A failed step 3 verification re-enters this step (step 2) and consumes another inner-loop iteration. Pre-commit hook failures during step 4 are treated the same way (re-enter step 2). The inner-iteration cap is the only cap on edit iterations within a round.

Track the count of BLOCKING+IMPORTANT findings on the **first** hardcore report of this round versus the **final** report — the difference is the `Y` value used in the round-summary commit message in step 4.

### 3. Run host-repo verification

Run the verification command resolved by the discovery rules in the "Verification command discovery" section above. Concretely, this is the **resolved verification command** for the host repo — for example, `<package_manager> $(<intersection of [build, test, lint] with package.json scripts>)` for an auto-detected Node.js repo, or `pytest && ruff check .` for an auto-detected Python repo (only when `ruff` is configured per the discovery rules), or the `$FIX_PR_COMMENTS_LOOP_VERIFY` value for an explicit override, or `true` for the no-op fallback (with the documented warning logged). Do **not** copy a hardcoded chain into this step — the actual command is whatever the discovery section resolved.

If verification exits non-zero, **do not push**. The skill no longer distinguishes mechanical from structural failures (that distinction was vibes-based); on any non-zero exit, **re-enter step 2** (the inner hardcore loop) so the hardcore reviewer re-vets the fix. This consumes an inner-loop iteration budget rather than a separate verification-retry budget. There is no verification-retries cap.

Once step 2 declares the inner loop clean again, re-run step 3 from the top. If the inner-iteration cap trips before verification can pass, bail to the user with the latest hardcore report AND the latest failing verification output.

A failed verification is a hard gate. The skill must never push a commit that fails this sequence.

### 4. Commit and push (explicit-path staging only)

Stage **only the files actually edited by this round**. Do not use `git add -A` or `git add .` — those can sweep in `.env`, credentials, build artifacts, or harness scratch files (e.g. `PLAN.md`, `TASK.md`, `.harness-state.md`) that the user did not intend to push to a public PR.

The list of files to stage is the **union** of:

- `FIX_FILES` — the files edited by `pr-comment-fixer:fix-issues` in step 1 of this round.
- `INNER_FIX_FILES` — the files edited during the hardcore-review inner loop in step 2 of this round.

The complexity-threshold gate (see "Complexity threshold bail-outs") is evaluated against this union BEFORE any staging happens. If the union trips the gate, bail to the user — do not stage, do not commit, do not push.

Stage them by explicit path. For each entry in the union, classify by porcelain code (see step 1's classification step) and stage with the matching command:

```bash
# Added or modified file:
git add -- "$file1" "$file2"

# Deleted file (already-tracked path that's gone from the working tree):
git add --update -- "$file_deleted"

# One path per item, no globs. Variable substitution is unambiguous because each
# variable holds exactly one path string.
```

After staging, **gate** with `git status --short` and verify only the expected paths are staged. If anything unexpected appears (untracked secrets, unrelated edits), **bail to the user** with the unexpected entries listed — do not push.

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

- `N` = the current round number (1-based).
- `X` = `THREADS_CLAIMED_ADDRESSED` — the count of distinct review threads `pr-comment-fixer:fix-issues` reported as addressed in step 1 of THIS round. This is the value committed in the message; the authoritative resolution count from step 5 may differ slightly (the strict mapping rule may resolve fewer or, in rare cases, more) and is reported separately in the round status output, not in the commit subject.
- `Y` = the count of `BLOCKING + IMPORTANT` findings the inner hardcore-review loop fixed this round, defined as `(BLOCKING+IMPORTANT count on iteration 1's first report) - (BLOCKING+IMPORTANT count on the final iteration's report)`. If the inner loop ran only 1 iteration (clean on first pass), `Y = 0`.

Commit and push. If the commit fails because of a pre-commit hook (`git commit` non-zero exit), treat the failure exactly like a step 3 verification failure: re-enter step 2's inner hardcore loop so the reviewer re-vets whatever the hook flagged, and re-attempt the commit after the inner loop is clean. Pre-commit hook failures consume an inner-loop iteration budget — there is no separate "commit retry" cap.

Before pushing, fetch + rebase to avoid a silent race with concurrent pushes (other automation, or the user pushing manually from another terminal). Capture the local SHA before rebase and assert it is unchanged afterwards — `git rebase` can reorder hunks if auto-resolution succeeds, which silently invalidates `PUSHED_SHA` and the step-5 mapping-rule diff:

```bash
git commit -m "<deterministic round summary computed above>"

LOCAL_SHA_BEFORE_REBASE=$(git rev-parse HEAD)

# Fetch + rebase to detect concurrent pushes BEFORE pushing.
BRANCH=$(git rev-parse --abbrev-ref HEAD)
git fetch origin "$BRANCH"
git rebase "origin/$BRANCH" || {
  echo "concurrent push detected; manual resolution required"
  # Bail: do NOT auto-merge, do NOT --skip, do NOT --abort silently.
  # The user must resolve the conflict, re-run the loop afterwards.
  exit 1
}

LOCAL_SHA_AFTER_REBASE=$(git rev-parse HEAD)
if [ "$LOCAL_SHA_BEFORE_REBASE" != "$LOCAL_SHA_AFTER_REBASE" ]; then
  # Rebase succeeded but rewrote the commit (auto-resolved hunks reordered).
  # The mapping-rule diff in step 5 would be computed against a different
  # commit than the one we authored — bail rather than silently mis-resolve.
  echo "rebase rewrote commit; manual resolution required"
  exit 1
fi

git push origin HEAD
```

If the `rebase` step exits non-zero (real conflict between concurrent pushes), bail to the user with a "concurrent push detected; manual resolution required" message and do not auto-merge, do not force-push, do not `--skip` rebase commits. If the rebase succeeded but the SHA changed (auto-resolved hunks were reordered), bail with "rebase rewrote commit; manual resolution required" — the mapping-rule diff in step 5 cannot be trusted to anchor on the originally-authored commit. Hand control back so the user can resolve manually before re-running the loop.

Capture the SHA of the just-pushed commit (`PUSHED_SHA`) and the timestamp of the push (`PUSH_TS`) — both are needed for step 5 (mapping rule) and step 7 (review-attached-to-commit filter).

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

`BASE_BRANCH` was captured during the fail-fast step (`gh pr view --json baseRefName --jq '.baseRefName'`). If `MERGE_BASE` cannot be computed (e.g. the local clone is missing the base branch ref), bail with "could not derive merge base; ensure `origin/$BASE_BRANCH` is fetched".

Next, fetch the unresolved threads with the metadata needed to apply the strict mapping rule below. **Paginate** the `reviewThreads` connection — `first:100` silently caps a noisy PR — by looping until `pageInfo.hasNextPage` is false. As with step 0, use TWO query strings (one for page 1, one for page N>1) because `gh api`'s `-F cursor=null` does NOT send GraphQL `null` (it sends the literal string `"null"`). `comments(first:0)` is a GraphQL error (minimum is `1`); use `comments(first:1) { nodes { body } }` if you need the comment body, or `comments { totalCount }` if you only need the count.

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
            comments(first:1) { nodes { body } }
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
            comments(first:1) { nodes { body } }
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

   The default window `W = 20` (lines on each side). Configure via the environment variable `FIX_PR_COMMENTS_LOOP_RESOLVE_WINDOW=<integer>` to widen or narrow it. Tradeoff: a tight window (e.g. `5`) misses real refactors that move code around; a loose window (e.g. `50`) increases the chance of false-positive resolutions where the just-pushed commit happened to edit nearby code without addressing the thread. `20` is a reasonable default for typical refactor-shaped fixes; tighten for highly localized comment patterns; loosen for diffs with significant whitespace/formatting churn.

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

Record the count of threads resolved this round — this is the authoritative `X` for the round summary (recompute and prepare it for the round status report; the commit-message `X` was a forward estimate from step 1 and is acceptable to be slightly off in either direction).

### 6. Re-request copilot review

`gh pr edit --add-reviewer` rejects `@`-prefixed handles ("not found"). Always pass the **bare login** stashed as `$COPILOT_REVIEWER` (default `copilot-pull-request-reviewer`, overridable via `FIX_PR_COMMENTS_LOOP_REVIEWER`).

Before adding the reviewer, query the existing reviewer requests to avoid relying on locale/version-dependent stderr strings to detect idempotency. `gh`'s `--jq` passthrough does NOT accept `--arg`; fetch the raw JSON and pipe through a separate `jq --arg` invocation:

```bash
ALREADY_REQUESTED=$(gh pr view "$PR_NUMBER" --json reviewRequests \
  | jq --arg login "$COPILOT_REVIEWER" \
       '[.reviewRequests[] | (.login // .name // .slug) | ascii_downcase]
        | any(. == ($login | ascii_downcase))')

if [ "$ALREADY_REQUESTED" = "true" ]; then
  # Already in the request list — no edit needed; continue to step 7.
  :
else
  gh pr edit "$PR_NUMBER" --add-reviewer "$COPILOT_REVIEWER"
fi
```

This re-triggers a fresh copilot review against the just-pushed HEAD.

**Error-handling rule:** if `gh pr edit` exits non-zero, **log the stderr verbatim and bail to the user** — do not interpret error messages, do not maintain an allowlist of "benign" or "fatal" phrases (locale and `gh` version drift make string-matching unreliable). The pre-check above already handles the "already requested" case structurally; any non-zero exit from the actual `gh pr edit` call is treated as a real failure.

### 7. Poll for new copilot activity (commit-anchored, not timestamp-anchored)

Poll the PR every `60s` for a copilot review **attached to the commit pushed in step 4** (`$PUSHED_SHA`), not just any review submitted after `$PUSH_TS`. Cap polling at `60 minutes` per round.

**Bot login filter (case-insensitive substring match):** the copilot bot's `login` is not a fixed string. Bot logins observed in the wild include `copilot-pull-request-reviewer`, `github-copilot[bot]`, and `copilot[bot]`; some have `copilot` at the start of the login, others have it embedded as a substring. A `startswith("copilot")` filter would miss `github-copilot[bot]`. The bot filter therefore requires BOTH:

- `author.__typename == "Bot"` (rejects user accounts with copilot in their handle, such as `copilotAdvocate`).
- `(author.login | ascii_downcase | contains("copilot"))` (case-insensitive substring match, accepts `github-copilot[bot]`, `copilot-pull-request-reviewer`, `copilot[bot]`, etc.).

Both conditions are required — `__typename == "Bot"` AND `contains("copilot")`. Document any deviation if a future GitHub change changes the bot typename.

**`COPILOT_LOGIN` capture (do once, reuse across rounds):** on round 1, query the existing reviews and capture the login of the first review whose author satisfies the combined filter. Stash this as `COPILOT_LOGIN`. Reuse it on subsequent rounds. If round 1 has no prior copilot review, **explicitly initialize `COPILOT_LOGIN=""`** before entering the polling loop. While `COPILOT_LOGIN` is empty, the polling filter relies entirely on the `__typename == "Bot"` AND `contains("copilot")` filter (the equality clause `author.login == $login` is dead-weight when `$login` is empty and is intentionally OR'd with the bot filter so polling still works). Once the first copilot review is observed in any round, capture its login into `COPILOT_LOGIN` and reuse on later rounds.

**Same-round commit set:** before entering the polling loop, capture the list of all SHAs pushed during this loop's lifetime so far (one per completed round). Call this `KNOWN_PUSHED_SHAS`; serialize it as a JSON array in the shell variable `KNOWN_PUSHED_SHAS_JSON` for the `jq --argjson` invocation below. The current round's `$PUSHED_SHA` is the **last** entry. Use `KNOWN_PUSHED_SHAS` to reject "delayed previous-round" reviews that would otherwise sneak through a permissive timestamp filter — see the polling pseudocode below.

```bash
# Example: append the round's pushed SHA to the array as part of step 4 cleanup.
# Hold KNOWN_PUSHED_SHAS in-memory across rounds (TodoWrite or in-context).
KNOWN_PUSHED_SHAS_JSON=$(printf '%s\n' "${KNOWN_PUSHED_SHAS[@]}" | jq -R . | jq -s .)
```

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
     --argjson knownShas "$KNOWN_PUSHED_SHAS_JSON" \
  '
    # $knownShas is the JSON array of SHAs pushed during this loop run (incl. $sha).
    # A review is the "current round''s copilot review" iff:
    #   (1) author is the copilot bot (__typename Bot AND login contains "copilot",
    #       OR login matches the previously-captured $login when non-empty); AND
    #   (2) EITHER commit.oid equals $sha
    #       OR commit.oid is null/missing AND submittedAt > $pushTs AND no other
    #          known-pushed SHA appears in the response window (defense in depth).
    .data.repository.pullRequest.reviews.nodes
    | map(select(
        (
          (.author.__typename == "Bot" and (.author.login | ascii_downcase | contains("copilot")))
          or (.author.login == $login and $login != "")
        )
        and (
          # Primary: review is anchored to exactly $sha.
          ((.commit.oid // "") == $sha)
          or
          # Fallback: bot reviews where commit.oid is null/missing.
          # Accept ONLY if no other known-pushed SHA could be the anchor —
          # i.e. $knownShas contains only $sha. This rejects "delayed
          # previous-round review (different non-null commit.oid, later
          # submittedAt)" which previously falsely terminated the loop.
          (
            (.commit.oid == null or .commit.oid == "")
            and (.submittedAt > $pushTs)
            and ($knownShas | map(. != $sha) | any | not)
          )
        )
      ))
    | sort_by(.submittedAt) | last
  '
```

`comments(first:0)` is a GraphQL error (minimum is `1`). Use `comments { totalCount }` as above when you only need the count (no `first:` argument required).

The shell-inline-interpolation form (`--jq "..."` with `\"$VAR\"` escapes) is intentionally removed from this skill — too fragile in practice; use the raw-fetch + `jq --arg` form above.

**Why the dual criterion (`commit.oid == $sha` OR (`commit.oid == null AND submittedAt > $pushTs`)):** the OID filter is the primary signal — it precisely identifies a review attached to the just-pushed commit. The timestamp half is a fallback for review types where GitHub does not populate `commit.oid` for bots; in that case, the review's submission time after `$pushTs` plus the bot-author filter is the next-best evidence. The previous round-2 implementation OR'd the two halves loosely, which let a delayed previous-round review (different non-null `commit.oid`, later `submittedAt`) match — falsely terminating the loop. The fix above tightens the OR: a review with a populated, non-matching `commit.oid` is **rejected**, even if its `submittedAt` is after `$pushTs`. Only a review whose `commit.oid` is null AND whose timestamp is fresh AND that does not collide with another known-pushed SHA can pass the fallback path.

A round is complete when a copilot review for the just-pushed `$PUSHED_SHA` is observed (the filter above returns a non-null result). If the 60-min cap trips before that happens, bail to the user with: "copilot reviewer was silent past the 60-min cap on round N; manual follow-up required". Do not push anything else in that case.

### 8. Decide: continue, exit clean, or bail

Inspect the new copilot review fetched in step 7. To count "new comments", count unresolved review threads anchored to `$PUSHED_SHA` (or, equivalently, count comments on the just-fetched review) — not all unresolved threads on the PR (some may have been intentionally left unresolved by step 5's strict mapping rule and would otherwise spin the loop forever).

- If the latest copilot review on `$PUSHED_SHA` submitted with **zero new unresolved comments**, exit clean. Print a final summary: rounds run, total comments addressed across rounds, total hardcore findings fixed, total threads resolved, final PR URL.
- If it submitted with new comments, increment the round counter and goto **step 0** (the prelude).

### 9. Cap total rounds

If incrementing the round counter in step 8 would exceed the outer-round cap (default `8`), do not loop again. Bail to the user with a status summary describing why the cap tripped (most often: the reviewer keeps finding new issues round after round, which is a signal that the diff is too ambitious for an autonomous loop and needs human steering).

## Status reporting

On every transition between steps, log a one-line status update so the user can follow along. **Every status line is prefixed with the structured tag `[fix-pr-comments-loop] [round N/<cap>] [step K] <message>`** — that format is grep-friendly and lets a downstream tool (or the user piping stdout to a file) parse runs without ambiguity. The `<cap>` placeholder is the configured outer cap (default 8) — **do not hardcode the literal "8"** so that operators changing the cap see consistent output. `K` is the step number (`0` through `9`).

Example status lines:

- `[fix-pr-comments-loop] [round N/<cap>] [step 0] 12 unresolved threads → continuing`
- `[fix-pr-comments-loop] [round N/<cap>] [step 1] invoking pr-comment-fixer:fix-issues for PR #1234`
- `[fix-pr-comments-loop] [round N/<cap>] [step 2] hardcore review iteration 1/3 — 3 BLOCKING, 5 IMPORTANT`
- `[fix-pr-comments-loop] [round N/<cap>] [step 3] <resolved verification command> → PASS`
- `[fix-pr-comments-loop] [round N/<cap>] [step 4] pushed commit abc1234`
- `[fix-pr-comments-loop] [round N/<cap>] [step 5] resolved 4/5 review threads (1 left for copilot judgment)`
- `[fix-pr-comments-loop] [round N/<cap>] [step 6] re-requested copilot reviewer (login=$COPILOT_REVIEWER)`
- `[fix-pr-comments-loop] [round N/<cap>] [step 7] polling every 60s, cap 60m`
- `[fix-pr-comments-loop] [round N/<cap>] [step 8] copilot returned 2 new comments on $PUSHED_SHA → looping`

Suggested usage: pipe stdout to a file (`<command> 2>&1 | tee fix-pr-comments-loop.log`) for grep-friendly transcripts later. The bracketed-tag prefix lets you `grep '\[step 5\]'` to isolate every round's resolution-step output, etc.

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

## Verification (static checks an implementer can run without a live PR)

There is no automated unit-test harness for this skill yet — the orchestration runs against live GitHub APIs. As a partial substitute, the implementer can run these **static** checks against the SKILL.md content to catch common breakage:

- **GraphQL query strings parse:** copy each `gh api graphql -f query='...'` block out of SKILL.md and pipe through a GraphQL parser (e.g. `graphql-js`'s `parse()` or `gh api graphql --dry-run` if a future `gh` version supports it). The five query strings to validate are: step 0 page-1 prelude, step 0 page-N prelude, step 5 page-1 reviewThreads, step 5 page-N reviewThreads, step 5 `resolveReviewThread` mutation, and step 7 polling. None should reference `comments(first:0)` (GraphQL minimum is `1`); none should reference `-F cursor=null` (sends literal string `"null"`); page-1 queries must omit the `$cursor` variable entirely.
- **jq filter syntax:** copy each `--jq '...'` and `jq --arg ... '...'` filter out of SKILL.md and pipe through `jq -n '<filter>'` against an empty input — syntax errors will surface immediately. The polling filter (step 7) and reviewer-existence check (step 6) are the most likely to drift.
- **gh field-name correctness:** every `gh pr view --json <fields>` and `gh repo view --json <fields>` invocation should be cross-checked against `gh pr view --help` / `gh repo view --help` for valid field names. Common drifts: `baseRepository` (NOT a `gh pr view` field), `reviewRequests.login` vs `reviewRequests.name` vs `reviewRequests.slug` (use `(.login // .name // .slug)`).
- **No hardcoded verification chains:** `grep -E '(yarn|pnpm|npm) (build|test|lint|run) (&&|build|test|lint)' SKILL.md` should match only inside the auto-detect explanation (not as an instruction to run a literal chain). Auto-detect must compose from the script intersection rule, not a fixed string.
- **No `@`-prefixed reviewer handles in invocations:** `grep '\-\-add-reviewer @' SKILL.md` should produce no matches in command examples (only in the explanatory note that says "never `@copilot`"). The reviewer is `$COPILOT_REVIEWER` (default `copilot-pull-request-reviewer`).

Future work (documented in README): factor pagination, mapping-rule line-window matching, and the polling filter into a small unit-testable script (e.g. `bin/fix-pr-comments-loop-helpers.sh` with mocked `gh api` outputs) so the loop's risky parts can be exercised without a live PR.
