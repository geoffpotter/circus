#!/usr/bin/env bash
# handler.sh
#
# Opens (or re-attaches to) the handler's Claude session inside a tmux
# session named 'handler'. Running inside this session means:
#   - bin/send.sh targeting 'handler' is rejected (we don't send-keys you)
#   - the session name is stable for any future tooling that wants it
#   - you can detach (Ctrl-b d) and reattach from anywhere
#
# Worker Stop hooks never inject text into your pane — they append to
# inbox.jsonl + fire a macOS notification. Read with: bin/inbox.sh

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_lib.sh"

# Allow passing extra args through to claude (e.g. --resume, --model)
exec tmux new-session -A -s handler -c "$CIRCUS_ROOT" "claude $*"
