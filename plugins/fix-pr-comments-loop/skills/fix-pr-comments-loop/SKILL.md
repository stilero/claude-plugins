---
name: fix-pr-comments-loop
description: Autonomous loop that drives a pull request to a clean review state by dispatching one fresh Agent-tool subagent per round (each round = fetch unresolved copilot threads, fix via pr-comment-fixer, harden via hardcore-code-reviewer, verify, push, resolve threads, re-request copilot, poll). Per-round fresh context means hardcore-reviewer output, fix logs, verification logs, and polling spam do NOT accumulate across rounds — the orchestrator only sees a compact JSON return per round. Use this skill when the user wants to run a "fix-pr-comments loop", "address all PR comments and re-request review until clean", run an "autonomous PR fix loop", "drive PR to clean review", "auto-iterate PR comment fixes with hardcore review", or "loop fix-pr-comments until copilot is happy". Trigger proactively whenever the user asks to grind through copilot PR feedback rounds end-to-end, not just one round.
---

# fix-pr-comments-loop

Orchestrator that drives a PR to a clean review state by dispatching one fresh subagent per round. Each round runs in its own Agent-tool subagent so accumulated noise (hardcore-reviewer reports, fix-step diffs, verification logs, polling output) stays isolated and does not bloat the orchestrator's context across rounds.

This skill **does not run the round itself**. The per-round work — steps 0–8 (count unresolved threads, fix, harden, verify, push, resolve threads, re-request copilot, poll, decide) — lives in the companion skill `fix-pr-comments-loop-round`, which the orchestrator invokes once per round in a fresh subagent.

If the per-comment fix behavior changes, edit `pr-comment-fixer:fix-issues`. If the hardcore review heuristics change, edit `hardcore-code-reviewer:hardcore-code-reviewer`. If the per-round procedure changes, edit `fix-pr-comments-loop-round`. This skill only encodes the outer-loop / dispatch contract.

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
- The three child skills installed and triggerable: `pr-comment-fixer:fix-issues`, `hardcore-code-reviewer:hardcore-code-reviewer`, and `fix-pr-comments-loop-round`.
- A clean working tree at the start of the run.

**Shell execution environment:** every shell pipeline below (especially `gh ... | jq ...` invocations) should run with `set -o pipefail` so an upstream `gh` failure surfaces instead of being silently swallowed by a downstream `jq` that succeeds against empty stdin. The agent harness's bash session does NOT enable `pipefail` by default — set it explicitly at the start of any subshell or function that runs these pipelines.

## Step 1: fail-fast & one-time setup (orchestrator, before any round)

Run this once at the start of the run; the resolved values are passed to every per-round subagent below.

### Confirm open PR and capture identifiers

`gh pr view --json` does NOT accept a `baseRepository` field — valid base-repository fields are limited to `baseRefName` / `baseRefOid`. Derive owner and repo from the current repo instead:

```bash
# Confirm an open PR exists for the current branch and capture its number.
gh pr view --json number,state,headRefName,url

# Capture OWNER/REPO from the current repo (the branch's repo).
# Two distinct --jq passes — repo owner logins do not normally contain
# whitespace, but a whitespace-split of a single concatenated string is
# fragile. Prefer two separate calls.
OWNER=$(gh repo view --json owner --jq '.owner.login')
REPO=$(gh repo view --json name --jq '.name')
PR_NUMBER=$(gh pr view --json number --jq '.number')
BASE_BRANCH=$(gh pr view --json baseRefName --jq '.baseRefName')
```

Also assert the PR is open: `gh pr view --json state --jq '.state'` must equal `OPEN`. If the `gh pr view` command fails or returns `state != "OPEN"`, **abort immediately** with a message like:

> No open PR found for the current branch (`<branch>`). This skill only operates on open PRs — push the branch and open a PR first, then re-run.

Do not dispatch any round. This is a hard precondition.

### Verify clean working tree

```bash
test -z "$(git status --short)"  # if non-empty: emit "working tree not clean — commit, stash, or discard before running" to the user and stop the loop without dispatching round 1. This is an agent-control bail.
```

This avoids mixing pre-existing local edits into a round's `FIX_FILES` snapshot diff.

### Resolve `COPILOT_REVIEWER`

