#!/usr/bin/env bash
# close-mission.sh <mission-id>
#
# Tears down a completed mission: stops the legman & watcher background
# sessions, removes their worktrees, closes the mirrored issue if any,
# and archives state to done/.

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
SESSION_ID=$(jq -r '.session_id // ""' "$STATUS_FILE")
WATCHER_SESSION_ID=$(jq -r '.watcher_session_id // ""' "$STATUS_FILE")
SESSION_NAME=$(jq -r '.session_name // ""' "$STATUS_FILE")
WATCHER_SESSION_NAME=$(jq -r '.watcher_session_name // ""' "$STATUS_FILE")
REPO=$(jq -r '.repo // ""' "$STATUS_FILE")
REPO_PATH=""
[[ -n "$REPO" && "$REPO" != "(ferret)" ]] && REPO_PATH=$(repo_path "$REPO")

stop_session() {
  local s="$1"
  if [[ -n "$s" && "$s" != "null" ]]; then
    log "stopping background session $s"
    claude stop "$s" 2>/dev/null || true
    claude rm "$s" 2>/dev/null || true
  fi
}

stop_session_by_name() {
  local name="$1"
  [[ -n "$name" && "$name" != "null" ]] || return 0
  command -v claude >/dev/null 2>&1 || return 0
  local ids
  ids=$(claude agents --json 2>/dev/null \
    | jq -r --arg n "$name" '.[] | select(.name == $n) | .sessionId' \
    | head -20)
  [[ -n "$ids" ]] || return 0
  while IFS= read -r sid; do
    [[ -n "$sid" ]] || continue
    log "stopping background session by name ($name → $sid)"
    claude stop "$sid" 2>/dev/null || true
    claude rm "$sid" 2>/dev/null || true
  done <<<"$ids"
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

stop_session "$SESSION_ID"
stop_session "$WATCHER_SESSION_ID"
stop_session_by_name "$SESSION_NAME"
stop_session_by_name "$WATCHER_SESSION_NAME"
remove_worktree "$WORKTREE"
remove_worktree "$WATCHER_WORKTREE"

# Mark closed + close the mirrored GH issue (if any). The PR's `Closes #N`
# usually does this on merge, but call again for missions that didn't merge.
status_set_state "$MISSION_ID" "closed"
status_close_issue "$MISSION_ID" "Mission closed via close-mission.sh"

# Sync the status wiki page for this repo if status_wiki: on.
# Do this before archiving so REPO is still defined from status.json.
if [[ -n "$REPO" && "$REPO" != "(ferret)" ]]; then
  STATUS_WIKI=$(repo_field "$REPO" '.status_wiki')
  if [[ "$STATUS_WIKI" == "on" ]]; then
    log "syncing status wiki for $REPO after mission close"
    "$HERE/status-sync.sh" "$REPO" \
      || log "WARNING: status-sync.sh failed for $REPO — sync manually"
  fi
fi

mkdir -p "$CIRCUS_DONE_DIR"
mv "$M_DIR" "$CIRCUS_DONE_DIR/$MISSION_ID"
rebuild_inbox

log "mission closed: $MISSION_ID  archived to $CIRCUS_DONE_DIR/$MISSION_ID"
