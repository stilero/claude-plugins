#!/bin/bash
# github-issue-generator stop hook
#
# Triggers /github-issue-generator once per session when Claude stops,
# prompting it to evaluate whether any conversation findings are worth
# tracking as GitHub issues.
#
# Setup: add this to your project's .claude/settings.json:
#
#   "hooks": {
#     "Stop": [
#       {
#         "hooks": [
#           {
#             "type": "command",
#             "command": "/path/to/this/stop-hook.sh"
#           }
#         ]
#       }
#     ]
#   }

set -euo pipefail

# Read session ID from hook stdin payload
SESSION_ID=$(jq -r '.session_id // empty' 2>/dev/null || true)

# If no session ID available, exit cleanly to avoid blocking stop
if [ -z "$SESSION_ID" ]; then
    exit 0
fi

FLAG_FILE="/tmp/.claude-issue-gen-${SESSION_ID}"

# Only trigger once per session to avoid an infinite loop
if [ -f "$FLAG_FILE" ]; then
    exit 0
fi

# Mark this session as evaluated before outputting the block decision,
# so if something goes wrong we don't get stuck in a loop
touch "$FLAG_FILE"

# Block the stop and ask Claude to run the github-issue-generator skill.
# Claude will process the "reason" as a new instruction.
printf '{"decision":"block","reason":"Before finishing, run /github-issue-generator to check whether any findings from this conversation are worth tracking as GitHub issues. Apply the value criteria strictly — if there are no high-value findings, say so in one sentence and stop."}'
