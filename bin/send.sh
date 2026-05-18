#!/usr/bin/env bash
# send.sh <session-or-mission-id> <message>
#
# Sends a message into a worker's Claude prompt and submits it.
# Accepts either a full tmux session name (legman-*, watcher-*, ferret-*) or
# a bare mission id (and assumes legman-).

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_lib.sh"

[[ $# -ge 2 ]] || { echo "usage: send.sh <session-or-mission-id> <message>" >&2; exit 1; }

TARGET="$1"; shift
MSG="$*"

if [[ "$TARGET" == handler || "$TARGET" == handler-* ]]; then
  die "refusing to send-keys to handler — the handler reads inbox.jsonl on demand"
fi
if [[ "$TARGET" != legman-* && "$TARGET" != watcher-* && "$TARGET" != ferret-* ]]; then
  TARGET="legman-$TARGET"
fi

tmux_send "$TARGET" "$MSG"
log "sent to $TARGET: ${MSG:0:80}$([ ${#MSG} -gt 80 ] && echo ...)"
