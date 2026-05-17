#!/usr/bin/env bash
# Shared helpers for circus bin/ scripts. Source this; don't run it.

set -euo pipefail

CIRCUS_ROOT="${CIRCUS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CIRCUS_STATE="${CIRCUS_STATE:-$HOME/.circus}"
CIRCUS_MISSIONS_DIR="$CIRCUS_STATE/missions"
CIRCUS_DONE_DIR="$CIRCUS_STATE/missions/done"
CIRCUS_INBOX="$CIRCUS_STATE/inbox.json"
CIRCUS_REPOS_YML="$CIRCUS_ROOT/repos.yml"

# Ensure state dirs exist on import.
mkdir -p "$CIRCUS_MISSIONS_DIR" "$CIRCUS_DONE_DIR"
[[ -f "$CIRCUS_INBOX" ]] || echo '{"missions":[]}' > "$CIRCUS_INBOX"

log() { printf '[circus] %s\n' "$*" >&2; }
die() { printf '[circus][error] %s\n' "$*" >&2; exit 1; }

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_id_stamp() { date +"%y%m%d-%H%M"; }

# slugify "Fix the foo bar" -> "fix-the-foo-bar"
slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' \
    | cut -c1-40 \
    | sed -E 's/-+$//'
}

# generate_mission_id "fix bug in reverse" -> "260517-0114-fix-bug-in-reverse"
generate_mission_id() {
  local slug
  slug=$(slugify "$1")
  [[ -n "$slug" ]] || slug="mission"
  printf '%s-%s' "$(now_id_stamp)" "$slug"
}

# Mission paths
mission_dir() { printf '%s/%s' "$CIRCUS_MISSIONS_DIR" "$1"; }
mission_status() { printf '%s/%s/status.json' "$CIRCUS_MISSIONS_DIR" "$1"; }
mission_brief() { printf '%s/%s/brief.md' "$CIRCUS_MISSIONS_DIR" "$1"; }
mission_transcript() { printf '%s/%s/transcript.log' "$CIRCUS_MISSIONS_DIR" "$1"; }
mission_summary() { printf '%s/%s/summary.md' "$CIRCUS_MISSIONS_DIR" "$1"; }

# Tmux session names
legman_session() { printf 'legman-%s' "$1"; }
watcher_session() { printf 'watcher-%s' "$1"; }
ferret_session() { printf 'ferret-%s' "$1"; }
handler_session() { printf 'handler'; }

# repo_field <name> <yaml-path>
# e.g. repo_field testbed .category
repo_field() {
  local name="$1" path="$2"
  yq -r ".repos[] | select(.name == \"$name\") | $path // \"\"" "$CIRCUS_REPOS_YML"
}

repo_exists() {
  local name="$1"
  local found
  found=$(yq -r ".repos[] | select(.name == \"$name\") | .name" "$CIRCUS_REPOS_YML")
  [[ -n "$found" ]]
}

list_repos() {
  yq -r '.repos[].name' "$CIRCUS_REPOS_YML"
}

# Status JSON helpers --------------------------------------------------------

# status_get <mission-id> <key>
status_get() {
  local id="$1" key="$2"
  jq -r ".$key // \"\"" "$(mission_status "$id")"
}

# status_set <mission-id> <key> <value>
# Strings are stored as JSON strings. Use status_set_raw for booleans/numbers/null.
status_set() {
  local id="$1" key="$2" value="$3"
  local file
  file=$(mission_status "$id")
  local tmp="$file.tmp.$$"
  jq --arg v "$value" ".$key = \$v | .last_update = \"$(now_iso)\"" "$file" > "$tmp"
  mv "$tmp" "$file"
  rebuild_inbox || true
}

# status_set_raw <mission-id> <key> <raw-json-value>
status_set_raw() {
  local id="$1" key="$2" value="$3"
  local file
  file=$(mission_status "$id")
  local tmp="$file.tmp.$$"
  jq ".$key = $value | .last_update = \"$(now_iso)\"" "$file" > "$tmp"
  mv "$tmp" "$file"
  rebuild_inbox || true
}

