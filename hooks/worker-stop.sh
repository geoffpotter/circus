#!/usr/bin/env bash
# worker-stop.sh <mission-id> <worker-type>
#
# Claude Code Stop hook for circus workers. Fires whenever the worker's
# model finishes a turn (idle, awaiting input). We:
#  1. Update last_heartbeat on status.json
#  2. Extract the last assistant text from the transcript
#  3. Ping the handler tmux session (if it's running) with a one-line summary
#
# Hook input arrives on stdin as JSON, including transcript_path.

set -euo pipefail
# Make sure brew binaries are on PATH (Claude Code hooks may run with a
# minimal environment).
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../bin/_lib.sh"

MISSION_ID="${1:-}"
WORKER_TYPE="${2:-legman}"
[[ -n "$MISSION_ID" ]] || { echo "worker-stop: missing mission id" >&2; exit 0; }

# Bail silently if the mission file is gone (already closed)
STATUS_FILE=$(mission_status "$MISSION_ID")
[[ -f "$STATUS_FILE" ]] || exit 0

# Read hook input
INPUT="$(cat)"
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")

# Heartbeat
status_set "$MISSION_ID" "last_heartbeat" "$(now_iso)"

# Pull last assistant text from transcript (best-effort).
LAST_TEXT=""
if [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]]; then
  LAST_TEXT=$(jq -s '
      [ .[] | select(.type == "assistant" or .message.role == "assistant") ]
      | last
      | .message.content
      | (if type == "string" then .
         elif type == "array" then ([.[] | select(.type == "text") | .text] | join("\n"))
         else "" end)
    ' "$TRANSCRIPT" 2>/dev/null | jq -r '.' 2>/dev/null || echo "")
  # Trim
  LAST_TEXT=$(printf '%s' "$LAST_TEXT" | tr -d '\r' | head -c 600)
fi

SESSION_NAME="${WORKER_TYPE}-${MISSION_ID}"

# Append to transcript log for audit
{
  echo "--- $(now_iso) [$SESSION_NAME] turn end ---"
  printf '%s\n' "${LAST_TEXT:-(no text)}"
} >> "$(mission_transcript "$MISSION_ID")"

# Notify handler via inbox + (best-effort) macOS notification. Never inject
# text into the handler's tmux pane — that splices into whatever the user
# is typing.
notify_handler "$MISSION_ID" "turn-end" "[$SESSION_NAME] ${LAST_TEXT:-(turn ended, no text)}"

exit 0
