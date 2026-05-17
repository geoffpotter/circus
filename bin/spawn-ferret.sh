#!/usr/bin/env bash
# spawn-ferret.sh <repo-csv-or-roots> <question> [--model X]
#
# Spawn a ferret (research worker). Ferret reads from one or more repos
# (or arbitrary roots) and writes findings to ~/.circus/missions/<id>/findings.md
# then exits. No worktree, no PR, no branch.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_lib.sh"

usage() {
  cat <<'EOF' >&2
usage: spawn-ferret.sh <roots> <question> [--model X] [--attach]
  roots      Comma-separated repo names (from repos.yml) OR absolute paths.
             Mix is fine. The first one becomes the ferret's cwd.
  question   The research question (free text).
  --model    Default: claude-haiku-4-5-20251001 (ferrets are usually cheap)
EOF
  exit 1
}

[[ $# -ge 2 ]] || usage
ROOTS_CSV="$1"; QUESTION="$2"; shift 2
MODEL="claude-haiku-4-5-20251001"
ATTACH=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL="$2"; shift 2;;
    --attach) ATTACH=1; shift;;
    *) usage;;
  esac
done

# Resolve roots to absolute paths
ROOTS=()
IFS=',' read -ra TOKENS <<<"$ROOTS_CSV"
for tok in "${TOKENS[@]}"; do
  tok="${tok// /}"
  if [[ "$tok" == /* ]]; then
    ROOTS+=("$tok")
  elif repo_exists "$tok"; then
    p=$(repo_field "$tok" '.path')
    ROOTS+=("$p")
  else
    die "unknown root: $tok (not a repo name in repos.yml and not an absolute path)"
  fi
done
[[ "${#ROOTS[@]}" -gt 0 ]] || die "no roots resolved"
CWD="${ROOTS[0]}"

MISSION_ID=$(generate_mission_id "$QUESTION")
M_DIR=$(mission_dir "$MISSION_ID")
mkdir -p "$M_DIR"

# Brief is just the question for a ferret
{
  echo "# $QUESTION"
  echo
  echo "Roots searched:"
  for r in "${ROOTS[@]}"; do echo "  - $r"; done
} > "$M_DIR/brief.md"

# Initial status
STATUS_BLOB=$(jq -n \
  --arg session "$(ferret_session "$MISSION_ID")" \
  --arg model "$MODEL" \
  --arg state "dispatched" \
  --arg worker_type "ferret" \
  --arg q "$QUESTION" \
  '{tmux_session: $session, model: $model, state: $state, worker_type: $worker_type,
    repo: "(ferret)", question: $q, findings: null}')
status_init "$MISSION_ID" "$STATUS_BLOB"

# Wire up Stop hook into the cwd's .claude/settings.local.json — but careful,
# the ferret runs in an existing repo so we shouldn't pollute its .claude/.
# Use a project-local settings file at $M_DIR/.claude/settings.local.json
# and --add-dir to bring it in, OR pass --settings via the cli. Safest: a
# dedicated settings file passed via --settings.
SETTINGS_FILE="$M_DIR/settings.local.json"
cat > "$SETTINGS_FILE" <<JSON
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "$CIRCUS_ROOT/hooks/worker-stop.sh $MISSION_ID ferret"
          }
        ]
      }
    ]
  }
}
JSON

# Assemble --add-dir args
ADD_DIRS=( "--add-dir" "$M_DIR" )
for r in "${ROOTS[@]}"; do
  ADD_DIRS+=( "--add-dir" "$r" )
done

SESSION=$(ferret_session "$MISSION_ID")
FINDINGS_PATH="$M_DIR/findings.md"
PROMPT_FILE="$M_DIR/ferret.prompt"
{
  echo "You are a ferret in circus on mission $MISSION_ID."
  echo
  echo "Question: $QUESTION"
  echo
  echo "Search roots (read-only):"
  for r in "${ROOTS[@]}"; do echo "  - $r"; done
  cat <<PROMPT

Your job:
1. Investigate the question. Grep/Read across the roots above.
2. Write a tight findings note to: $FINDINGS_PATH
   - Lead with a one-paragraph answer.
   - Then list specific file paths and line numbers that support the answer.
   - Be concise. The handler reads this; don't include a wall of code.
3. Print "DONE" and stop.

You do not write code, open PRs, or modify any repo. Read-only research only.
PROMPT
} > "$PROMPT_FILE"

# Build add-dir args list for launcher
LAUNCH_FILE="$M_DIR/ferret-launch.sh"
{
  echo "#!/usr/bin/env bash"
  echo "set -e"
  echo "cd \"$CWD\""
  echo "exec claude --dangerously-skip-permissions \\"
  echo "  --model \"$MODEL\" \\"
  echo "  --settings \"$SETTINGS_FILE\" \\"
  for r in "${ROOTS[@]}"; do
    echo "  --add-dir \"$r\" \\"
  done
  echo "  --add-dir \"$M_DIR\" \\"
  echo "  -n \"$SESSION\" \\"
  echo "  \"\$(cat \"$PROMPT_FILE\")\""
} > "$LAUNCH_FILE"
chmod +x "$LAUNCH_FILE"

log "starting ferret tmux session: $SESSION"
tmux new-session -d -s "$SESSION" -c "$CWD" "$LAUNCH_FILE"
auto_dismiss_trust "$SESSION"

if [[ "$ATTACH" -eq 1 ]]; then
  "$HERE/attach-window.sh" "$SESSION"
fi

cat <<EOF
mission:  $MISSION_ID
session:  $SESSION
findings: $FINDINGS_PATH
model:    $MODEL
EOF
