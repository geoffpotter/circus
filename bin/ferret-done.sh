#!/usr/bin/env bash
# ferret-done.sh <mission-id>
#
# Called by a ferret after writing its findings note. Verifies findings.md
# exists, transitions the mission to findings_ready, and notifies the handler
# via the inbox so inbox-watch.sh auto-resumes the handler.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_lib.sh"

[[ $# -ge 1 ]] || { echo "usage: ferret-done.sh <mission-id>" >&2; exit 1; }
MISSION_ID="$1"
STATUS_FILE=$(mission_status "$MISSION_ID")
[[ -f "$STATUS_FILE" ]] || die "no mission: $MISSION_ID"

M_DIR=$(mission_dir "$MISSION_ID")
FINDINGS_PATH="$M_DIR/findings.md"
[[ -f "$FINDINGS_PATH" ]] || die "findings.md missing at $FINDINGS_PATH — write it before calling ferret-done.sh"

status_set_state "$MISSION_ID" "findings_ready"

notify_handler "$MISSION_ID" "ferret-done" "findings ready: $FINDINGS_PATH"

cat <<EOF
mission:   $MISSION_ID
state:     findings_ready
findings:  $FINDINGS_PATH
EOF
