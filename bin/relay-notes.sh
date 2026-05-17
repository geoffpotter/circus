#!/usr/bin/env bash
# relay-notes.sh <mission-id> [extra-message]
#
# Used after a watcher returns 'changes': forwards the review notes to the
# legman as a single message. Optionally appends an extra message from the
# handler. Flips mission state back to in_review once the legman has been
# told (we assume they'll address and re-push).

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_lib.sh"

[[ $# -ge 1 ]] || { echo "usage: relay-notes.sh <mission-id> [extra-message]" >&2; exit 1; }
MISSION_ID="$1"; shift
EXTRA="${*:-}"

STATUS_FILE=$(mission_status "$MISSION_ID")
[[ -f "$STATUS_FILE" ]] || die "no mission: $MISSION_ID"

REVIEW_FILE=$(mission_dir "$MISSION_ID")/review.md
[[ -f "$REVIEW_FILE" ]] || die "no review notes file at $REVIEW_FILE"

LEGMAN_SESSION=$(jq -r '.tmux_session' "$STATUS_FILE")
tmux_session_exists "$LEGMAN_SESSION" || die "legman session not running: $LEGMAN_SESSION (it may have been closed; respawn?)"

MSG=$({
  echo "Review notes from the watcher:"
  echo
  cat "$REVIEW_FILE"
  if [[ -n "$EXTRA" ]]; then
    echo
    echo "Handler notes: $EXTRA"
  fi
  echo
  echo "Please address these, commit, push, then run worker-done.sh again to re-request review."
})

tmux_send "$LEGMAN_SESSION" "$MSG"
status_set "$MISSION_ID" "state" "in_review"
log "relayed notes to $LEGMAN_SESSION; state -> in_review"
