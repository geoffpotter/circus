#!/usr/bin/env bash
# Shared helpers for circus bin/ scripts. Source this; don't run it.
#
# This file is meant to be sourced by bash scripts in bin/. It deliberately
# does NOT call `set -e`, etc. — caller scripts set their own modes. That
# also means the file can be sourced from a zsh shell (e.g. inside a Claude
# session) without nuking the user's shell options.

# Resolve our own location (works when sourced from bash). Fall back to
# CIRCUS_ROOT env or a hard-coded sensible path.
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  _CIRCUS_LIB_PATH="${BASH_SOURCE[0]}"
fi
CIRCUS_ROOT="${CIRCUS_ROOT:-$(cd "$(dirname "${_CIRCUS_LIB_PATH:-$0}")/.." 2>/dev/null && pwd || echo "$HOME/code/circus")}"
# Everything lives under CIRCUS_ROOT so a single grep finds it all.
CIRCUS_MISSIONS_DIR="$CIRCUS_ROOT/missions"
CIRCUS_DONE_DIR="$CIRCUS_ROOT/missions/done"
CIRCUS_WORKTREES_DIR="$CIRCUS_ROOT/worktrees"
CIRCUS_REPOS_DIR="$CIRCUS_ROOT/repos"
CIRCUS_WIKIS_DIR="$CIRCUS_ROOT/wikis"
CIRCUS_INBOX="$CIRCUS_ROOT/inbox.json"
CIRCUS_INBOX_LOG="$CIRCUS_ROOT/inbox.jsonl"
CIRCUS_REPOS_YML="$CIRCUS_ROOT/repos.yml"

# Ensure state dirs exist on import.
mkdir -p "$CIRCUS_MISSIONS_DIR" "$CIRCUS_DONE_DIR" "$CIRCUS_WORKTREES_DIR" "$CIRCUS_REPOS_DIR" "$CIRCUS_WIKIS_DIR"
[[ -f "$CIRCUS_INBOX" ]] || echo '{"missions":[]}' > "$CIRCUS_INBOX"
[[ -f "$CIRCUS_INBOX_LOG" ]] || : > "$CIRCUS_INBOX_LOG"

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

# Repo's working checkout path. Defaults to $CIRCUS_REPOS_DIR/<name> if not
# explicitly set in repos.yml.
repo_path() {
  local name="$1"
  local p
  p=$(repo_field "$name" '.path')
  if [[ -z "$p" || "$p" == "null" ]]; then
    p="$CIRCUS_REPOS_DIR/$name"
  fi
  printf '%s' "$p"
}

# Repo's worktree root. Defaults to $CIRCUS_WORKTREES_DIR (shared) but a repo
# can override with its own worktree_root.
repo_worktree_root() {
  local name="$1"
  local p
  p=$(repo_field "$name" '.worktree_root')
  if [[ -z "$p" || "$p" == "null" ]]; then
    p="$CIRCUS_WORKTREES_DIR"
  fi
  printf '%s' "$p"
}

