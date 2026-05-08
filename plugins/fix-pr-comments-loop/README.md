# Fix PR Comments Loop

Autonomous loop that drives a pull request to a clean review state. Fetches unresolved review threads, fixes them via the `pr-comment-fixer` skill, hardens the resulting diff via the `hardcore-code-reviewer` skill, runs the project verification sequence, pushes, resolves the addressed threads, re-requests copilot review, polls for the next round, and repeats until the PR is review-clean or hard caps trip.

## Features

- **Fetch unresolved threads**: Reads open `reviewThreads` for the current PR via `gh api graphql`.
- **Fix step**: Delegates to the existing `pr-comment-fixer:fix-issues` skill — does not re-implement comment fixing.
- **Inner hardening loop**: Delegates to `hardcore-code-reviewer:hardcore-code-reviewer` and iterates fixes until the report is clean (capped, default 3 inner iterations).
- **Verification gating**: Resolves the host repo's verification command (env override → skill arg → `CLAUDE.md` declaration → auto-detected from `package.json`/`pyproject.toml`/`Makefile` → no-op fallback with a warning) and runs it before every push; failure blocks the push.
- **Thread resolution**: Resolves only the threads that were actually addressed by code in the just-pushed commit, via the `resolveReviewThread` GraphQL mutation.
- **Re-request copilot**: Calls `gh pr edit --add-reviewer @copilot` to trigger the next round of review.
- **Bounded polling**: Polls every 60s for new copilot activity, with a per-round timeout (default 60 minutes).
- **Hard caps**: Outer loop is capped (default 8 rounds); on cap exhaustion the skill bails to the user with a status summary instead of pushing more.
- **Complexity bail-outs**: Escalates to the user instead of auto-applying when a fix would require multi-file refactors, test removal, or a public-API change.
- **Fast fail**: Errors out clearly when no open PR exists for the current branch.

## Skills

This plugin contains the following skill:

- **fix-pr-comments-loop**: The autonomous loop that orchestrates fix → review → verify → push → resolve → re-request review → poll until clean.

## Prerequisites

- **GitHub CLI (`gh`) ≥ 2.88**, authenticated against the repo. Required for `gh pr view`, `gh api graphql` (used for the `reviewThreads` query and `resolveReviewThread` mutation), and `gh pr edit --add-reviewer @copilot`.
- **An open PR for the current branch.** The skill fails fast if there is none.
- **The `pr-comment-fixer` plugin installed.** The loop delegates the fix step to its `fix-issues` skill rather than re-implementing comment-fixing logic.
- **The `hardcore-code-reviewer` plugin installed.** The loop delegates the inner hardening step to its `hardcore-code-reviewer` skill.

## Trigger phrases

The skill is designed to activate on phrases like:

- "fix-pr-comments loop"
- "address all PR comments and re-request review until clean"
- "autonomous PR fix loop"
- "drive PR to clean review"

You can also invoke it explicitly via the companion slash command `/fix-pr-comments-loop` (optional PR number argument).

## Usage

Once your PR has copilot review comments, run the slash command `/fix-pr-comments-loop` (or ask the agent to "drive this PR to a clean review"). The loop will fetch unresolved threads, dispatch the fix step to `pr-comment-fixer`, harden the diff with `hardcore-code-reviewer`, run the host repo's resolved verification command (see "Verification command" below), push, resolve only the threads it actually addressed, re-request `@copilot` review via `gh pr edit --add-reviewer @copilot`, and poll every 60s for the next round — repeating until the PR is review-clean or the configured caps (3 inner hardcore iterations, 2 verification retries per round, 8 outer loop rounds, 60-minute per-round poll) trip and it bails to you with a status summary.

## Verification command

The skill does **not** hardcode a verification command. It resolves one at runtime in this priority order:

1. Environment variable `FIX_PR_COMMENTS_LOOP_VERIFY` (highest priority).
2. A `verify=<command>` argument passed to the skill.
3. A verification sequence declared in the host repo's `CLAUDE.md` (under headings like "Verification", "Tests", or "Build").
4. Auto-detected from the host repo's package manifest (`package.json` + lockfile → `yarn`/`pnpm`/`npm` script chain; `pyproject.toml` → `pytest` + `ruff`; `Makefile` `test` target → `make test`).
5. No-op fallback: if none of the above resolves a command (e.g. a markdown-only repo), the skill skips verification with a one-line warning. To enforce a verification step in such a repo, set `FIX_PR_COMMENTS_LOOP_VERIFY` to the desired command.

## Manual smoke test

This is a reproducible recipe for verifying the `fix-pr-comments-loop` skill end-to-end against a throwaway PR. Run it any time you change the skill's behavior, or before you trust the loop on a real PR.

### (a) Set up a deliberately-buggy PR

