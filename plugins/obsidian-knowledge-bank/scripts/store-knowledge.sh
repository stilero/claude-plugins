#!/bin/bash
# store-knowledge.sh — Store a knowledge entry directly from the shell
#
# Use this script from other hooks, CI pipelines, or shell aliases to write
# knowledge bank entries without going through Claude.
#
# USAGE:
#   ./store-knowledge.sh <category> <title> <content> [tags]
#
# ARGUMENTS:
#   category  — One of: learnings, decisions, context, sessions, adr
#   title     — Short title (will be slugified for the filename)
#   content   — The body text. Use $() or heredoc for multi-line:
#               content=$(cat <<'EOF'
#               Line one.
#               Line two.
#               EOF
#               )
#   tags      — Optional. Comma-separated, no spaces. e.g. "auth,jwt,security"
#
# EXAMPLES:
#   # Simple one-liner
#   ./store-knowledge.sh learnings "Always quote shell variables" \
#     "Unquoted variables break on spaces and glob patterns." "shell,bash,gotcha"
#
#   # Multi-line content via heredoc
#   content=$(cat <<'EOF'
#   The deploy pipeline requires DEPLOY_TOKEN to be set in CI secrets.
#   Without it the push step silently exits 0 but nothing is deployed.
#   EOF
#   )
#   ./store-knowledge.sh decisions "Deploy token required in CI" "$content" "ci,deploy,secrets"
#
# HOOK USAGE (e.g. PostToolUse or custom hooks):
#   Read JSON from stdin if needed, then call this script with extracted fields.

set -euo pipefail

CATEGORY="${1:-}"
TITLE="${2:-}"
CONTENT="${3:-}"
TAGS="${4:-}"

# ── Validate inputs ─────────────────────────────────────────────────────────

if [ -z "$CATEGORY" ] || [ -z "$TITLE" ] || [ -z "$CONTENT" ]; then
  echo "Usage: store-knowledge.sh <category> <title> <content> [tags]" >&2
  echo "Categories: learnings, decisions, context, sessions, adr" >&2
  exit 1
fi

VALID_CATEGORIES="learnings decisions context sessions adr"
if ! echo "$VALID_CATEGORIES" | grep -qw "$CATEGORY"; then
  echo "Error: invalid category '$CATEGORY'. Must be one of: $VALID_CATEGORIES" >&2
  exit 1
fi

# ── Locate knowledge bank ────────────────────────────────────────────────────

KB_DIR=".knowledge-bank"

if [ ! -d "$KB_DIR" ]; then
  echo "Error: .knowledge-bank/ not found in current directory." >&2
  echo "Run /kb-init in Claude first to set up the knowledge bank." >&2
  exit 1
fi

# ── Compute next ID ───────────────────────────────────────────────────────────

INDEX_FILE="${KB_DIR}/INDEX.md"
EXISTING=$(grep -c '^<!-- KB:' "$INDEX_FILE" 2>/dev/null || echo "0")
NEXT_ID=$((EXISTING + 1))
ID=$(printf "%04d" "$NEXT_ID")

# ── Dates and paths ───────────────────────────────────────────────────────────

DATE=$(date +%Y-%m-%d)
DATETIME=$(date +%Y-%m-%dT%H:%M:%S)
YEAR_MONTH=$(date +%Y-%m)

# Slugify the title: lowercase, spaces to hyphens, strip non-alphanumeric, max 60 chars
SLUG=$(echo "$TITLE" \
  | tr '[:upper:]' '[:lower:]' \
  | sed 's/[^a-z0-9 ]//g' \
  | sed 's/ \+/-/g' \
  | sed 's/^-\+\|-\+$//g' \
  | cut -c1-60)

if [ "$CATEGORY" = "adr" ]; then
  # ADRs get a numeric prefix; count existing ADR files
  ADR_COUNT=$(find "${KB_DIR}/adr" -name "ADR-*.md" 2>/dev/null | wc -l | tr -d ' ')
  ADR_NUM=$(printf "%04d" $((ADR_COUNT + 1)))
  FILENAME="ADR-${ADR_NUM}-${SLUG}.md"
  SUBDIR="${KB_DIR}/adr"
  FILEPATH="adr/${FILENAME}"
else
  SUBDIR="${KB_DIR}/${CATEGORY}/${YEAR_MONTH}"
  FILENAME="${DATE}-${SLUG}.md"
  FILEPATH="${CATEGORY}/${YEAR_MONTH}/${FILENAME}"
fi

mkdir -p "$SUBDIR"
FULL_PATH="${KB_DIR}/${FILEPATH}"

# ── Write the markdown file ───────────────────────────────────────────────────

cat > "$FULL_PATH" <<EOF
---
id: "${ID}"
title: "${TITLE}"
date: "${DATETIME}"
category: ${CATEGORY}
tags: [${TAGS}]
source: shell-script
---

${CONTENT}
EOF

# ── Update indexes ────────────────────────────────────────────────────────────

INDEX_ENTRY="<!-- KB: id=${ID} date=${DATE} category=${CATEGORY} tags=${TAGS} title=${TITLE} file=${FILEPATH} -->"

# Append to master index
echo "$INDEX_ENTRY" >> "$INDEX_FILE"

# Append to category index (create if missing)
CATEGORY_INDEX="${KB_DIR}/${CATEGORY}/INDEX.md"
if [ ! -f "$CATEGORY_INDEX" ]; then
  echo "# ${CATEGORY^} Index" > "$CATEGORY_INDEX"
  echo "" >> "$CATEGORY_INDEX"
  echo "<!-- KB entries for this category are listed below. One line per entry. -->" >> "$CATEGORY_INDEX"
  echo "" >> "$CATEGORY_INDEX"
fi
echo "$INDEX_ENTRY" >> "$CATEGORY_INDEX"

# ── Done ──────────────────────────────────────────────────────────────────────

echo "✓ Stored [${ID}] ${TITLE}"
echo "  File: ${FULL_PATH}"
echo "  Tags: ${TAGS:-none}"
