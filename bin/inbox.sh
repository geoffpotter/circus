#!/usr/bin/env bash
# inbox.sh [--since <iso8601>] [--clear]
#
# Prints active missions and unread notifications. The handler reads this
# on demand instead of being pinged via tmux send-keys.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_lib.sh"

SINCE=""
CLEAR=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --since) SINCE="$2"; shift 2;;
    --clear) CLEAR=1; shift;;
    *) echo "usage: inbox.sh [--since <iso8601>] [--clear]" >&2; exit 1;;
  esac
done

rebuild_inbox

echo "=== ACTIVE MISSIONS ==="
COUNT=$(jq '.missions | length' "$CIRCUS_INBOX")
if [[ "$COUNT" -eq 0 ]]; then
  echo "(none)"
else
  jq -r '.missions[] | "\(.id)  [\(.state)]  \(.worker_type) \(.repo)  model=\(.model)  pr=\(.pr_url // "—")"' "$CIRCUS_INBOX"
fi

echo
echo "=== NOTIFICATIONS ==="
if [[ ! -s "$CIRCUS_INBOX_LOG" ]]; then
  echo "(none)"
else
  if [[ -n "$SINCE" ]]; then
    jq -r --arg since "$SINCE" 'select(.ts >= $since) | "\(.ts) [\(.kind)] \(.mission) — \(.message)"' "$CIRCUS_INBOX_LOG"
  else
    # Default: last 20 notifications
    tail -20 "$CIRCUS_INBOX_LOG" | jq -r '"\(.ts) [\(.kind)] \(.mission) — \(.message)"'
  fi
fi

if [[ "$CLEAR" -eq 1 ]]; then
  : > "$CIRCUS_INBOX_LOG"
  echo
  echo "(notifications cleared)"
fi
