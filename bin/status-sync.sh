#!/usr/bin/env bash
# status-sync.sh [repo]
#
# Pushes the local status page for a repo to its GitHub wiki as Status.md.
#
#   source:   $CIRCUS_ROOT/meta/repo-status/<name>.md       (source of truth)
#   target:   $CIRCUS_ROOT/wikis/<name>/Status.md           (cloned wiki)
#   remote:   https://github.com/<nwo>.wiki.git
#
# Push-only. The local file under meta/repo-status/ is authoritative;
# this script does not pull. To bring upstream wiki edits back, do it
# by hand with `git -C wikis/<name> pull`.
#
# With no argument, syncs every repo with `status_wiki: on` in repos.yml.
# This is separate from `bin/wiki-sync.sh`, which is for the broader
# knowledge-base wiki (controlled by `wiki: true`).
#
# Bootstraps as needed:
#   - enables wikis on the repo via `gh api` if `has_wiki: false`
#   - clones wikis/<name>/ if missing
#   - aborts with a clear message if the wiki has never been initialized
#     via the web UI (GitHub only vends .wiki.git after the first page is saved)

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_lib.sh"

usage() {
  echo "usage: status-sync.sh [repo]" >&2
  echo "  with no argument, syncs every repo where status_wiki: on" >&2
  exit 1
}

# Clone wiki if it exists on the remote; bail with a helpful message if not.
bootstrap_wiki() {
  local name="$1" nwo="$2" wiki="$3"

  log "ensuring wiki is enabled on $nwo"
  gh api -X PATCH "repos/$nwo" -f has_wiki=true >/dev/null

  # Treat both a failed ls-remote AND an empty response (no refs) as
  # "wiki not initialized" — GitHub only vends the .wiki.git endpoint
  # after a human creates the first page via the web UI.
  local remote_refs
  if remote_refs=$(git ls-remote "https://github.com/$nwo.wiki.git" 2>/dev/null) \
      && [[ -n "$remote_refs" ]]; then
    log "cloning existing wiki: $nwo.wiki.git"
    git clone "https://github.com/$nwo.wiki.git" "$wiki"
    return 0
  fi

  echo "[status-sync] wiki for $nwo is not initialized." >&2
  echo "  Visit https://github.com/$nwo/wiki, click \"Create the first page\"," >&2
  echo "  save any content, then re-run \`bin/status-sync.sh $name\`." >&2
  return 1
}

sync_one() {
  local name="$1"
  repo_exists "$name" || die "no such repo: $name"

  local status_wiki
  status_wiki=$(repo_field "$name" '.status_wiki')
  if [[ "$status_wiki" != "on" ]]; then
    log "skipping $name (status_wiki: ${status_wiki:-off})"
    return 0
  fi

  local src="$CIRCUS_ROOT/meta/repo-status/$name.md"
  [[ -f "$src" ]] || die "no status page at $src"

  local nwo wiki
  nwo=$(repo_nwo "$name")
  [[ -n "$nwo" ]] || die "could not resolve nwo for $name"
  wiki="$CIRCUS_WIKIS_DIR/$name"

  if [[ ! -d "$wiki" ]]; then
    bootstrap_wiki "$name" "$nwo" "$wiki"
  fi

  cp "$src" "$wiki/Status.md"
  git -C "$wiki" add Status.md
  if git -C "$wiki" diff --cached --quiet; then
    log "$name: Status.md unchanged"
    return 0
  fi

  local iname iemail
  iname=$(repo_field "$name" '.identity.name')
  iemail=$(repo_field "$name" '.identity.email')
  git -C "$wiki" -c "user.name=$iname" -c "user.email=$iemail" \
    commit -q -m "circus: status sync $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  git -C "$wiki" push -q -u origin HEAD
  log "$name: pushed Status.md → $nwo wiki"
}

case "${1:-}" in
  -h|--help) usage;;
esac

if [[ $# -ge 1 ]]; then
  sync_one "$1"
else
  # All repos with status_wiki: on
  while read -r name; do
    [[ -n "$name" ]] && sync_one "$name"
  done < <(yq -r '.repos[] | select(.status_wiki == "on") | .name' "$CIRCUS_REPOS_YML")
fi
