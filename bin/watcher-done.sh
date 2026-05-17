#!/usr/bin/env bash
# watcher-done.sh <mission-id>
#
# Called by a watcher after posting its PR review. Inspects the PR state:
# - if approved: gh pr merge --squash; state -> merged (or awaiting_upstream_approval for contributor)
# - if changes requested: state -> revisions
# - otherwise: leaves state as in_review (commented but undecided)
# In all cases, pings the handler with a one-line summary.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_lib.sh"

[[ $# -ge 1 ]] || { echo "usage: watcher-done.sh <mission-id>" >&2; exit 1; }
MISSION_ID="$1"
STATUS_FILE=$(mission_status "$MISSION_ID")
[[ -f "$STATUS_FILE" ]] || die "no mission: $MISSION_ID"

REPO=$(jq -r '.repo' "$STATUS_FILE")
PR_NUMBER=$(jq -r '.pr_number // empty' "$STATUS_FILE")
PR_URL=$(jq -r '.pr_url // ""' "$STATUS_FILE")
CATEGORY=$(repo_field "$REPO" '.category')
WATCHER_WT=$(jq -r '.watcher_worktree // ""' "$STATUS_FILE")

[[ -n "$PR_NUMBER" ]] || die "no PR number on mission $MISSION_ID"

# Inspect the PR's latest review state. Need to cd into a repo dir for gh
# to know which repo.
CD_DIR=""
if [[ -n "$WATCHER_WT" && -d "$WATCHER_WT" ]]; then
  CD_DIR="$WATCHER_WT"
else
  CD_DIR=$(repo_field "$REPO" '.path')
fi

cd "$CD_DIR"

REVIEW_STATE=$(gh pr view "$PR_NUMBER" --json reviewDecision -q .reviewDecision 2>/dev/null || echo "")
# Possible values: APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED, or empty

OUTCOME=""
case "$REVIEW_STATE" in
  APPROVED)
    log "PR approved; merging"
    gh pr merge "$PR_NUMBER" --squash --delete-branch 2>&1 | sed 's/^/[gh] /' || die "merge failed"
    if [[ "$CATEGORY" == "contributor" ]]; then
      status_set "$MISSION_ID" "state" "awaiting_upstream_approval"
      OUTCOME="approved & merged into fork main; needs user OK to go upstream"
    else
      status_set "$MISSION_ID" "state" "merged"
      OUTCOME="approved & merged"
    fi
    ;;
  CHANGES_REQUESTED)
    status_set "$MISSION_ID" "state" "revisions"
    OUTCOME="changes requested — handler should relay notes to legman"
    ;;
  *)
    OUTCOME="review posted (no decision); still in_review"
    ;;
esac

# Ping handler
if tmux_session_exists "$(handler_session)"; then
  tmux_send "$(handler_session)" "[watcher-$MISSION_ID] $OUTCOME  ($PR_URL)"
fi

echo "$OUTCOME"
