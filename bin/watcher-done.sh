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

[[ -n "$PR_NUMBER" ]] || die "no PR number on mission $MISSION_ID"

# Cd into the repo's main checkout (NOT the watcher worktree — watcher
# worktrees are detached HEAD and gh trips on branch detection).
CD_DIR=$(repo_path "$REPO")
[[ -n "$CD_DIR" && -d "$CD_DIR" ]] || die "repo path missing for: $REPO"
cd "$CD_DIR"
REPO_NWO=$(repo_nwo "$REPO")

# Cache the verdict + internal notes locally for audit. The substantive
# review lives on the PR itself (gh pr review --comment) — this file is a
# breadcrumb, not the source of truth.
REVIEW_FILE="$(mission_dir "$MISSION_ID")/review.md"
{
  echo "# Watcher verdict: $VERDICT"
  echo
  echo "PR (canonical review): $PR_URL"
  echo "Time: $(now_iso)"
  echo
  if [[ -n "$NOTES" ]]; then
    echo "## Internal notes"
    echo
    printf '%s\n' "$NOTES"
  else
    echo "_no internal notes — see PR comments for the actual review_"
  fi
} > "$REVIEW_FILE"

OUTCOME=""
CLOSE_OWNED=false
AUTO_RESPAWN=false

case "$VERDICT" in
  approve)
    # CI gate: block auto-merge if checks are still pending or have failed.
    CHECKS_JSON=$(gh pr checks "$PR_NUMBER" ${REPO_NWO:+--repo "$REPO_NWO"} --json name,state 2>/dev/null || echo '[]')
    [[ -z "$CHECKS_JSON" ]] && CHECKS_JSON='[]'
    CHECK_TOTAL=$(printf '%s' "$CHECKS_JSON" | jq 'length')
    CHECK_PENDING=$(printf '%s' "$CHECKS_JSON" | jq \
      '[.[] | select(.state | ascii_downcase | test("pending|queued|in_progress|waiting"))] | length')
    CHECK_FAILED=$(printf '%s' "$CHECKS_JSON" | jq \
      '[.[] | select(.state | ascii_downcase | test("fail|error|cancel|timed_out|action_required"))] | length')

    if [[ "$CHECK_TOTAL" -gt 0 && "$CHECK_PENDING" -gt 0 ]]; then
      status_set_state "$MISSION_ID" "awaiting_ci"
      notify_handler "$MISSION_ID" "awaiting-ci" \
        "$CHECK_PENDING CI check(s) still pending on PR #$PR_NUMBER — auto-merge blocked ($PR_URL)"
      log "CI checks pending; auto-merge deferred. Re-run watcher-done.sh $MISSION_ID approve when CI completes."
      echo "awaiting CI — $CHECK_PENDING pending check(s); re-run when CI completes"
      exit 0
    fi

    if [[ "$CHECK_TOTAL" -gt 0 && "$CHECK_FAILED" -gt 0 ]]; then
      status_set_state "$MISSION_ID" "ci_failed"
      notify_handler "$MISSION_ID" "ci-failed" \
        "$CHECK_FAILED CI check(s) failed on PR #$PR_NUMBER — needs human intervention ($PR_URL)"
      log "CI checks failed; cannot auto-merge. Investigate and resolve, then run watcher-done.sh manually."
      echo "CI failed — $CHECK_FAILED check(s) failed; human intervention required"
      exit 1
    fi

    log "watcher approved; squash-merging PR #$PR_NUMBER"
    GH_ARGS=( "$PR_NUMBER" --squash --delete-branch )
    [[ -n "$REPO_NWO" ]] && GH_ARGS=( --repo "$REPO_NWO" "${GH_ARGS[@]}" )
    if ! gh pr merge "${GH_ARGS[@]}" 2>&1 | sed 's/^/[gh] /'; then
      # If the PR was already merged (e.g. retry), treat that as success.
      PR_STATE=$(gh pr view "$PR_NUMBER" ${REPO_NWO:+--repo "$REPO_NWO"} --json state -q .state 2>/dev/null || echo "")
      [[ "$PR_STATE" == "MERGED" ]] || die "merge failed"
      log "PR was already merged; continuing"
    fi

    # Pull the local checkout to match remote after merge. On failure, log
    # the error to inbox but don't abort — the merge succeeded on the remote.
    DEFAULT_BRANCH=$(repo_field "$REPO" '.default_branch')
    [[ -z "$DEFAULT_BRANCH" || "$DEFAULT_BRANCH" == "null" ]] && DEFAULT_BRANCH="main"
    pull_output=$(git fetch origin "$DEFAULT_BRANCH" 2>&1 && \
                  git pull --ff-only origin "$DEFAULT_BRANCH" 2>&1) || {
      log "WARNING: pull after merge failed"
      notify_handler "$MISSION_ID" "pull-failed" \
        "After merge, failed to pull local $DEFAULT_BRANCH to match remote: $pull_output"
    }

    if [[ "$CATEGORY" == "contributor" ]]; then
      status_set_state "$MISSION_ID" "awaiting_upstream_approval"
      OUTCOME="approved & merged into fork main — needs user OK to publish upstream"
    else
      status_set_state "$MISSION_ID" "merged"
      OUTCOME="approved & merged; auto-closing mission"
      CLOSE_OWNED=true
    fi
    ;;
  changes)
    status_set_state "$MISSION_ID" "revisions"
    OUTCOME="changes requested; auto-respawning legman"
    AUTO_RESPAWN=true
    ;;
esac

KIND="review-${VERDICT}"
notify_handler "$MISSION_ID" "$KIND" "$OUTCOME  ($PR_URL)"

echo "$OUTCOME"

# Auto-respawn legman after all output is done (changes verdict).
if [[ "$AUTO_RESPAWN" == "true" ]]; then
  log "auto-respawning legman for revisions"
  "$HERE/respawn-legman.sh" "$MISSION_ID" \
    || log "WARNING: respawn-legman.sh failed — respawn manually: bin/respawn-legman.sh $MISSION_ID"
fi

# Auto-close owned missions after all output is done (approve verdict, owned repo).
# Detached so the invocation survives the watcher's own session being stopped by
# close-mission.sh. setsid is absent on Darwin; nohup + disown is sufficient
# because nohup ignores SIGHUP and disown drops the job from the shell's job table.
if [[ "$CLOSE_OWNED" == "true" ]]; then
  AUTO_CLOSE_LOG="$(mission_dir "$MISSION_ID")/auto-close.log"
  log "auto-closing mission $MISSION_ID (detached; log: $AUTO_CLOSE_LOG)"
  nohup "$HERE/close-mission.sh" "$MISSION_ID" \
    >"$AUTO_CLOSE_LOG" 2>&1 </dev/null &
  disown
fi
