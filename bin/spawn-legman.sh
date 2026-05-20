#!/usr/bin/env bash
# spawn-legman.sh <repo> <brief-path> [--model X]
#
# Dispatches a legman background session via `claude --bg --agent legman`.
# Workflow:
#   1. Create worktree on circus/<mission-id> branched from default
#   2. Apply identity for that repo
#   3. If repo is issues_mode=mirror, create the GH issue
#   4. Init status.json
#   5. cd into worktree, dispatch claude --bg, capture session ID
#   6. Print summary
#
# Claude Code's supervisor manages the session lifecycle (running, idle,
# stopping, restarting). We don't use tmux for workers.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_lib.sh"

usage() {
  cat <<'EOF' >&2
usage: spawn-legman.sh <repo> <brief-path> [--model X] [--force]
  repo         Name of the repo as registered in repos.yml
  brief-path   Path to a markdown file describing the mission
  --model X    Claude model (default: claude-sonnet-4-6)
  --force      Skip the local/origin drift check (use only after reconciling manually)
EOF
  exit 1
}

[[ $# -ge 2 ]] || usage
REPO="$1"; BRIEF_SRC="$2"; shift 2
MODEL="claude-sonnet-4-6"
FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL="$2"; shift 2;;
    --force) FORCE=1; shift;;
    *) usage;;
  esac
done

repo_exists "$REPO" || die "repo not found in repos.yml: $REPO"
[[ -f "$BRIEF_SRC" ]] || die "brief not found: $BRIEF_SRC"

REPO_PATH=$(repo_path "$REPO")
CATEGORY=$(repo_field "$REPO" '.category')
DEFAULT_BRANCH=$(repo_field "$REPO" '.default_branch')
[[ -n "$DEFAULT_BRANCH" ]] || DEFAULT_BRANCH="main"
ISSUES_MODE=$(repo_field "$REPO" '.issues_mode')
[[ -n "$ISSUES_MODE" ]] || ISSUES_MODE="local"

[[ "$CATEGORY" == "reference" ]] && die "cannot spawn a legman on a reference repo: $REPO"
[[ -d "$REPO_PATH" ]] || die "repo path missing on disk: $REPO_PATH"

# Pre-spawn drift guard: abort if local default branch diverges from origin.
# Prevents PRs with thousands of lines of spurious diff.
if [[ "$FORCE" -eq 0 ]]; then
  git -C "$REPO_PATH" fetch origin --quiet 2>/dev/null || true
  DRIFT=$(git -C "$REPO_PATH" rev-list --left-right --count "${DEFAULT_BRANCH}...origin/${DEFAULT_BRANCH}" 2>/dev/null || echo "0	0")
  DRIFT_AHEAD=$(printf '%s' "$DRIFT" | awk '{print $1}')
  DRIFT_BEHIND=$(printf '%s' "$DRIFT" | awk '{print $2}')
  if [[ "$DRIFT_BEHIND" -gt 0 || "$DRIFT_AHEAD" -gt 5 ]]; then
    printf '[circus] ABORT: local %s/%s is %s ahead, %s behind origin/%s.\n' \
      "$REPO" "$DEFAULT_BRANCH" "$DRIFT_AHEAD" "$DRIFT_BEHIND" "$DEFAULT_BRANCH" >&2
    printf '        PRs spawned from this state will have spurious diffs and may not be mergeable.\n' >&2
    printf '        Reconcile: cd %s && git fetch && git status, then either\n' "$REPO_PATH" >&2
    printf '          git pull --rebase origin %s  (preserve local commits)\n' "$DEFAULT_BRANCH" >&2
    printf '          git reset --hard origin/%s   (DESTRUCTIVE — discards local commits)\n' "$DEFAULT_BRANCH" >&2
    printf '        Re-run spawn-legman.sh after reconciling.\n' >&2
    printf '        Or use --force to skip this check.\n' >&2
    exit 1
  fi
fi

# Mission id from brief title
BRIEF_TITLE=$(head -n 1 "$BRIEF_SRC" | sed -E 's/^#+ *//')
[[ -n "$BRIEF_TITLE" ]] || BRIEF_TITLE="mission"
MISSION_ID=$(generate_mission_id "$BRIEF_TITLE")
M_DIR=$(mission_dir "$MISSION_ID")
mkdir -p "$M_DIR"
cp "$BRIEF_SRC" "$M_DIR/brief.md"
BRIEF_PATH="$M_DIR/brief.md"

# Worktree under shared circus tree, branch circus/<mission-id>
WORKTREE="$CIRCUS_WORKTREES_DIR/$MISSION_ID"
BRANCH="circus/$MISSION_ID"
log "creating worktree $WORKTREE on branch $BRANCH (from $DEFAULT_BRANCH)"
git -C "$REPO_PATH" worktree add -b "$BRANCH" "$WORKTREE" "$DEFAULT_BRANCH"

# Inject agent definitions so role discovery works from inside the worktree.
# Only needed when the worktree doesn't already have its own .claude/agents
# (e.g. non-circus repos). Absolute symlink so it resolves regardless of cwd.
if [[ ! -e "$WORKTREE/.claude/agents" ]]; then
  mkdir -p "$WORKTREE/.claude"
  ln -sf "$CIRCUS_ROOT/.claude/agents" "$WORKTREE/.claude/agents"
fi

# Identity for this repo
( cd "$WORKTREE" && apply_identity "$REPO" )

