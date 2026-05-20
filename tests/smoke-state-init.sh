#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CIRCUS_ROOT="$TMP"
mkdir -p "$TMP/missions"

# shellcheck source=../bin/_lib.sh
source "$HERE/bin/_lib.sh"

# Override after sourcing — _lib.sh unconditionally sets CIRCUS_REPOS_YML=$CIRCUS_ROOT/repos.yml
CIRCUS_REPOS_YML="$HERE/repos.yml"

# generate_mission_id: shape check
id=$(generate_mission_id "smoke test")
[[ "$id" =~ ^[0-9]{6}-[0-9]{4}-.+$ ]] || { echo "bad id: $id"; exit 1; }

# status_init creates a valid JSON file
status_init "$id" '{"hello":"world"}'
[[ -f "$(mission_status "$id")" ]] || { echo "no status.json created"; exit 1; }
jq . "$(mission_status "$id")" >/dev/null

# repo_field reads repos.yml correctly
cat=$(repo_field "circus-screeps" '.category')
[[ "$cat" == "owned" ]] || { echo "circus-screeps category wrong: $cat"; exit 1; }

echo "smoke ok"
