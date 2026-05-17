#!/usr/bin/env bash
# close-mission.sh <mission-id>
#
# Tears down a completed mission: kills the tmux session, removes the
# worktree, writes a summary, archives state to done/.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_lib.sh"

[[ $# -ge 1 ]] || { echo "usage: close-mission.sh <mission-id>" >&2; exit 1; }
MISSION_ID="$1"
M_DIR=$(mission_dir "$MISSION_ID")
[[ -d "$M_DIR" ]] || die "no mission dir: $M_DIR"

STATUS_FILE=$(mission_status "$MISSION_ID")
WORKTREE=$(jq -r '.worktree // ""' "$STATUS_FILE")
SESSION=$(jq -r '.tmux_session // ""' "$STATUS_FILE")
REPO=$(jq -r '.repo // ""' "$STATUS_FILE")

# Kill tmux session if alive
if [[ -n "$SESSION" ]] && tmux_session_exists "$SESSION"; then
  log "killing tmux session $SESSION"
  tmux kill-session -t "$SESSION"
fi

# Remove worktree if present
if [[ -n "$WORKTREE" && -d "$WORKTREE" ]]; then
  REPO_PATH=$(repo_field "$REPO" '.path')
  if [[ -n "$REPO_PATH" && -d "$REPO_PATH" ]]; then
    log "removing worktree $WORKTREE"
    git -C "$REPO_PATH" worktree remove --force "$WORKTREE" 2>&1 || \
      { log "git worktree remove failed; falling back to rm -rf"; rm -rf "$WORKTREE"; }
  else
    rm -rf "$WORKTREE"
  fi
fi

# Mark closed and archive
status_set "$MISSION_ID" "state" "closed"
mkdir -p "$CIRCUS_DONE_DIR"
mv "$M_DIR" "$CIRCUS_DONE_DIR/$MISSION_ID"
rebuild_inbox

log "mission closed: $MISSION_ID  archived to $CIRCUS_DONE_DIR/$MISSION_ID"
