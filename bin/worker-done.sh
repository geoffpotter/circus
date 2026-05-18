#!/usr/bin/env bash
# worker-done.sh <mission-id>
#
# Called by a legman from inside its worktree when work is ready for review.
# Commits any stragglers, pushes the branch, opens a PR, updates status.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_lib.sh"

[[ $# -ge 1 ]] || { echo "usage: worker-done.sh <mission-id>" >&2; exit 1; }
MISSION_ID="$1"
STATUS_FILE=$(mission_status "$MISSION_ID")
[[ -f "$STATUS_FILE" ]] || die "no mission: $MISSION_ID"

WORKTREE=$(jq -r '.worktree' "$STATUS_FILE")
BRANCH=$(jq -r '.branch' "$STATUS_FILE")
REPO=$(jq -r '.repo' "$STATUS_FILE")
BRIEF_PATH=$(mission_brief "$MISSION_ID")
CATEGORY=$(repo_field "$REPO" '.category')

[[ -d "$WORKTREE" ]] || die "worktree missing: $WORKTREE"

cd "$WORKTREE"

# Commit any uncommitted changes
if ! git diff --quiet || ! git diff --cached --quiet || [[ -n "$(git status --porcelain)" ]]; then
  log "committing leftover changes"
  git add -A
  if ! git diff --cached --quiet; then
    git commit -m "wip: stragglers for $MISSION_ID"
  fi
fi

# Make sure there is at least one commit on the branch beyond the base
BASE_BRANCH=$(repo_field "$REPO" '.default_branch')
[[ -n "$BASE_BRANCH" ]] || BASE_BRANCH="main"
if [[ -z "$(git log "$BASE_BRANCH..$BRANCH" --oneline 2>/dev/null || git log "origin/$BASE_BRANCH..$BRANCH" --oneline 2>/dev/null || true)" ]]; then
  die "no commits on $BRANCH beyond $BASE_BRANCH — nothing to PR"
fi

# Push
log "pushing $BRANCH to origin"
git push -u origin "$BRANCH"

# PR title & body from brief. If the mission has a mirrored issue, include
# `Closes #N` so the merge auto-closes the issue.
TITLE=$(head -n 1 "$BRIEF_PATH" | sed -E 's/^#+ *//')
[[ -n "$TITLE" ]] || TITLE="circus: $MISSION_ID"
ISSUE_NUMBER=$(jq -r '.issue_number // ""' "$STATUS_FILE")
BODY=$({
  cat "$BRIEF_PATH"
  printf '\n---\ncircus mission: %s\n' "$MISSION_ID"
  [[ -n "$ISSUE_NUMBER" && "$ISSUE_NUMBER" != "null" ]] && printf 'Closes #%s\n' "$ISSUE_NUMBER"
})

# Open the PR — base is the repo's default branch (which for a fork is the
# fork's default, exactly what we want for contributor repos). If a PR for
# this branch already exists (re-run / recovered worker), reuse it.
EXISTING=$(gh pr list --head "$BRANCH" --json url,number --jq '.[0]' 2>/dev/null || echo "")
if [[ -n "$EXISTING" && "$EXISTING" != "null" ]]; then
  PR_URL=$(printf '%s' "$EXISTING" | jq -r '.url')
  PR_NUMBER=$(printf '%s' "$EXISTING" | jq -r '.number')
  log "PR already exists, reusing: $PR_URL"
else
  log "opening PR"
  PR_URL=$(gh pr create --title "$TITLE" --body "$BODY" --base "$BASE_BRANCH" --head "$BRANCH" 2>&1 | tail -1)
  PR_NUMBER=$(printf '%s' "$PR_URL" | sed -E 's|.*/pull/([0-9]+).*|\1|')
fi

status_set_raw "$MISSION_ID" "pr_number" "${PR_NUMBER:-null}"
status_set "$MISSION_ID" "pr_url" "$PR_URL"
status_set_state "$MISSION_ID" "awaiting_review"

# Notify handler via inbox + notification (never via send-keys).
notify_handler "$MISSION_ID" "pr-ready" "PR ready for review: $PR_URL"

cat <<EOF
mission:  $MISSION_ID
state:    awaiting_review
pr:       $PR_URL
EOF
