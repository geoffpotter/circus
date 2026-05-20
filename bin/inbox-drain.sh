#!/usr/bin/env bash
# inbox-drain.sh — drain new inbox events into the handler's prompt context.
#
# Called by the UserPromptSubmit hook (see .claude/settings.json).
# Emits any inbox.jsonl entries since the last drain, prefixed with [INBOX],
# then advances the cursor so the same events aren't repeated.
#
# Cursor file: $CIRCUS_ROOT/.inbox-cursor (gitignored, local-only state).
# If the cursor file is missing, treats all existing entries as already seen
# (only new entries from this point forward are surfaced).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_lib.sh"

CURSOR_FILE="$CIRCUS_ROOT/.inbox-cursor"
TOTAL=$(wc -l < "$CIRCUS_INBOX_LOG" 2>/dev/null | tr -d ' ' || echo 0)

# First run or reset: initialize cursor to current line count (no backfill).
if [[ ! -f "$CURSOR_FILE" ]]; then
  printf '%s' "$TOTAL" > "$CURSOR_FILE"
  exit 0
fi

CURSOR=$(cat "$CURSOR_FILE" 2>/dev/null || echo 0)

if [[ "$TOTAL" -gt "$CURSOR" ]]; then
  tail -n "+$((CURSOR + 1))" "$CIRCUS_INBOX_LOG" \
    | jq -rc 'select(.kind != null) |
              "[INBOX] [\(.kind)] \(.mission // "?") — \(.message // "")"'
  printf '%s' "$TOTAL" > "$CURSOR_FILE"
fi
