#!/usr/bin/env bash
# inbox-watch.sh — block-and-emit. Pipe into the handler's Monitor tool.
#
# Watches inbox.jsonl and emits one formatted event line per new entry.
# Each line lands in the handler's context as:
#   [kind] mission-id — message
#
# Usage (inside a handler turn):
#   Monitor("bin/inbox-watch.sh")
#
# The tail -F -n 0 blocks until a new line arrives, then jq formats it
# and the Monitor tool fires the next handler turn with the event in context.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_lib.sh"

exec tail -F -n 0 "$CIRCUS_INBOX_LOG" \
  | jq -rc 'select(.kind != null) |
            "[\(.kind)] \(.mission // "?") — \(.message // "")"'
