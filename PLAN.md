---
task: PRODUKT-1384
planner_rounds: 1
approved_by:
---

# Plan

## Goal
Add a new Claude Code plugin (`fix-pr-comments-loop`) to the `stilero-tools` marketplace that wraps the existing `pr-comment-fixer` and `hardcore-code-reviewer` skills into a single autonomous loop: fetch unresolved PR threads → fix → hardcore-review until clean → verify → commit/push → resolve threads → re-request copilot → poll → repeat until the PR is review-clean or hard caps trip.

## Acceptance criteria
- [ ] New plugin directory exists at `plugins/fix-pr-comments-loop/` with `.claude-plugin/plugin.json` (name, description, version `1.0.0`, author).
- [ ] Plugin contains a single skill `skills/fix-pr-comments-loop/SKILL.md` with YAML frontmatter whose `description` triggers on phrases like "fix-pr-comments loop", "address all PR comments and re-request review until clean", "autonomous PR fix loop", "drive PR to clean review".
- [ ] `SKILL.md` body documents the full 9-step loop from `TASK.md` with the exact `gh pr view`, `gh api graphql` (reviewThreads + resolveReviewThread mutation), and `gh pr edit --add-reviewer @copilot` invocations.
- [ ] Skill explicitly invokes the existing `pr-comment-fixer:fix-issues` skill for the fix step and the `hardcore-code-reviewer:hardcore-code-reviewer` skill for the inner review loop (does NOT re-implement either).
- [ ] Skill respects the user's CLAUDE.md verification sequence: `yarn build && yarn test:unit && yarn test:integration && yarn lint` runs before every push, and a failed verification blocks the push.
- [ ] Skill never resolves a GitHub review thread that wasn't addressed by a code change in the just-pushed commit (mapping rule documented).
- [ ] Skill caps inner hardcore-review iterations (default 3) and outer loop rounds (default 8); on cap exhaustion it bails to the user with a status summary instead of pushing.
- [ ] Skill defines complexity-threshold bail-out rules (multi-file refactor, test removal, public-API change) that escalate to the user instead of auto-applying.
- [ ] Skill polls every 60s for new copilot review activity with a 60-min cap per round and surfaces a clear message if the reviewer is silent past cap.
- [ ] Skill fails fast with a clear message when no open PR exists for the current branch.
- [ ] An optional companion slash command `commands/fix-pr-comments-loop.md` exists that loads the skill and accepts an optional PR number argument (mirrors `pr-comment-fixer/commands/fix-issue.md` shape).
- [ ] Plugin `README.md` added at `plugins/fix-pr-comments-loop/README.md` with a usage example and a plain-English description of the loop, mirroring the style of `plugins/pr-comment-fixer/README.md`.
- [ ] `.claude-plugin/marketplace.json` at the repo root contains a new entry for `fix-pr-comments-loop` (name, source path, description, version `1.0.0`, author) — without this the plugin is invisible to users (per `CLAUDE.md`).
- [ ] `jq empty .claude-plugin/marketplace.json` and `jq empty plugins/fix-pr-comments-loop/.claude-plugin/plugin.json` both exit 0 (valid JSON).
- [ ] Skill frontmatter parses as valid YAML (no unbalanced quotes, single `description` key).

## Steps

### Step 1: Scaffold the plugin directory and manifest
**Goal:** Create the plugin skeleton (`plugins/fix-pr-comments-loop/.claude-plugin/plugin.json`) so the rest of the work has a place to land. The manifest declares name, description, version `1.0.0`, and author, matching the conventions used by sibling plugins (`pr-comment-fixer`, `hardcore-code-reviewer`).
**Files expected to change:**
- `plugins/fix-pr-comments-loop/.claude-plugin/plugin.json` (new)

**Verification:**
- `test -f plugins/fix-pr-comments-loop/.claude-plugin/plugin.json` exits 0.
- `jq -e '.name == "fix-pr-comments-loop" and .version == "1.0.0" and (.description | length > 0) and (.author.name | length > 0)' plugins/fix-pr-comments-loop/.claude-plugin/plugin.json` exits 0.

---

### Step 2: Write the core SKILL.md with frontmatter and loop documentation
**Goal:** Author the heart of the plugin — `skills/fix-pr-comments-loop/SKILL.md` — containing YAML frontmatter (with a trigger-rich `description`) and the full 9-step loop body. The body must reference (not re-implement) `pr-comment-fixer:fix-issues` and `hardcore-code-reviewer:hardcore-code-reviewer`, document the exact `gh` and GraphQL commands, and codify caps, verification gating, thread-resolution mapping, complexity bail-outs, and the no-open-PR fast fail.
**Files expected to change:**
- `plugins/fix-pr-comments-loop/skills/fix-pr-comments-loop/SKILL.md` (new)