```bash
COPILOT_REVIEWER="${FIX_PR_COMMENTS_LOOP_REVIEWER:-copilot-pull-request-reviewer}"
```

The default GitHub Copilot reviewer login on most repos is `copilot-pull-request-reviewer` (the app slug; sometimes surfaced as `github-copilot[bot]`). If your repo's copilot reviewer has a different login (visible in `gh pr view --json reviewRequests`), set `FIX_PR_COMMENTS_LOOP_REVIEWER=<login>` before invoking the loop. `gh pr edit --add-reviewer` rejects `@`-prefixed handles — always pass the bare login.

### Resolve `VERIFY_CMD` via the discovery rules

The orchestrator resolves the verification command ONCE at run start and passes it to every round subagent. The command is **not hardcoded**. Discover it in this priority order:

1. **Explicit override (highest priority):** environment variable `FIX_PR_COMMENTS_LOOP_VERIFY` is set → use its value verbatim.
2. **Skill argument:** if the caller passed a `verify=<command>` argument, use it.
3. **Project CLAUDE.md:** read the host repo's `CLAUDE.md` (root) and search for an explicit verification sequence. **Heading priority** (deterministic order — first match wins):
   1. A heading whose text matches `Verification` (case-insensitive).
   2. Otherwise, a heading whose text matches `Tests` (case-insensitive).
   3. Otherwise, a heading whose text matches `Build` (case-insensitive).

   Once a heading is matched at the highest available priority, take the **first fenced code block** immediately under it as the verification command. This rule is deterministic across CLAUDE.md files that have multiple matching headings.
4. **Auto-detect from package manifest:** compose the verification command from intersected scripts and configured tools — never from a hardcoded chain.
   - `package.json` present with `yarn.lock` (and only `yarn.lock`) → `yarn` invocation built from the intersection of (scripts in `package.json`) and `[build, test, lint]` (see "Script intersection" below).
   - `package.json` present with `pnpm-lock.yaml` (and no other JS lockfile) → equivalent `pnpm` form, same script-intersection logic.
   - `package.json` present with `package-lock.json` (and no other JS lockfile) → equivalent `npm run` form, same script-intersection logic.
   - `pyproject.toml` with `[tool.pytest.ini_options]` or `pytest.ini` → `pytest`. Also append `&& ruff check .` if any of: `pyproject.toml` contains a `[tool.ruff]` section, OR `.ruff.toml` exists in repo root, OR `ruff.toml` exists in repo root.
   - `Makefile` with a `test` target → `make test`.
   - No manifest detectable → fall through to step 5.

   **Script intersection (Node.js auto-detect):** Before composing the chain, run `jq -r '.scripts | keys[]' package.json` (or use the Read tool to read `package.json` and parse the `scripts` object) and intersect the keys with `[build, test, lint]`. Compose the chain from **only the subcommands present in that intersection**, in that order. If the intersection is empty, fall through to step 5 (no-op fallback) — do not invoke `yarn`/`pnpm`/`npm` with no subcommands.

   **Per-package-manager invocation form (deterministic, do not improvise):** the three package managers each have a different "exact" form for invoking a script. Use the form below for each manager so two orchestrators auto-detecting against the same `package.json` produce the same command. Never write the bare `<package_manager> <script>` form (e.g. `npm build` is wrong — npm requires `npm run build`).
   - **yarn:** `yarn <script>` for every script (e.g. `yarn build`, `yarn test`, `yarn lint`).
   - **npm:** `npm run <script>` for `build` and `lint`; **`npm test`** (special-cased, no `run`) for `test`. Example chain: `npm run build && npm test && npm run lint`.
   - **pnpm:** `pnpm run <script>` for every script (e.g. `pnpm run build`, `pnpm run test`, `pnpm run lint`).

   Examples — given an intersection of `{build, test}` (no `lint` script):
   - yarn: `yarn build && yarn test`
   - npm: `npm run build && npm test`
   - pnpm: `pnpm run build && pnpm run test`

   **Lockfile tie-breaker:** If multiple JS lockfiles are present in the same repo, check `package.json` for a `packageManager` field (or `engines.packageManager`). If that field declares `yarn@...`, prefer yarn; if `pnpm@...`, prefer pnpm; if `npm@...`, prefer npm. If neither field is present and multiple lockfiles still match, fall through to step 5 with a one-line warning describing which lockfiles were detected and that no `packageManager` declaration could disambiguate them. Do not guess.
