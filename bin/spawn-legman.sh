#!/usr/bin/env bash
# spawn-legman.sh <repo> <brief-path> [--model X] [--attach]
#
# Spawns a legman (coding worker) on a repo. Creates a worktree, configures
# identity + remotes, wires up the Stop hook, writes initial status, starts
# a detached tmux session running Claude in interactive mode, optionally
# attaches a Terminal.app window.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_lib.sh"

usage() {
  cat <<'EOF' >&2
usage: spawn-legman.sh <repo> <brief-path> [--model X] [--attach]
  repo         Name of the repo as registered in repos.yml
  brief-path   Path to a markdown file describing the mission
  --model X    Claude model (default: claude-sonnet-4-6)
  --attach     Open a Terminal.app window attached to the tmux session
EOF
  exit 1
}

[[ $# -ge 2 ]] || usage
REPO="$1"; BRIEF_SRC="$2"; shift 2
MODEL="claude-sonnet-4-6"
ATTACH=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL="$2"; shift 2;;
    --attach) ATTACH=1; shift;;
    *) usage;;
  esac
done

repo_exists "$REPO" || die "repo not found in repos.yml: $REPO"
[[ -f "$BRIEF_SRC" ]] || die "brief not found: $BRIEF_SRC"

REPO_PATH=$(repo_field "$REPO" '.path')
WORKTREE_ROOT=$(repo_field "$REPO" '.worktree_root')
CATEGORY=$(repo_field "$REPO" '.category')
DEFAULT_BRANCH=$(repo_field "$REPO" '.default_branch')
[[ -n "$DEFAULT_BRANCH" ]] || DEFAULT_BRANCH="main"

[[ "$CATEGORY" == "reference" ]] && die "cannot spawn a legman on a reference repo: $REPO"
[[ -d "$REPO_PATH" ]] || die "repo path missing on disk: $REPO_PATH"
[[ -n "$WORKTREE_ROOT" ]] || die "worktree_root not set in repos.yml for: $REPO"

# Generate mission id from brief's first heading or first line.
BRIEF_TITLE=$(head -n 1 "$BRIEF_SRC" | sed -E 's/^#+ *//')
[[ -n "$BRIEF_TITLE" ]] || BRIEF_TITLE="mission"
MISSION_ID=$(generate_mission_id "$BRIEF_TITLE")
M_DIR=$(mission_dir "$MISSION_ID")
mkdir -p "$M_DIR"
cp "$BRIEF_SRC" "$M_DIR/brief.md"

# Create the worktree
mkdir -p "$WORKTREE_ROOT"
WORKTREE="$WORKTREE_ROOT/$MISSION_ID"
BRANCH="circus/$MISSION_ID"
log "creating worktree $WORKTREE on branch $BRANCH (from $DEFAULT_BRANCH)"
git -C "$REPO_PATH" worktree add -b "$BRANCH" "$WORKTREE" "$DEFAULT_BRANCH"

# Apply identity if set
( cd "$WORKTREE" && apply_identity "$REPO" )

# For contributor repos, ensure the upstream remote is set up
if [[ "$CATEGORY" == "contributor" ]]; then
  UPSTREAM_URL=$(repo_field "$REPO" '.upstream_remote_url')
  if [[ -n "$UPSTREAM_URL" ]]; then
    if ! git -C "$WORKTREE" remote get-url upstream >/dev/null 2>&1; then
      git -C "$WORKTREE" remote add upstream "$UPSTREAM_URL"
      log "added upstream remote: $UPSTREAM_URL"
    fi
  fi
fi

# Wire up the Stop hook in this worktree's .claude/settings.local.json
mkdir -p "$WORKTREE/.claude"
cat > "$WORKTREE/.claude/settings.local.json" <<JSON
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "$CIRCUS_ROOT/hooks/worker-stop.sh $MISSION_ID legman"
          }
        ]
      }
    ]
  }
}
JSON

# Initial status.json
STATUS_BLOB=$(jq -n \
  --arg repo "$REPO" \
  --arg branch "$BRANCH" \
  --arg worktree "$WORKTREE" \
  --arg session "$(legman_session "$MISSION_ID")" \
  --arg model "$MODEL" \
  --arg category "$CATEGORY" \
  --arg state "dispatched" \
  --arg worker_type "legman" \
  '{repo: $repo, branch: $branch, worktree: $worktree, tmux_session: $session,
    model: $model, category: $category, state: $state, worker_type: $worker_type,
    pr_number: null, pr_url: null, summary: null}')
status_init "$MISSION_ID" "$STATUS_BLOB"

# Bootstrap prompt for the worker
SESSION=$(legman_session "$MISSION_ID")

# Write the bootstrap prompt to a file for the launcher to read; avoids
# shell-quoting hell when the prompt contains backticks, quotes, etc.
PROMPT_FILE="$M_DIR/bootstrap.prompt"
cat > "$PROMPT_FILE" <<PROMPT
You are a legman in circus on mission $MISSION_ID.

Repo: $REPO
Category: $CATEGORY
Worktree (your cwd): $WORKTREE
Branch you are on: $BRANCH
Brief: $M_DIR/brief.md

Read your brief now and start work.

Constraints:
- Stay on this branch ($BRANCH). Do not switch branches.
- Commit incrementally as you go (small, focused commits). Identity is already configured for this repo.
- When the code is ready for review, run:
    $CIRCUS_ROOT/bin/worker-done.sh $MISSION_ID
  That pushes the branch, opens the PR, and notifies the handler.
- After that, idle in this session. The handler or watcher may send you review notes — address them, push again, and the same script is safe to re-run.
- If you have a question you cannot answer from the project, say so plainly in your next message. Your Stop hook forwards it to the handler.

The mission's CLAUDE.md and any repo-level CLAUDE.md will be auto-loaded. The brief is the source of truth for the task.
PROMPT

# Per-mission launcher (avoids re-quoting issues every time)
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

# Launch tmux session running the launcher
log "starting tmux session: $SESSION"
tmux new-session -d -s "$SESSION" -c "$WORKTREE" "$LAUNCH_FILE"
auto_dismiss_trust "$SESSION"

# Optional Terminal.app attach
if [[ "$ATTACH" -eq 1 ]]; then
  "$HERE/attach-window.sh" "$SESSION"
fi

cat <<EOF
mission:  $MISSION_ID
session:  $SESSION
worktree: $WORKTREE
branch:   $BRANCH
model:    $MODEL
EOF
