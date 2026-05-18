#!/usr/bin/env bash
# respawn-legman.sh <mission-id> [--notes <text-or-path>] [--model X] [--attach]
#
# Used to bounce a mission back to a legman after the watcher requested
# changes. Kills the prior legman tmux session (if any), reuses the existing
# worktree (still on the branch), and starts a fresh Claude session with a
# bootstrap prompt telling it to read the PR's review comments and address
# them.
#
# This replaces the old relay-notes.sh + tmux-send-keys mechanism. Cleaner:
# the new session starts with no in-progress reasoning to splice into and a
# crisp, single-focus task.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_lib.sh"

usage() {
  cat <<'EOF' >&2
usage: respawn-legman.sh <mission-id> [--notes <text-or-path>] [--model X] [--attach]
  --notes   Extra handler-side context to include in the bootstrap prompt.
            Either a literal string or a path to a file (auto-detected).
  --model   Override the model. Defaults to the model recorded on the mission.
  --attach  Open a Terminal.app window attached to the tmux session.
EOF
  exit 1
}

[[ $# -ge 1 ]] || usage
MISSION_ID="$1"; shift

NOTES=""
MODEL_OVERRIDE=""
ATTACH=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes)  NOTES="$2"; shift 2;;
    --model)  MODEL_OVERRIDE="$2"; shift 2;;
    --attach) ATTACH=1; shift;;
    *) usage;;
  esac
done

if [[ -n "$NOTES" && -f "$NOTES" ]]; then
  NOTES=$(cat "$NOTES")
fi

STATUS_FILE=$(mission_status "$MISSION_ID")
[[ -f "$STATUS_FILE" ]] || die "no mission: $MISSION_ID"

REPO=$(jq -r '.repo' "$STATUS_FILE")
BRANCH=$(jq -r '.branch' "$STATUS_FILE")
WORKTREE=$(jq -r '.worktree' "$STATUS_FILE")
PR_URL=$(jq -r '.pr_url // ""' "$STATUS_FILE")
PR_NUMBER=$(jq -r '.pr_number // empty' "$STATUS_FILE")
SESSION=$(jq -r '.tmux_session' "$STATUS_FILE")
MODEL=$(jq -r '.model' "$STATUS_FILE")
[[ -n "$MODEL_OVERRIDE" ]] && MODEL="$MODEL_OVERRIDE"
M_DIR=$(mission_dir "$MISSION_ID")

[[ -n "$PR_URL" ]] || die "mission $MISSION_ID has no PR"
[[ -d "$WORKTREE" ]] || die "worktree missing: $WORKTREE"

# Kill the prior legman session (it's idle after worker-done.sh ran, but a
# fresh start is cleaner than splicing into stale conversation state).
if tmux_session_exists "$SESSION"; then
  log "killing prior legman session: $SESSION"
  tmux kill-session -t "$SESSION"
fi

# Make sure the worktree's still on the branch and up to date with origin.
( cd "$WORKTREE" && git fetch origin "$BRANCH" 2>/dev/null || true )

# Write the bootstrap prompt for the revisions round.
PROMPT_FILE="$M_DIR/revisions.prompt"
{
  echo "You are a legman in circus on mission $MISSION_ID, returning for revisions."
  echo
  echo "Repo: $REPO"
  echo "Worktree (your cwd): $WORKTREE"
  echo "Branch you are on: $BRANCH"
  echo "PR: $PR_URL"
  echo "Original brief: $M_DIR/brief.md"
  echo
  echo "The watcher requested changes. Your job:"
  echo
  echo "1. Read the review comments on the PR:"
  echo "     gh pr view $PR_NUMBER --comments"
  echo "     gh pr diff $PR_NUMBER"
  echo "2. Address each piece of feedback in this worktree."
  echo "3. Commit your changes incrementally (small focused commits)."
  echo "4. When done, run:"
  echo "     $CIRCUS_ROOT/bin/worker-done.sh $MISSION_ID"
  echo "   (it's idempotent — re-uses the existing PR, pushes new commits,"
  echo "   and flips the mission back to awaiting_review.)"
  echo
  if [[ -n "$NOTES" ]]; then
    echo "Handler notes (in addition to the PR comments):"
    echo
    printf '%s\n' "$NOTES"
    echo
  fi
  echo "Constraints:"
  echo "- Stay on this branch ($BRANCH)."
  echo "- The original brief is still the source of truth for scope. If the"
  echo "  watcher's notes seem to push beyond it, push back in your reply"
  echo "  rather than silently expanding scope."
} > "$PROMPT_FILE"

# Reuse the per-mission launcher pattern (avoids quoting hell).
LAUNCH_FILE="$M_DIR/launch.sh"
cat > "$LAUNCH_FILE" <<LAUNCH
#!/usr/bin/env bash
set -e
cd "$WORKTREE"
exec claude --dangerously-skip-permissions \\
  --model "$MODEL" \\
  --add-dir "$M_DIR" \\
  -n "$MISSION_ID" \\
  "\$(cat "$PROMPT_FILE")"
LAUNCH
chmod +x "$LAUNCH_FILE"

log "starting fresh legman session: $SESSION (model=$MODEL)"
tmux new-session -d -s "$SESSION" -c "$WORKTREE" "$LAUNCH_FILE"
auto_dismiss_trust "$SESSION"

# Flip state back to in_review so the inbox view shows it as active.
status_set_state "$MISSION_ID" "in_review"
[[ -n "$MODEL_OVERRIDE" ]] && status_set "$MISSION_ID" "model" "$MODEL"

if [[ "$ATTACH" -eq 1 ]]; then
  "$HERE/attach-window.sh" "$SESSION"
fi

cat <<EOF
mission:  $MISSION_ID
session:  $SESSION
state:    in_review (respawned for revisions)
pr:       $PR_URL
model:    $MODEL
EOF
