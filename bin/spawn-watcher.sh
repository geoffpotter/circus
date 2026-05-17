#!/usr/bin/env bash
# spawn-watcher.sh <mission-id> [--model X]
#
# Spawn a watcher (reviewer) for an awaiting-review mission. The watcher
# gets a detached worktree at the legman's branch tip, reads the diff via
# gh, posts a review, and either merges (on approve) or returns notes to
# the handler (on request-changes).

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_lib.sh"

usage() {
  echo "usage: spawn-watcher.sh <mission-id> [--model X] [--attach]" >&2; exit 1
}

[[ $# -ge 1 ]] || usage
MISSION_ID="$1"; shift
MODEL="claude-sonnet-4-6"
ATTACH=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL="$2"; shift 2;;
    --attach) ATTACH=1; shift;;
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

REPO_PATH=$(repo_field "$REPO" '.path')
WORKTREE_ROOT=$(repo_field "$REPO" '.worktree_root')
CATEGORY=$(repo_field "$REPO" '.category')

# Detached worktree at the branch tip so we don't conflict with the legman's tree
WATCHER_WORKTREE="$WORKTREE_ROOT/${MISSION_ID}-watcher"
if [[ -d "$WATCHER_WORKTREE" ]]; then
  log "watcher worktree already exists, reusing: $WATCHER_WORKTREE"
else
  log "creating watcher worktree at $WATCHER_WORKTREE"
  # Fetch the legman's pushed branch to make sure we see it
  git -C "$REPO_PATH" fetch origin "$BRANCH" 2>/dev/null || true
  git -C "$REPO_PATH" worktree add --detach "$WATCHER_WORKTREE" "origin/$BRANCH" 2>/dev/null \
    || git -C "$REPO_PATH" worktree add --detach "$WATCHER_WORKTREE" "$BRANCH"
fi

# Wire up Stop hook
mkdir -p "$WATCHER_WORKTREE/.claude"
cat > "$WATCHER_WORKTREE/.claude/settings.local.json" <<JSON
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "$CIRCUS_ROOT/hooks/worker-stop.sh $MISSION_ID watcher"
          }
        ]
      }
    ]
  }
}
JSON

# Mark mission state in_review and record watcher session
WATCHER_SESSION=$(watcher_session "$MISSION_ID")
status_set "$MISSION_ID" "state" "in_review"
status_set "$MISSION_ID" "watcher_session" "$WATCHER_SESSION"
status_set "$MISSION_ID" "watcher_worktree" "$WATCHER_WORKTREE"

# Bootstrap prompt
M_DIR=$(mission_dir "$MISSION_ID")
BRIEF_PATH=$(mission_brief "$MISSION_ID")
PROMPT_FILE="$M_DIR/watcher.prompt"
cat > "$PROMPT_FILE" <<PROMPT
You are a watcher in circus reviewing mission $MISSION_ID for repo $REPO.

The legman has opened PR: $PR_URL
Mission brief: $BRIEF_PATH
Your worktree (detached HEAD at branch tip): $WATCHER_WORKTREE — read files freely.

Your job:
1. Read the brief.
2. Read the diff: gh pr diff $PR_NUMBER
3. Inspect any files you want, in this worktree.
4. Optionally post a public comment on the PR for context:
     gh pr review $PR_NUMBER --comment --body "<short review>"
   (Don't try to use --approve: GitHub forbids approving your own PRs and
   the legman ran under the same account. We approve internally instead.)
5. Decide your verdict and finalize. ONE of:
     $CIRCUS_ROOT/bin/watcher-done.sh $MISSION_ID approve [--notes "..."]
     $CIRCUS_ROOT/bin/watcher-done.sh $MISSION_ID changes  --notes "..."
   On 'approve', the PR is squash-merged and the handler is pinged.
   On 'changes', the mission moves to 'revisions' and the handler relays
   notes back to the legman. Always pass --notes on changes; on approve
   it's optional but a one-line summary helps the audit log.

Review standards:
- The brief is the source of truth for scope. Don't request changes beyond the brief.
- Look for: correctness, tests if applicable, obvious bugs, security issues,
  scope creep, broken style consistency.
- Be concise. Reviewers who write paragraphs don't get read.

After running watcher-done.sh, your job is done. You can stop.
PROMPT

LAUNCH_FILE="$M_DIR/watcher-launch.sh"
cat > "$LAUNCH_FILE" <<LAUNCH
#!/usr/bin/env bash
set -e
cd "$WATCHER_WORKTREE"
exec claude --dangerously-skip-permissions \\
  --model "$MODEL" \\
  --add-dir "$M_DIR" \\
  -n "$WATCHER_SESSION" \\
  "\$(cat "$PROMPT_FILE")"
LAUNCH
chmod +x "$LAUNCH_FILE"

log "starting watcher tmux session: $WATCHER_SESSION"
tmux new-session -d -s "$WATCHER_SESSION" -c "$WATCHER_WORKTREE" "$LAUNCH_FILE"
auto_dismiss_trust "$WATCHER_SESSION"

if [[ "$ATTACH" -eq 1 ]]; then
  "$HERE/attach-window.sh" "$WATCHER_SESSION"
fi

cat <<EOF
mission:  $MISSION_ID
session:  $WATCHER_SESSION
worktree: $WATCHER_WORKTREE
pr:       $PR_URL
model:    $MODEL
EOF