1. Create a throwaway branch off `main`: `git checkout -b smoke/fix-pr-comments-loop`.
2. Commit a small diff that contains **at least two distinct defects** — one that copilot will flag, and one that `hardcore-code-reviewer` will flag. A reliable combination:
   - **Missing await** on an async call (copilot reliably flags this; e.g. `const user = fetchUser(id);` where `fetchUser` returns a Promise and the next line uses `user.name`).
   - **Hardcoded secret** as a string literal (e.g. `const API_KEY = "FAKE_PLACEHOLDER_REPLACE_ME";`). `hardcore-code-reviewer`'s security subagent will flag this as BLOCKING. Use an obviously-fake placeholder so GitHub's secret scanner does not trip on the demo PR.
   - Optional third defect for extra signal: an **unhandled error** path (a `JSON.parse(input)` with no `try`/`catch` inside a request handler). The `error-handling` and `silent-failure-hunter` reviewers will flag it.
3. Push the branch and open a PR: `gh pr create --fill --draft`.
4. Add `@copilot` as a reviewer so it produces an initial review: `gh pr edit --add-reviewer @copilot` and wait for copilot to leave at least one review comment on the diff (usually 1–3 minutes).

### (b) Invoke the skill

From the PR's branch checkout, invoke the loop. Either of these is sufficient:

- Slash command: `/fix-pr-comments-loop`
- Natural-language phrase: ask the agent to **"drive this PR to a clean review"** (or any of the documented trigger phrases such as `address all PR comments and re-request review until clean`).

### (c) Expected observable signals at each loop stage

Watch for each of the following — all of them must be visible in the agent's tool-call/output stream for the run to count as a pass:

1. **Fix step runs and touches files.** The agent invokes the `pr-comment-fixer` skill (`pr-comment-fixer:fix-issues`); you should see it report which files it edited in response to the unresolved review threads.
2. **Inner hardening loop reaches a clean report.** The agent invokes `hardcore-code-reviewer` and iterates until the final report shows **0 BLOCKING and 0 IMPORTANT** findings (the `BLOCKING` count must reach zero before the loop is allowed to push). Capped at 3 inner iterations per outer round.
3. **Verification command exits 0.** Before pushing, the agent runs the host repo's **resolved** verification command (see "Verification command" above — env override, then `CLAUDE.md`, then auto-detect, then no-op fallback). The combined exit code must be `0`. A non-zero exit blocks the push. If the no-op fallback applies (markdown-only repo), the agent must log the `no verification command discovered` warning instead of pretending verification ran.
4. **Push lands.** `git push` completes successfully and the new commit SHA appears on the PR.
5. **Threads resolved via `resolveReviewThread`.** The agent issues `gh api graphql` calls invoking the `resolveReviewThread` mutation, **only for threads that were actually addressed by the just-pushed commit** (other threads stay unresolved).
6. **Copilot re-requested.** `gh pr edit --add-reviewer @copilot` succeeds (no error from `gh`) and the PR's reviewer list shows `@copilot` re-requested.
7. **Copilot re-review returns with zero new comments.** After the agent polls (every 60s, up to 60 minutes), copilot's next review submission has **zero new comments** (equivalently: no new unresolved threads). This is the success terminator for the outer loop.
8. **Skill exits with a clean status.** The agent prints a final status summary indicating success — no caps tripped, all threads resolved, copilot returned with no new comments.

### (d) Pass / fail criteria

**PASS:** All eight signals above are observed within the configured caps (≤ 3 inner hardcore iterations per round, ≤ 8 outer rounds, ≤ 60 minutes of copilot polling per round). The PR ends with: every original unresolved thread either resolved or explicitly escalated to the user; `hardcore-code-reviewer` final report at 0 BLOCKING / 0 IMPORTANT; verification command green on the pushed commit; copilot re-review submitted with zero new comments (or `no new comments`).

**FAIL:** Any of the following:

- The fix step does not invoke `pr-comment-fixer` (the loop is reimplementing comment-fixing inline).
- `hardcore-code-reviewer` final report still has `BLOCKING` or `IMPORTANT` findings when the loop pushes.
- The loop pushes without the resolved verification command having exited 0 (or, in the documented no-op fallback case, without having logged the warning that verification was skipped).
- A review thread is resolved that was **not** addressed by the just-pushed commit (false-positive resolution — this is a hard fail even if everything else looks green).
- `gh pr edit --add-reviewer @copilot` is not invoked, or invoked with the wrong reviewer.
- An outer or inner cap trips and the agent silently retries instead of bailing to the user with a status summary.
- Copilot returns a non-empty re-review and the loop exits as if clean.

If any FAIL signal is observed, the smoke test fails and the skill must be fixed before the loop is used on a real PR.
