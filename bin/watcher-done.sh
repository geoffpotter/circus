#!/usr/bin/env bash
# watcher-done.sh <mission-id> <verdict> [--notes <markdown-or-path>]
#
# verdict: 'approve' | 'changes'
#
# Called by a watcher after reviewing a PR. GitHub forbids self-approval
# (we use the same account for the legman and the watcher), so we don't
# rely on GitHub's reviewDecision. Instead the watcher tells us the
# verdict directly.
#
# approve: merge the PR with --squash; state -> merged (or awaiting_upstream_approval for contributor)
# changes: state -> revisions; handler receives review notes

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_lib.sh"

usage() {
  echo "usage: watcher-done.sh <mission-id> <approve|changes> [--notes <text-or-path>]" >&2; exit 1
}

[[ $# -ge 2 ]] || usage
MISSION_ID="$1"; VERDICT="$2"; shift 2
NOTES=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes) NOTES="$2"; shift 2;;
    *) usage;;
  esac
done

[[ "$VERDICT" == "approve" || "$VERDICT" == "changes" ]] || usage

# If notes is a path, read its content
if [[ -n "$NOTES" && -f "$NOTES" ]]; then
  NOTES=$(cat "$NOTES")
fi

STATUS_FILE=$(mission_status "$MISSION_ID")
[[ -f "$STATUS_FILE" ]] || die "no mission: $MISSION_ID"

REPO=$(jq -r '.repo' "$STATUS_FILE")
PR_NUMBER=$(jq -r '.pr_number // empty' "$STATUS_FILE")
PR_URL=$(jq -r '.pr_url // ""' "$STATUS_FILE")
CATEGORY=$(repo_field "$REPO" '.category')
WATCHER_WT=$(jq -r '.watcher_worktree // ""' "$STATUS_FILE")

[[ -n "$PR_NUMBER" ]] || die "no PR number on mission $MISSION_ID"

# Cd into the repo's main checkout (NOT the watcher worktree — watcher
# worktrees are detached HEAD and gh trips on branch detection).
CD_DIR=$(repo_field "$REPO" '.path')
[[ -n "$CD_DIR" && -d "$CD_DIR" ]] || die "repo path missing for: $REPO"
cd "$CD_DIR"
# Determine OWNER/REPO for gh --repo, belt-and-suspenders against detached state.
REPO_NWO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")

# Save review notes to the mission dir for audit
REVIEW_FILE="$(mission_dir "$MISSION_ID")/review.md"
{
  echo "# Watcher review: $VERDICT"
  echo
  echo "PR: $PR_URL"
  echo "Time: $(now_iso)"
  echo
  if [[ -n "$NOTES" ]]; then
    echo "## Notes"
    echo
    printf '%s\n' "$NOTES"
  else
    echo "_no notes_"
  fi
} > "$REVIEW_FILE"

OUTCOME=""
case "$VERDICT" in
  approve)
    log "watcher approved; squash-merging PR #$PR_NUMBER"
    GH_ARGS=( "$PR_NUMBER" --squash --delete-branch )
    [[ -n "$REPO_NWO" ]] && GH_ARGS=( --repo "$REPO_NWO" "${GH_ARGS[@]}" )
    if ! gh pr merge "${GH_ARGS[@]}" 2>&1 | sed 's/^/[gh] /'; then
      # If the PR was already merged (e.g. retry), treat that as success.
      PR_STATE=$(gh pr view "$PR_NUMBER" ${REPO_NWO:+--repo "$REPO_NWO"} --json state -q .state 2>/dev/null || echo "")
      [[ "$PR_STATE" == "MERGED" ]] || die "merge failed"
      log "PR was already merged; continuing"
    fi
    if [[ "$CATEGORY" == "contributor" ]]; then
      status_set "$MISSION_ID" "state" "awaiting_upstream_approval"
      OUTCOME="approved & merged into fork main — needs user OK to publish upstream"
    else
      status_set "$MISSION_ID" "state" "merged"
      OUTCOME="approved & merged"
    fi
    ;;
  changes)
    status_set "$MISSION_ID" "state" "revisions"
    OUTCOME="changes requested — see $REVIEW_FILE"
    ;;
esac

# Ping handler
if tmux_session_exists "$(handler_session)"; then
  tmux_send "$(handler_session)" "[watcher-$MISSION_ID] $OUTCOME  ($PR_URL)"
fi

echo "$OUTCOME"