5. **No-op fallback (REFUSE TO DISPATCH):** if none of the above resolves a command, the orchestrator **MUST refuse to dispatch any round** and bail to the user with: `[fix-pr-comments-loop] no verification target found; set FIX_PR_COMMENTS_LOOP_VERIFY or add a build/test/lint script to package.json (or equivalent) before re-running`. Verification is a hard gate — silently no-op'ing it would let the loop push unverified code. A repo with no detectable verification target requires explicit user configuration before this skill can be used on it.

The resolved command is `$VERIFY_CMD` — passed verbatim to every round subagent.

### Initialize orchestrator state

```text
ROUND = 1
OUTER_CAP = 8                  # default; not currently configurable via env var
INNER_ITERATION_CAP = 3        # default
POLL_CAP_MINUTES = 60          # default
POLL_INTERVAL_SECONDS = 60     # default
COMPLEXITY_THRESHOLD = "${FIX_PR_COMMENTS_LOOP_COMPLEXITY_THRESHOLD:-3}"
RESOLVE_WINDOW = "${FIX_PR_COMMENTS_LOOP_RESOLVE_WINDOW:-20}"
COPILOT_LOGIN = ""             # captured on first round that observes a copilot review
total_threads_addressed = 0
total_findings_fixed = 0
total_threads_resolved = 0
per_round_outcomes = []        # list of compact summaries for the final user-facing summary
```

These are tracked in-memory by the orchestrator (TodoWrite or in-context) for the duration of the run. They do not persist across sessions; if the run is interrupted, the next session re-derives them by re-running this fail-fast step.

## Step 2: round dispatch loop (orchestrator drives, subagent executes)

Iterate `ROUND` from `1` to `OUTER_CAP` (default `8`). On each round, dispatch a fresh subagent and process its return:

### 2a. Dispatch the round subagent

Invoke the Agent tool with `subagent_type: general-purpose`. The prompt body MUST instruct the subagent to:

1. Load the `fix-pr-comments-loop-round` skill via the Skill tool.
2. Execute steps 0–8 of that skill against the supplied args.
3. Emit a single fenced ```` ```json ```` block as the **last** thing in its output — the orchestrator parses by extracting the last ` ```json ... ``` ` block in the relayed transcript.

Pass the following args inline in the prompt body (as plain `KEY=VALUE` lines or an enumerated list — both are unambiguous):

```text
ROUND=<current round number, 1..OUTER_CAP>
OUTER_CAP=<resolved outer cap, default 8>
OWNER=<from step 1>
REPO=<from step 1>
PR_NUMBER=<from step 1>
BASE_BRANCH=<from step 1>
COPILOT_REVIEWER=<from step 1>
VERIFY_CMD=<from step 1, verbatim — may contain spaces and shell operators>
INNER_ITERATION_CAP=3
POLL_CAP_MINUTES=60
POLL_INTERVAL_SECONDS=60
COMPLEXITY_THRESHOLD=<from step 1>
RESOLVE_WINDOW=<from step 1>
COPILOT_LOGIN=<orchestrator-persisted, "" until first capture>
```

Each round dispatch is sequential — the orchestrator does NOT spawn rounds in parallel. The Agent tool's subagent receives a fresh context window so prior rounds' noise does not leak in.

### 2b. Parse the round result (or bail on parse failure)

When the subagent returns, extract the LAST ` ```json ... ``` ` block from the relayed transcript and parse it. The expected schema is documented in `fix-pr-comments-loop-round`'s "Return value contract" section. Required fields: `round`, `outcome`, `bail_reason`, `bail_detail`, `pushed_sha`, `copilot_login`, `counts.{threads_addressed,findings_fixed,threads_resolved,new_copilot_comments}`, `artifacts.{latest_hardcore_report_excerpt,latest_verification_output_tail,latest_copilot_review_url}`.

If parsing fails for any reason — missing fenced block, malformed JSON, schema-violating fields, subagent crash before emission, or Agent-tool error — the orchestrator **bails to the user immediately**. No auto-retry. Include in the bail message:

1. The raw subagent output (or as much as the harness returned).
2. The output of `git log --oneline -5` so the user can see whether the round partially pushed.
3. The output of `gh pr view --json statusCheckRollup,reviewRequests` so the user can see the PR's current state (check status, requested reviewers).

These two recovery-hint commands are the most-asked questions after a crash ("did it push?", "is copilot still requested?"). Print them verbatim alongside the bail.

The orchestrator does NOT attempt to reconstruct missing JSON fields from git/gh — partial state after a crash is unsafe to act on. Hand control back to the user.

### 2c. Update orchestrator state from the parsed result

On a successful parse, the orchestrator updates:

- `total_threads_addressed += counts.threads_addressed`
- `total_findings_fixed   += counts.findings_fixed`
- `total_threads_resolved += counts.threads_resolved`
- If `COPILOT_LOGIN == ""` and `result.copilot_login != ""` → `COPILOT_LOGIN = result.copilot_login` (persist for subsequent rounds).
- Append a compact per-round summary to `per_round_outcomes` (round number, outcome, `pushed_sha`, the four `counts.*` values, `bail_reason` if any).

### 2d. Decide: continue, exit clean, or bail

- **`outcome == "clean"`**: Exit the dispatch loop with a final user-facing summary (see step 3 below).
- **`outcome == "continue"`**:
  - If `ROUND < OUTER_CAP`: increment `ROUND` and go back to step 2a.
  - If `ROUND == OUTER_CAP`: bail with the outer-cap message (see step 3 below).
- **`outcome == "bail"`**: Surface `bail_reason`, `bail_detail`, and the relevant `artifacts.*` to the user. Stop the loop. Do not dispatch further rounds.

The orchestrator's context across rounds only ever holds: the one-time setup state (above), the per-round structured result (the JSON, roughly 500 bytes), the cumulative tallies (a few integers), and `per_round_outcomes` (one compact line per round). No hardcore-reviewer findings dumps, no fix-step diffs, no verification logs, no polling spam — all of that lives and dies inside each subagent.

## Step 3: terminal output

Print one of three terminal messages depending on how the dispatch loop exited:

### On clean exit (zero new copilot comments on the final round's pushed SHA)

```text
[fix-pr-comments-loop] DONE — clean exit after <N> rounds
  Total comments addressed across rounds: <total_threads_addressed>
  Total hardcore findings fixed across rounds: <total_findings_fixed>
  Total threads resolved across rounds:   <total_threads_resolved>
  Final commit: <PUSHED_SHA from the last continue/clean round, or "(none — round 0 was empty)" if the run exited cleanly on round 1 with no unresolved threads>
  PR URL: <gh pr view --json url --jq '.url'>
```

### On outer-cap bail (round 8 returned `continue`)

```text
[fix-pr-comments-loop] CAP TRIPPED — outer-round cap (<OUTER_CAP>) reached without copilot returning a clean review
  Per-round summary:
    Round 1: <one-line per_round_outcomes entry>
    Round 2: ...
    ...
  Total comments addressed across rounds: <total_threads_addressed>
  Total hardcore findings fixed across rounds: <total_findings_fixed>
  Total threads resolved across rounds:   <total_threads_resolved>
  This usually means the diff is too ambitious for an autonomous loop and
  needs human steering. Inspect the latest copilot review and the
  per-round outcomes above before re-running.
```

### On per-round bail (subagent returned `outcome: bail`)

```text
[fix-pr-comments-loop] ROUND <N> BAILED — <bail_reason>
  <bail_detail>
  Artifacts:
    <latest_hardcore_report_excerpt — printed if non-null>
    <latest_verification_output_tail — printed if non-null>
    <latest_copilot_review_url — printed if non-null>
  Cumulative totals so far:
    threads_addressed=<total_threads_addressed>, findings_fixed=<total_findings_fixed>, threads_resolved=<total_threads_resolved>
```

### On JSON parse failure (subagent crashed or emitted no JSON)

```text
[fix-pr-comments-loop] ROUND <N> SUBAGENT FAILED — could not parse JSON return
  Recovery hints (cheap commands you may want to inspect):
    git log --oneline -5:
      <verbatim output>
    gh pr view --json statusCheckRollup,reviewRequests:
      <verbatim output>
  Raw subagent output (truncated to last 4000 chars):
    <verbatim>
