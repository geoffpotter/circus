#!/usr/bin/env bash
# wiki-sync.sh [repo-name]
#
# Pulls (and pushes if there are local commits) each cloned wiki. With no
# args, syncs every repo whose `wiki: true` in repos.yml.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_lib.sh"

sync_one() {
  local name="$1"
  local dir="$CIRCUS_WIKIS_DIR/$name"
  if [[ ! -d "$dir/.git" ]]; then
    log "skip $name: no wiki clone at $dir"
    return 0
  fi
  log "syncing wiki: $name"
  (
    cd "$dir"
    git pull --rebase --autostash 2>&1 | sed 's/^/  /'
    # Only push if there are local commits ahead of origin
    if git log @{u}..HEAD --oneline 2>/dev/null | grep -q .; then
      git push 2>&1 | sed 's/^/  /'
    fi
  )
}

if [[ $# -ge 1 ]]; then
  NAME="$1"
  repo_exists "$NAME" || die "no such repo: $NAME"
  sync_one "$NAME"
else
  # Iterate over repos with wiki: true
  while IFS= read -r name; do
    [[ -n "$name" ]] && sync_one "$name"
  done < <(yq -r '.repos[] | select(.wiki == true) | .name' "$CIRCUS_REPOS_YML")
fi