# Contributor: ensure upstream remote
if [[ "$CATEGORY" == "contributor" ]]; then
  UPSTREAM_URL=$(repo_field "$REPO" '.upstream_remote_url')
  if [[ -n "$UPSTREAM_URL" ]]; then
    if ! git -C "$WORKTREE" remote get-url upstream >/dev/null 2>&1; then
      git -C "$WORKTREE" remote add upstream "$UPSTREAM_URL"
      log "added upstream remote: $UPSTREAM_URL"
    fi
  fi
fi

# Mirror as a GitHub issue if configured
ISSUE_URL=""
ISSUE_NUMBER=""
ISSUE_NWO=""
if [[ "$ISSUES_MODE" == "mirror" ]]; then
  ISSUE_NWO=$(repo_nwo "$REPO")
  if [[ -z "$ISSUE_NWO" ]]; then
    log "WARNING: issues_mode=mirror but no nwo for $REPO — skipping issue"
  else
    log "creating mirror issue on $ISSUE_NWO"
    ISSUE_URL=$(circus_issue_create "$ISSUE_NWO" "$BRIEF_TITLE" "$BRIEF_PATH" | tail -1)
    ISSUE_NUMBER=$(printf '%s' "$ISSUE_URL" | sed -E 's|.*/issues/([0-9]+).*|\1|')
    log "issue: $ISSUE_URL"
  fi
fi

# Initial status.json (session_id filled in after dispatch)
STATUS_BLOB=$(jq -n \
  --arg repo "$REPO" \
  --arg branch "$BRANCH" \
  --arg worktree "$WORKTREE" \
  --arg session_name "$MISSION_ID" \
  --arg model "$MODEL" \
  --arg category "$CATEGORY" \
  --arg state "dispatched" \
  --arg worker_type "legman" \
  --arg issue_url "$ISSUE_URL" \
  --arg issue_nwo "$ISSUE_NWO" \
  --arg issue_number "$ISSUE_NUMBER" \
  '{repo: $repo, branch: $branch, worktree: $worktree, session_name: $session_name,
    session_id: null, model: $model, category: $category, state: $state,
    worker_type: $worker_type, pr_number: null, pr_url: null, summary: null,
    issue_url: (if $issue_url == "" then null else $issue_url end),
    issue_nwo: (if $issue_nwo == "" then null else $issue_nwo end),
    issue_number: (if $issue_number == "" then null else ($issue_number | tonumber) end)}')
status_init "$MISSION_ID" "$STATUS_BLOB"

# Stamp initial label on the issue if mirrored
if [[ -n "$ISSUE_NUMBER" && -n "$ISSUE_NWO" ]]; then
  circus_issue_relabel "$ISSUE_NWO" "$ISSUE_NUMBER" "dispatched"
fi

# Build the per-mission user prompt. The role system prompt comes from
# ~/.claude/agents/circus/legman.md (symlinked from this repo's agents/).
PROMPT=$(cat <<EOF
Mission: $MISSION_ID
Repo: $REPO ($CATEGORY)
Worktree (cwd): $WORKTREE
Branch: $BRANCH
Brief: $BRIEF_PATH
Mission dir: $M_DIR
$([[ -n "$ISSUE_URL" ]] && echo "Mirrored issue: $ISSUE_URL")

Read your brief and start work. When the PR is ready for review, run:
  $CIRCUS_ROOT/bin/worker-done.sh $MISSION_ID
EOF
)

# Pre-accept Claude Code's workspace trust for the worktree.
ensure_trusted "$WORKTREE"

# Per-mission settings file: persists the additional dir (the mission dir,
# so the worker can read its brief.md) as session config. We use this
# instead of `--add-dir` because `--add-dir` triggers an interactive
# startup dialog that hangs `claude --bg`.
SETTINGS_FILE="$M_DIR/.claude-settings.json"
jq -n --arg dir "$M_DIR" \
  '{permissions: {additionalDirectories: [$dir]}}' > "$SETTINGS_FILE"

# Dispatch via claude --bg. cd into the worktree so Claude detects it's
# already inside a linked git worktree and skips its own auto-isolation.
log "dispatching legman (model=$MODEL)"
SESSION_OUTPUT=$(
  cd "$WORKTREE" && \
  claude --bg \
    --agent legman \
    --name "$MISSION_ID" \
    --model "$MODEL" \
    --settings "$SETTINGS_FILE" \
    --dangerously-skip-permissions \
    "$PROMPT" 2>&1
)
# Strip ANSI color codes before parsing — `claude --bg` prints the session
# id wrapped in [36m...[39m, which would otherwise defeat the regex.
SESSION_ID=$(printf '%s' "$SESSION_OUTPUT" | sed -E $'s/\x1b\\[[0-9;]*m//g' | grep -oE 'backgrounded · [a-f0-9]+' | awk '{print $3}' | head -1)
if [[ -z "$SESSION_ID" ]]; then
  log "WARNING: could not parse session id from claude --bg output:"
  printf '%s\n' "$SESSION_OUTPUT" | sed 's/^/  /' >&2
fi

[[ -n "$SESSION_ID" ]] && status_set "$MISSION_ID" "session_id" "$SESSION_ID"

cat <<EOF
mission:    $MISSION_ID
session:    ${SESSION_ID:-(unknown)}
worktree:   $WORKTREE
branch:     $BRANCH
model:      $MODEL
issue:      ${ISSUE_URL:-—}

Monitor:    claude agents
Attach:     claude attach $SESSION_ID
Logs:       claude logs $SESSION_ID
EOF
