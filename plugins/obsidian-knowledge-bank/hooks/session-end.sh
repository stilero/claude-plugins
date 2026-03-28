#!/bin/bash
# session-end.sh — Claude Stop hook
#
# Triggers at session end to prompt Claude to store significant learnings
# before the session closes.
#
# Install in .claude/settings.json:
#
#   "hooks": {
#     "Stop": [
#       {
#         "matcher": "",
#         "hooks": [
#           {
#             "type": "command",
#             "command": "bash .claude-plugin/hooks/session-end.sh"
#           }
#         ]
      #       }
#     ]
#   }
#
# Or in your global ~/.claude/settings.json for all repos.

set -euo pipefail

SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"
FLAG_FILE="/tmp/.kb-session-end-${SESSION_ID}"

# Only trigger once per session to avoid loops
if [ -f "$FLAG_FILE" ]; then
  printf '{"decision":"allow"}'
  exit 0
fi

# Only activate if this repo has a knowledge bank
if [ ! -d ".knowledge-bank" ]; then
  printf '{"decision":"allow"}'
  exit 0
fi

# Mark as triggered so we don't loop
touch "$FLAG_FILE"

printf '{"decision":"block","reason":"Before ending this session, use the knowledge-bank:knowledge-bank skill (Step 2f: SESSION) to review the conversation and store any significant learnings, decisions, or insights. Run the skill now, then signal done by using the complete_session tool."}'
