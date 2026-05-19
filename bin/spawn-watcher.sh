#!/usr/bin/env bash
# spawn-watcher.sh <mission-id> [--model X]
#
# Dispatches a watcher background session via `claude --bg --agent watcher`.
# Creates a detached-HEAD worktree at the legman's branch tip so it can
# read the code without conflicting with the legman's worktree.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_lib.sh"

usage() {
  echo "usage: spawn-watcher.sh <mission-id> [--model X]" >&2; exit 1
}

[[ $# -ge 1 ]] || usage
MISSION_ID="$1"; shift
MODEL="claude-sonnet-4-6"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL="$2"; shift 2;;
    *) usage;;
  esac
done

STATUS_FILE=$(mission_status "$MISSION_ID")
[[ -f "$STATUS_FILE" ]] || die "no mission: $MISSION_ID"

REPO=$(jq -r '.repo' "$STATUS_FILE")
BRANCH=$(jq -r '.branch' "$STATUS_FILE")
PR_URL=$(jq -r '.pr_url // ""' "$STATUS_FILE")
PR_NUMBER=$(jq -r '.pr_number // empty' "$STATUS_FILE")
[[ -n "$PR_URL" ]] || die "mission has no PR yet: $MISSION_ID"

REPO_PATH=$(repo_path "$REPO")

# Detached-HEAD worktree at branch tip — separate from legman's worktree.
WATCHER_WORKTREE="$CIRCUS_WORKTREES_DIR/${MISSION_ID}-watcher"
if [[ -d "$WATCHER_WORKTREE" ]]; then
  log "watcher worktree exists, reusing: $WATCHER_WORKTREE"
else
  log "creating watcher worktree at $WATCHER_WORKTREE"
  git -C "$REPO_PATH" fetch origin "$BRANCH" 2>/dev/null || true
  git -C "$REPO_PATH" worktree add --detach "$WATCHER_WORKTREE" "origin/$BRANCH" 2>/dev/null \
    || git -C "$REPO_PATH" worktree add --detach "$WATCHER_WORKTREE" "$BRANCH"
fi

WATCHER_SESSION_NAME="${MISSION_ID}-watcher"
status_set_state "$MISSION_ID" "in_review"
status_set "$MISSION_ID" "watcher_session_name" "$WATCHER_SESSION_NAME"
status_set "$MISSION_ID" "watcher_worktree" "$WATCHER_WORKTREE"

M_DIR=$(mission_dir "$MISSION_ID")
BRIEF_PATH=$(mission_brief "$MISSION_ID")

PROMPT=$(cat <<EOF
Mission: $MISSION_ID
Repo: $REPO
PR: $PR_URL (#$PR_NUMBER)
Brief: $BRIEF_PATH
Worktree (cwd, detached HEAD at branch tip): $WATCHER_WORKTREE
Mission dir: $M_DIR

Review the PR per your role instructions. Post your review on the PR via
\`gh pr review $PR_NUMBER --comment\`, then report verdict via:
  $CIRCUS_ROOT/bin/watcher-done.sh $MISSION_ID approve [--notes "..."]
  $CIRCUS_ROOT/bin/watcher-done.sh $MISSION_ID changes  [--notes "..."]
EOF
)

ensure_trusted "$WATCHER_WORKTREE"

log "dispatching watcher (model=$MODEL)"
SESSION_OUTPUT=$(
  cd "$WATCHER_WORKTREE" && \
  claude --bg \
    --agent watcher \
    --name "$WATCHER_SESSION_NAME" \
    --model "$MODEL" \
    --dangerously-skip-permissions \
    --add-dir "$M_DIR" \
    "$PROMPT" 2>&1
)
SESSION_ID=$(printf '%s' "$SESSION_OUTPUT" | grep -oE 'backgrounded · [a-f0-9]+' | awk '{print $3}' | head -1)
if [[ -z "$SESSION_ID" ]]; then
  log "WARNING: could not parse session id from claude --bg output:"
  printf '%s\n' "$SESSION_OUTPUT" | sed 's/^/  /' >&2
fi

[[ -n "$SESSION_ID" ]] && status_set "$MISSION_ID" "watcher_session_id" "$SESSION_ID"

cat <<EOF
mission:    $MISSION_ID
session:    ${SESSION_ID:-(unknown)}
worktree:   $WATCHER_WORKTREE
pr:         $PR_URL
model:      $MODEL

Monitor:    claude agents
Attach:     claude attach $SESSION_ID
Logs:       claude logs $SESSION_ID
EOF
