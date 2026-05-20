#!/usr/bin/env bash
# respawn-legman.sh <mission-id> [--notes <text-or-path>] [--model X]
#
# Bounces a mission back to a fresh legman after the watcher requested
# changes. Stops the prior legman session, reuses the existing worktree
# (still on the branch), and dispatches a new background session focused
# on addressing the PR review comments.
#
# A fresh session is preferred over `claude respawn <id>` (which would
# restart the prior session with its stale context); the new legman reads
# the PR comments directly and starts clean.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_lib.sh"

usage() {
  cat <<'EOF' >&2
usage: respawn-legman.sh <mission-id> [--notes <text-or-path>] [--model X]
  --notes   Extra handler-side context to include in the bootstrap prompt.
            Literal string OR path to a file (auto-detected).
  --model   Override model. Defaults to the model recorded on the mission.
EOF
  exit 1
}

[[ $# -ge 1 ]] || usage
MISSION_ID="$1"; shift

NOTES=""
MODEL_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes)  NOTES="$2"; shift 2;;
    --model)  MODEL_OVERRIDE="$2"; shift 2;;
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
PRIOR_SESSION_ID=$(jq -r '.session_id // ""' "$STATUS_FILE")
SESSION_NAME=$(jq -r '.session_name' "$STATUS_FILE")
MODEL=$(jq -r '.model' "$STATUS_FILE")
[[ -n "$MODEL_OVERRIDE" ]] && MODEL="$MODEL_OVERRIDE"
M_DIR=$(mission_dir "$MISSION_ID")

[[ -n "$PR_URL" ]] || die "mission $MISSION_ID has no PR"
[[ -d "$WORKTREE" ]] || die "worktree missing: $WORKTREE"

# Drift warning: the respawned legman will commit on top of the existing branch,
# not re-branch from default_branch, but flag drift so the handler knows.
REPO_PATH=$(repo_path "$REPO")
DEFAULT_BRANCH=$(repo_field "$REPO" '.default_branch')
[[ -n "$DEFAULT_BRANCH" ]] || DEFAULT_BRANCH="main"
git -C "$REPO_PATH" fetch origin --quiet 2>/dev/null || true
DRIFT=$(git -C "$REPO_PATH" rev-list --left-right --count "${DEFAULT_BRANCH}...origin/${DEFAULT_BRANCH}" 2>/dev/null || echo "0	0")
DRIFT_AHEAD=$(printf '%s' "$DRIFT" | awk '{print $1}')
DRIFT_BEHIND=$(printf '%s' "$DRIFT" | awk '{print $2}')
if [[ "$DRIFT_BEHIND" -gt 0 || "$DRIFT_AHEAD" -gt 5 ]]; then
  log "WARNING: local $REPO/$DEFAULT_BRANCH is $DRIFT_AHEAD ahead, $DRIFT_BEHIND behind origin/$DEFAULT_BRANCH — consider reconciling before the legman pushes again"
fi

# Stop and remove the prior session (state stays on disk per claude rm
# semantics, but we're about to start a fresh one with the same name).
if [[ -n "$PRIOR_SESSION_ID" ]]; then
  log "stopping prior legman session: $PRIOR_SESSION_ID"
  claude stop "$PRIOR_SESSION_ID" 2>/dev/null || true
  claude rm "$PRIOR_SESSION_ID" 2>/dev/null || true
fi

# Make sure the worktree is up to date with origin
( cd "$WORKTREE" && git fetch origin "$BRANCH" 2>/dev/null || true )

PROMPT_FILE="$M_DIR/revisions.prompt"
{
  cat <<EOF
Mission: $MISSION_ID  (returning for revisions)
Repo: $REPO
Worktree (cwd): $WORKTREE
Branch: $BRANCH
PR: $PR_URL (#$PR_NUMBER)
Original brief: $M_DIR/brief.md
Mission dir: $M_DIR

The watcher requested changes. Read the PR review comments:
  gh pr view $PR_NUMBER --comments
  gh pr diff $PR_NUMBER

Address each piece of feedback, commit incrementally, and when done run:
  $CIRCUS_ROOT/bin/worker-done.sh $MISSION_ID
(idempotent — pushes new commits, re-uses the existing PR.)

EOF
  if [[ -n "$NOTES" ]]; then
    printf 'Additional handler notes:\n%s\n\n' "$NOTES"
  fi
  cat <<EOF2
The original brief is still the source of truth for scope. If the
watcher notes seem to push beyond it, push back in your reply rather
than silently expanding scope.
EOF2
} > "$PROMPT_FILE"
PROMPT=$(cat "$PROMPT_FILE")

ensure_trusted "$WORKTREE"

SETTINGS_FILE="$M_DIR/.claude-settings.json"
jq -n --arg dir "$M_DIR" \
  '{permissions: {additionalDirectories: [$dir]}}' > "$SETTINGS_FILE"

log "dispatching fresh legman for revisions (model=$MODEL)"
SESSION_OUTPUT=$(
  cd "$WORKTREE" && \
  claude --bg \
    --agent legman \
    --name "$SESSION_NAME" \
    --model "$MODEL" \
    --settings "$SETTINGS_FILE" \
    --dangerously-skip-permissions \
    "$PROMPT" 2>&1
)
SESSION_ID=$(printf '%s' "$SESSION_OUTPUT" | grep -oE 'backgrounded · [a-f0-9]+' | awk '{print $3}' | head -1)
if [[ -z "$SESSION_ID" ]]; then
  log "WARNING: could not parse session id from claude --bg output:"
  printf '%s\n' "$SESSION_OUTPUT" | sed 's/^/  /' >&2
fi

[[ -n "$SESSION_ID" ]] && status_set "$MISSION_ID" "session_id" "$SESSION_ID"
status_set_state "$MISSION_ID" "in_review"
[[ -n "$MODEL_OVERRIDE" ]] && status_set "$MISSION_ID" "model" "$MODEL"

cat <<EOF
mission:    $MISSION_ID
session:    ${SESSION_ID:-(unknown)}
state:      in_review (respawned for revisions)
pr:         $PR_URL
model:      $MODEL

Monitor:    claude agents
Logs:       claude logs $SESSION_ID
EOF
