#!/usr/bin/env bash
# Verify that generate_mission_id() returns unique ids even when called
# rapidly in a tight loop (sub-second bursts with the same question text).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CIRCUS_ROOT="$TMP"
mkdir -p "$TMP/missions"

# shellcheck source=../bin/_lib.sh
source "$HERE/bin/_lib.sh"

ids=()
for i in 1 2 3 4 5; do
  ids+=("$(generate_mission_id 'same question text')")
done

n_unique=$(printf '%s\n' "${ids[@]}" | sort -u | wc -l | tr -d ' ')
if [[ "$n_unique" != "5" ]]; then
  echo "FAIL: expected 5 unique ids, got $n_unique:"
  printf '%s\n' "${ids[@]}"
  exit 1
fi
echo "collision test ok"
