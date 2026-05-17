#!/usr/bin/env bash
# capture.sh <session-or-mission-id> [lines]
#
# Captures the recent pane output of a worker's tmux session.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_lib.sh"

[[ $# -ge 1 ]] || { echo "usage: capture.sh <session-or-mission-id> [lines]" >&2; exit 1; }

TARGET="$1"
LINES="${2:-200}"

if [[ "$TARGET" != legman-* && "$TARGET" != watcher-* && "$TARGET" != ferret-* && "$TARGET" != handler ]]; then
  TARGET="legman-$TARGET"
fi

tmux_capture "$TARGET" "$LINES"