# Repo's NWO (owner/repo) for gh commands. Reads from repos.yml; falls back
# to introspecting the repo's origin remote if not set.
repo_nwo() {
  local name="$1"
  local nwo
  nwo=$(repo_field "$name" '.nwo')
  if [[ -z "$nwo" || "$nwo" == "null" ]]; then
    local p
    p=$(repo_path "$name")
    if [[ -d "$p/.git" || -f "$p/.git" ]]; then
      nwo=$(git -C "$p" remote get-url origin 2>/dev/null \
        | sed -E 's|^git@github\.com:|https://github.com/|; s|\.git$||; s|^https?://[^/]+/||')
    fi
  fi
  printf '%s' "$nwo"
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
  local entries='[]' f
  # `find` is portable (vs bash-only shopt nullglob); -maxdepth keeps it shallow.
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    entries=$(jq --slurpfile cur "$f" '. + [$cur[0]]' <<<"$entries")
  done < <(find "$CIRCUS_MISSIONS_DIR" -maxdepth 2 -type f -name status.json -not -path "$CIRCUS_DONE_DIR/*" 2>/dev/null)
  jq -n --argjson missions "$entries" --arg now "$(now_iso)" '{missions: $missions, updated_at: $now}' > "$CIRCUS_INBOX"
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

# Handler comms -------------------------------------------------------------

# notify_handler <mission-id> <kind> <message>
# Appends a JSONL line to inbox.jsonl and (best-effort) fires a macOS
# notification. Never uses tmux send-keys against the handler — the handler
# reads its inbox on demand.
#
# kind is a short tag, used for the macOS notification subtitle and for
# downstream filtering. Examples: turn-end, pr-ready, review-changes,
# review-approve, error.
notify_handler() {
  local mission_id="$1" kind="$2" msg="$3"
  local line
  line=$(jq -cn \
    --arg id "$mission_id" \
    --arg kind "$kind" \
    --arg msg "$msg" \
    --arg ts "$(now_iso)" \
    '{ts: $ts, mission: $id, kind: $kind, message: $msg}')
  printf '%s\n' "$line" >> "$CIRCUS_INBOX_LOG"

  # macOS notification (silent if osascript unavailable / not on macOS).
  if command -v osascript >/dev/null 2>&1; then
    local safe_msg safe_sub
    safe_msg=$(printf '%s' "$msg" | head -c 200 | tr -d '\n' | sed 's/"/\\"/g')
    safe_sub=$(printf '%s — %s' "$kind" "$mission_id" | sed 's/"/\\"/g')
    osascript -e "display notification \"$safe_msg\" with title \"circus\" subtitle \"$safe_sub\"" 2>/dev/null || true
  fi
}

# GitHub issue mirror -------------------------------------------------------
#
# When repos.yml sets issues_mode: mirror, a mission also gets a GitHub
# issue in the target repo. The local brief is still the source of truth;
# the issue is the *external surface* for collaborators / mobile / audit.

# circus_label_set <nwo> <label>
# Ensures a `circus/<state>` label exists in the repo. Idempotent.
circus_label_ensure() {
  local nwo="$1" label="$2"
  # `gh label create` errors if it already exists; suppress.
  gh label create "$label" --repo "$nwo" --color "ededed" --description "circus mission state" 2>/dev/null || true
}

# circus_issue_create <nwo> <title> <body-file> -> prints issue url, then number
circus_issue_create() {
  local nwo="$1" title="$2" body_file="$3"
  circus_label_ensure "$nwo" "circus"
  local url
  url=$(gh issue create --repo "$nwo" --title "$title" --body-file "$body_file" --label circus)
  printf '%s\n' "$url"
}

# circus_issue_relabel <nwo> <issue-number> <new-state>
# Strips any circus/state:* label, adds circus/state:<new-state>.
circus_issue_relabel() {
  local nwo="$1" num="$2" state="$3"
  local new_label="circus/state:$state"
  circus_label_ensure "$nwo" "$new_label"
  # Remove any prior circus/state:* labels.
  local cur
  cur=$(gh issue view "$num" --repo "$nwo" --json labels --jq '.labels[].name' 2>/dev/null | grep '^circus/state:' || true)
  while IFS= read -r old; do
    [[ -n "$old" && "$old" != "$new_label" ]] && gh issue edit "$num" --repo "$nwo" --remove-label "$old" >/dev/null 2>&1 || true
  done <<<"$cur"
  gh issue edit "$num" --repo "$nwo" --add-label "$new_label" >/dev/null 2>&1 || true
}

# Update mission state AND mirror to issue label if the mission has one.
status_set_state() {
  local id="$1" new_state="$2"
  status_set "$id" "state" "$new_state"
  local sf nwo num
  sf=$(mission_status "$id")
  nwo=$(jq -r '.issue_nwo // ""' "$sf")
  num=$(jq -r '.issue_number // ""' "$sf")
  if [[ -n "$nwo" && -n "$num" && "$nwo" != "null" && "$num" != "null" ]]; then
    circus_issue_relabel "$nwo" "$num" "$new_state" || true
  fi
}

# Close the GH issue tied to a mission, if any.
status_close_issue() {
  local id="$1" comment="${2:-}"
  local sf nwo num
  sf=$(mission_status "$id")
  nwo=$(jq -r '.issue_nwo // ""' "$sf")
  num=$(jq -r '.issue_number // ""' "$sf")
  if [[ -n "$nwo" && -n "$num" && "$nwo" != "null" && "$num" != "null" ]]; then
    if [[ -n "$comment" ]]; then
      gh issue comment "$num" --repo "$nwo" --body "$comment" >/dev/null 2>&1 || true
    fi
    gh issue close "$num" --repo "$nwo" >/dev/null 2>&1 || true
  fi
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