```

## Status reporting

The orchestrator emits one-line dispatch and result lines to the user as it works. Subagent stdout (including the subagent's own `[step K]` status lines) is buffered by the Agent tool and dumped to the user only when the round completes — there is no live `[step K]` stream during a round.

Example orchestrator status lines:

- `[fix-pr-comments-loop] dispatching round 1/8 (subagent will run steps 0–8 in a fresh context)`
- `[fix-pr-comments-loop] round 1 complete — outcome=continue pushed=abc1234 threads_addressed=4 findings_fixed=2 threads_resolved=4 new_copilot_comments=1`
- `[fix-pr-comments-loop] dispatching round 2/8`
- ...
- `[fix-pr-comments-loop] round N complete — outcome=clean`

`tee fix-pr-comments-loop.log` on the orchestrator's stdout still works and gives a grep-friendly transcript of dispatch/result lines plus each round's buffered subagent output. The bracketed-tag prefix lets `grep '\[fix-pr-comments-loop\]'` isolate orchestrator lines and `grep '\[step 5\]'` isolate the resolution step across all rounds.

## Caps and bail-outs (orchestrator-enforced)

| Cap | Default | What happens at cap |
|---|---|---|
| Outer-round cap | `8` rounds | Round 8 returning `outcome: continue` triggers the outer-cap bail. The orchestrator does NOT dispatch a 9th round. |

The other caps (inner hardcore-review iterations, copilot poll cap, complexity threshold, rate-limit back-off, flake-retry) are enforced **inside** each round subagent — see `fix-pr-comments-loop-round`'s "Caps and bail-outs" section. The orchestrator surfaces those bails when a subagent returns `outcome: bail` with the appropriate `bail_reason`.

## What this skill is NOT

- Not a code reviewer. It calls `hardcore-code-reviewer:hardcore-code-reviewer` (via the round subagent).
- Not a per-comment fixer. It calls `pr-comment-fixer:fix-issues` (via the round subagent).
- Not a per-round executor. It calls `fix-pr-comments-loop-round` once per round in a fresh Agent-tool subagent.
- Not a generic PR automation. It only wraps the copilot review feedback loop and only fast-fails on missing PRs.
- Not a way to bypass the host-repo verification sequence — the resolved `$VERIFY_CMD` is mandatory before every push.
- Not a way to mass-resolve review threads — the strict mapping rule lives in the round subagent.

## Out of scope

- Triggering reviewers other than copilot (could be added later via a `--reviewer` flag).
- Handling branches without an open PR (fail fast — see step 1 above).
- Building a new reviewer (we wrap the existing hardcore-code-reviewer).
- Running rounds in parallel (the dispatch loop is sequential by design — copilot's per-PR review serialization makes parallel rounds meaningless).
- Resuming an interrupted run (skill state is in-memory; if the user Ctrl-C's mid-round, the next invocation restarts at round 1, and the per-round skill's idempotency — strict mapping rule on resolves, structural "already requested" check on reviewers — covers most of the recovery).

## Verification (static checks an implementer can run without a live PR)

- **No `[step K]` references for `K >= 9`:** `grep -E '\[step 9\]|step 9|Step 9' SKILL.md` should not match step-9 *content* (only "outer-cap" references). Step 9 (the previous outer-round-cap step inside the round) has been moved entirely into this orchestrator's step 2d.
- **The `fix-pr-comments-loop-round` companion skill exists:** check `plugins/fix-pr-comments-loop/skills/fix-pr-comments-loop-round/SKILL.md` is present and has matching front matter (`name: fix-pr-comments-loop-round`).
- **Auto-detect rule unchanged:** `grep -E '(yarn|pnpm|npm) (build|test|lint|run) (&&|build|test|lint)' SKILL.md` should match only inside the discovery-step explanation, never as an instruction to run a literal chain.
- **No `@`-prefixed reviewer handles:** `grep '\-\-add-reviewer @' SKILL.md` should not match command examples.
- **The dispatch-prompt section references the JSON return contract:** `grep -E "outcome|fenced.*json" SKILL.md` should match at least once.
