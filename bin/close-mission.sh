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
WATCHER_WORKTREE=$(jq -r '.watcher_worktree // ""' "$STATUS_FILE")
SESSION=$(jq -r '.tmux_session // ""' "$STATUS_FILE")
WATCHER_SESSION=$(jq -r '.watcher_session // ""' "$STATUS_FILE")
REPO=$(jq -r '.repo // ""' "$STATUS_FILE")
REPO_PATH=$(repo_field "$REPO" '.path' 2>/dev/null || echo "")

kill_session() {
  local s="$1"
  if [[ -n "$s" ]] && tmux_session_exists "$s"; then
    log "killing tmux session $s"
    tmux kill-session -t "$s"
  fi
}

remove_worktree() {
  local wt="$1"
  [[ -n "$wt" && -d "$wt" ]] || return 0
  if [[ -n "$REPO_PATH" && -d "$REPO_PATH" ]]; then
    log "removing worktree $wt"
    git -C "$REPO_PATH" worktree remove --force "$wt" 2>&1 || \
      { log "git worktree remove failed; falling back to rm -rf"; rm -rf "$wt"; }
  else
    rm -rf "$wt"
  fi
}

kill_session "$SESSION"
kill_session "$WATCHER_SESSION"
remove_worktree "$WORKTREE"
remove_worktree "$WATCHER_WORKTREE"

# Mark closed + close the mirrored GH issue (if any). The PR's `Closes #N`
# usually does this on merge, but call again for missions that didn't merge
# (revisions abandoned, or contributor missions that never went upstream).
status_set_state "$MISSION_ID" "closed"
status_close_issue "$MISSION_ID" "Mission closed via close-mission.sh"
mkdir -p "$CIRCUS_DONE_DIR"
mv "$M_DIR" "$CIRCUS_DONE_DIR/$MISSION_ID"
rebuild_inbox

log "mission closed: $MISSION_ID  archived to $CIRCUS_DONE_DIR/$MISSION_ID"
