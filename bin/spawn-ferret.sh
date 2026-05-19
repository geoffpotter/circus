#!/usr/bin/env bash
# spawn-ferret.sh <roots> <question> [--model X]
#
# Dispatches a ferret background session via `claude --bg --agent ferret`.
# No worktree, no PR, no branch. Ferret writes findings to:
#   $CIRCUS_ROOT/missions/<id>/findings.md
# then prints DONE and stops.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_lib.sh"

usage() {
  cat <<'EOF' >&2
usage: spawn-ferret.sh <roots> <question> [--model X]
  roots      Comma-separated repo names (from repos.yml) OR absolute paths.
             First one becomes cwd; the rest are added via --add-dir.
  question   Research question (free text).
  --model    Default: haiku
EOF
  exit 1
}

[[ $# -ge 2 ]] || usage
ROOTS_CSV="$1"; QUESTION="$2"; shift 2
MODEL="haiku"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL="$2"; shift 2;;
    *) usage;;
  esac
done

# Resolve roots
ROOTS=()
IFS=',' read -ra TOKENS <<<"$ROOTS_CSV"
for tok in "${TOKENS[@]}"; do
  tok="${tok// /}"
  if [[ "$tok" == /* ]]; then
    ROOTS+=("$tok")
  elif repo_exists "$tok"; then
    ROOTS+=("$(repo_path "$tok")")
  else
    die "unknown root: $tok (not a repo name in repos.yml and not an absolute path)"
  fi
done
[[ "${#ROOTS[@]}" -gt 0 ]] || die "no roots resolved"
CWD="${ROOTS[0]}"

MISSION_ID=$(generate_mission_id "$QUESTION")
M_DIR=$(mission_dir "$MISSION_ID")
mkdir -p "$M_DIR"
FINDINGS_PATH="$M_DIR/findings.md"

# Brief = the question for audit
{
  echo "# $QUESTION"
  echo
  echo "Roots searched:"
  for r in "${ROOTS[@]}"; do echo "  - $r"; done
} > "$M_DIR/brief.md"

STATUS_BLOB=$(jq -n \
  --arg session_name "$MISSION_ID" \
  --arg model "$MODEL" \
  --arg state "dispatched" \
  --arg worker_type "ferret" \
  --arg q "$QUESTION" \
  '{session_name: $session_name, session_id: null, model: $model, state: $state,
    worker_type: $worker_type, repo: "(ferret)", question: $q, findings: null}')
status_init "$MISSION_ID" "$STATUS_BLOB"

# Build prompt + add-dir args
ROOTS_LIST=""
for r in "${ROOTS[@]}"; do
  ROOTS_LIST+="  - $r"$'\n'
done

PROMPT=$(cat <<EOF
Mission: $MISSION_ID
Question: $QUESTION
Findings path (write your answer here): $FINDINGS_PATH

Search roots (read-only; cwd is the first):
$ROOTS_LIST
Investigate, write a tight findings note per your role instructions,
print "DONE" and stop.
EOF
)

ADD_DIR_ARGS=( "--add-dir" "$M_DIR" )
for r in "${ROOTS[@]}"; do
  ADD_DIR_ARGS+=( "--add-dir" "$r" )
done

ensure_trusted "$CWD"
for r in "${ROOTS[@]}"; do ensure_trusted "$r"; done

log "dispatching ferret (model=$MODEL)"
SESSION_OUTPUT=$(
  cd "$CWD" && \
  claude --bg \
    --agent ferret \
    --name "$MISSION_ID" \
    --model "$MODEL" \
    --dangerously-skip-permissions \
    "${ADD_DIR_ARGS[@]}" \
    "$PROMPT" 2>&1
)
SESSION_ID=$(printf '%s' "$SESSION_OUTPUT" | grep -oE 'backgrounded · [a-f0-9]+' | awk '{print $3}' | head -1)
if [[ -z "$SESSION_ID" ]]; then
  log "WARNING: could not parse session id from claude --bg output:"
  printf '%s\n' "$SESSION_OUTPUT" | sed 's/^/  /' >&2
fi

[[ -n "$SESSION_ID" ]] && status_set "$MISSION_ID" "session_id" "$SESSION_ID"

cat <<EOF
mission:    $MISSION_ID
session:    ${SESSION_ID:-(unknown)}
findings:   $FINDINGS_PATH
model:      $MODEL

Monitor:    claude agents
Logs:       claude logs $SESSION_ID
EOF
