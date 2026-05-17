#!/usr/bin/env bash
# attach-window.sh <session>
#
# Opens a new Terminal.app window attached to the given tmux session.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_lib.sh"

[[ $# -ge 1 ]] || { echo "usage: attach-window.sh <session>" >&2; exit 1; }
SESSION="$1"

tmux_session_exists "$SESSION" || die "no tmux session: $SESSION"

# Escape session name for AppleScript (paranoia)
SAFE_SESSION=$(printf '%s' "$SESSION" | sed 's/"/\\"/g')

osascript <<APPLESCRIPT
tell application "Terminal"
  activate
  do script "tmux attach -t \"$SAFE_SESSION\""
end tell
APPLESCRIPT