# status_init <mission-id> <json-blob>
# Creates the status.json with the given blob, plus standard fields.
status_init() {
  local id="$1" blob="$2"
  local file
  file=$(mission_status "$id")
  mkdir -p "$(dirname "$file")"
  jq -n --arg id "$id" --arg now "$(now_iso)" --argjson extra "$blob" \
    '$extra + {id: $id, created_at: $now, last_update: $now}' > "$file"
  rebuild_inbox || true
}

# Inbox rebuild: scan all active missions, write a flat summary.
rebuild_inbox() {
  local entries='[]'
  shopt -s nullglob
  for d in "$CIRCUS_MISSIONS_DIR"/*/; do
    [[ "$d" == "$CIRCUS_DONE_DIR/" ]] && continue
    [[ "$(basename "$d")" == "done" ]] && continue
    local f="$d/status.json"
    [[ -f "$f" ]] || continue
    entries=$(jq --slurpfile cur "$f" '. + [$cur[0]]' <<<"$entries")
  done
  shopt -u nullglob
  jq -n --argjson missions "$entries" '{missions: $missions, updated_at: "'"$(now_iso)"'"}' > "$CIRCUS_INBOX"
}

# Tmux helpers --------------------------------------------------------------

tmux_session_exists() {
  tmux has-session -t "$1" 2>/dev/null
}

# tmux_send <session> <message>
# Sends a message to a Claude session running in tmux. Uses paste-buffer for
# safety with multi-line / special-character messages, then Enter to submit.
tmux_send() {
  local session="$1" msg="$2"
  tmux_session_exists "$session" || die "no tmux session: $session"
  local buf="circus-send-$$"
  tmux set-buffer -b "$buf" -- "$msg"
  tmux paste-buffer -b "$buf" -t "$session" -p
  tmux delete-buffer -b "$buf" 2>/dev/null || true
  sleep 0.2
  tmux send-keys -t "$session" Enter
}

# tmux_capture <session> [lines]
tmux_capture() {
  local session="$1" lines="${2:-200}"
  tmux_session_exists "$session" || die "no tmux session: $session"
  tmux capture-pane -t "$session" -p -S "-$lines"
}

# auto_dismiss_trust <session> [timeout-seconds]
# When Claude starts in a fresh worktree, it shows a workspace-trust dialog
# asking the user to confirm. We poll the pane and answer "1" (trust) so
# the worker can proceed. Idempotent — bails if the dialog doesn't appear
# within the timeout (assume it's already trusted or skipped).
auto_dismiss_trust() {
  local session="$1" timeout="${2:-20}"
  local i=0
  while (( i < timeout )); do
    if tmux_session_exists "$session"; then
      local pane
      pane=$(tmux capture-pane -t "$session" -p -S -50 2>/dev/null || true)
      if printf '%s' "$pane" | grep -qi "trust this folder\|trust this workspace"; then
        tmux send-keys -t "$session" "1"
        sleep 0.1
        tmux send-keys -t "$session" Enter
        log "auto-dismissed trust dialog for $session"
        return 0
      fi
      # If the prompt is already up (we see the regular Claude UI), bail.
      if printf '%s' "$pane" | grep -qE "^[│║] "; then
        return 0
      fi
    fi
    sleep 1
    (( i += 1 )) || true
  done
  return 0
}

# Identity helpers ----------------------------------------------------------

# Apply identity (git user.name/email) for a repo in the current dir.
# Reads identity.name and identity.email from repos.yml; falls back to global.
apply_identity() {
  local repo="$1"
  local name email
  name=$(repo_field "$repo" '.identity.name')
  email=$(repo_field "$repo" '.identity.email')
  if [[ -n "$name" ]]; then
    git config user.name "$name"
  fi
  if [[ -n "$email" ]]; then
    git config user.email "$email"
  fi
}
