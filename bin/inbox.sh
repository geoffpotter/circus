#!/usr/bin/env bash
# inbox.sh
#
# Prints a one-line summary per active mission.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_lib.sh"

rebuild_inbox

COUNT=$(jq '.missions | length' "$CIRCUS_INBOX")
if [[ "$COUNT" -eq 0 ]]; then
  echo "(no active missions)"
  exit 0
fi

jq -r '.missions[] | "\(.id)  [\(.state)]  \(.worker_type) \(.repo)  model=\(.model)  pr=\(.pr_url // "—")"' "$CIRCUS_INBOX"