**Verification:**
- `test -f plugins/fix-pr-comments-loop/skills/fix-pr-comments-loop/SKILL.md` exits 0.
- The file's YAML frontmatter parses cleanly: `python3 -c 'import yaml,sys,re; t=open("plugins/fix-pr-comments-loop/skills/fix-pr-comments-loop/SKILL.md").read(); m=re.match(r"---\n(.*?)\n---", t, re.S); assert m, "no frontmatter"; d=yaml.safe_load(m.group(1)); assert d.get("name")=="fix-pr-comments-loop" and "description" in d and len(d["description"])>0' && echo OK`.
- Manual content checks via `grep`: each of these patterns must appear at least once in `SKILL.md` — `pr-comment-fixer:fix-issues`, `hardcore-code-reviewer:hardcore-code-reviewer`, `resolveReviewThread`, `reviewThreads`, `gh pr edit --add-reviewer @copilot`, `yarn build && yarn test:unit && yarn test:integration && yarn lint`, `60s`, and the words `cap` and `complexity threshold`.

---

### Step 3: Add the companion slash command
**Goal:** Provide a thin slash-command wrapper at `commands/fix-pr-comments-loop.md` that loads the skill via the `Skill` tool and accepts an optional PR number argument — mirroring the shape of `plugins/pr-comment-fixer/commands/fix-issue.md`. Keeps muscle-memory parity with the existing plugin.
**Files expected to change:**
- `plugins/fix-pr-comments-loop/commands/fix-pr-comments-loop.md` (new)

**Verification:**
- `test -f plugins/fix-pr-comments-loop/commands/fix-pr-comments-loop.md` exits 0.
- File starts with a `---` YAML block and contains a `description:` key (`grep -q '^description:' plugins/fix-pr-comments-loop/commands/fix-pr-comments-loop.md`).
- File contains the literal string `fix-pr-comments-loop` (skill name) in the body, confirming it dispatches to the skill (`grep -q 'fix-pr-comments-loop' plugins/fix-pr-comments-loop/commands/fix-pr-comments-loop.md`).

---

### Step 4: Add plugin README
**Goal:** Document the plugin externally with a `README.md` describing what the loop does, the prerequisites (`gh ≥ 2.88`, repo with an open PR, `pr-comment-fixer` + `hardcore-code-reviewer` plugins also installed), trigger phrases, and a one-paragraph usage example. Mirror the structure of `plugins/pr-comment-fixer/README.md`.
**Files expected to change:**
- `plugins/fix-pr-comments-loop/README.md` (new)

**Verification:**
- `test -f plugins/fix-pr-comments-loop/README.md` exits 0.
- README mentions all three: `pr-comment-fixer`, `hardcore-code-reviewer`, and `gh` (one `grep -q` per term, all must pass).
- README contains a `## Usage` (or equivalent `Usage`) heading: `grep -q -i '^##.*usage' plugins/fix-pr-comments-loop/README.md`.

---

### Step 5: Register the plugin in the marketplace manifest
**Goal:** Append a new object to the `plugins` array in `.claude-plugin/marketplace.json` so the plugin is discoverable via `/plugin install`. Per `CLAUDE.md`: "Without an entry here, the plugin exists in the repo but is invisible to users."
**Files expected to change:**
- `.claude-plugin/marketplace.json` (modify — append one entry)

**Verification:**
- `jq -e '.plugins | map(select(.name=="fix-pr-comments-loop")) | length == 1' .claude-plugin/marketplace.json` exits 0.
- `jq -e '.plugins[] | select(.name=="fix-pr-comments-loop") | .source == "./plugins/fix-pr-comments-loop" and .version == "1.0.0" and (.description | length > 20) and (.author.name | length > 0)' .claude-plugin/marketplace.json` exits 0.
- `jq empty .claude-plugin/marketplace.json` exits 0 (valid JSON, no trailing-comma damage from the edit).

---

### Step 6: End-to-end consistency sweep
**Goal:** Cross-check that every acceptance criterion has a corresponding artifact and that the plugin matches the conventions enforced by `CLAUDE.md` (manifest under `.claude-plugin/`, semver version, marketplace entry present, skill frontmatter has the trigger phrases). No code changes expected — fix any drift discovered.
**Files expected to change:**
- Any of the files from steps 1–5 if drift is found; otherwise none.

**Verification:**
- All previous step verifications still pass when re-run.
- `grep -q "fix-pr-comments loop" plugins/fix-pr-comments-loop/skills/fix-pr-comments-loop/SKILL.md` AND `grep -q "re-request review" plugins/fix-pr-comments-loop/skills/fix-pr-comments-loop/SKILL.md` (the two mandatory trigger phrases from acceptance criteria) both exit 0.
- Directory tree matches the `CLAUDE.md` plugin convention: `find plugins/fix-pr-comments-loop -type f` lists exactly the manifest, the SKILL.md, the command, and the README (no stray files).
- `git status --short` shows only the expected new/modified paths (the new plugin tree plus the modified `marketplace.json`); nothing outside `plugins/fix-pr-comments-loop/` and `.claude-plugin/marketplace.json` is touched.
