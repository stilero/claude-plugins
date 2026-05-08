# Fix PR Comments Loop

Autonomous loop that drives a pull request to a clean review state. Fetches unresolved review threads, fixes them via the `pr-comment-fixer` skill, hardens the resulting diff via the `hardcore-code-reviewer` skill, runs the project verification sequence, pushes, resolves the addressed threads, re-requests copilot review, polls for the next round, and repeats until the PR is review-clean or hard caps trip.

## Features

- **Fetch unresolved threads**: Reads open `reviewThreads` for the current PR via `gh api graphql`.
- **Fix step**: Delegates to the existing `pr-comment-fixer:fix-issues` skill — does not re-implement comment fixing.
- **Inner hardening loop**: Delegates to `hardcore-code-reviewer:hardcore-code-reviewer` and iterates fixes until the report is clean (capped, default 3 inner iterations).
- **Verification gating**: Runs the project's `yarn build && yarn test:unit && yarn test:integration && yarn lint` sequence before every push; failure blocks the push.
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

Once your PR has copilot review comments, run the slash command `/fix-pr-comments-loop` (or ask the agent to "drive this PR to a clean review"). The loop will fetch unresolved threads, dispatch the fix step to `pr-comment-fixer`, harden the diff with `hardcore-code-reviewer`, run `yarn build && yarn test:unit && yarn test:integration && yarn lint`, push, resolve only the threads it actually addressed, re-request `@copilot` review via `gh pr edit --add-reviewer @copilot`, and poll every 60s for the next round — repeating until the PR is review-clean or the configured caps (3 inner hardcore iterations, 8 outer loop rounds, 60-minute per-round poll) trip and it bails to you with a status summary.
