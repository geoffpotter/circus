#!/usr/bin/env bash
# wiki-clone.sh <repo-name>
#
# Clones a registered repo's GitHub wiki into $CIRCUS_ROOT/wikis/<name>/.
# Useful when:
#   - The wiki was empty at add-repo time and you've since created the
#     Home page on GitHub
#   - You enabled the wiki on an existing registered repo and want it local

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_lib.sh"

[[ $# -ge 1 ]] || { echo "usage: wiki-clone.sh <repo-name>" >&2; exit 1; }
NAME="$1"
repo_exists "$NAME" || die "no such repo: $NAME"
NWO=$(repo_nwo "$NAME")
[[ -n "$NWO" ]] || die "could not resolve nwo for $NAME"

DEST="$CIRCUS_WIKIS_DIR/$NAME"
[[ -e "$DEST" ]] && die "already exists: $DEST"

WIKI_URL="https://github.com/${NWO}.wiki.git"
log "cloning wiki: $WIKI_URL -> $DEST"
if ! git clone "$WIKI_URL" "$DEST"; then
  die "wiki clone failed. The wiki may be disabled, or empty (create Home.md on github.com/$NWO/wiki first)."
fi

# Flip wiki: true in repos.yml. Best-effort sed; if it fails, tell the user.
if grep -q "  - name: $NAME$" "$CIRCUS_REPOS_YML"; then
  # awk replacement to set wiki: true within the matching repo block.
  TMP="$CIRCUS_REPOS_YML.tmp.$$"
  awk -v target="$NAME" '
    BEGIN { in_block = 0 }
    /^  - name: / {
      in_block = ($0 == "  - name: " target)
    }
    in_block && /^    wiki: / { print "    wiki: true"; next }
    { print }
  ' "$CIRCUS_REPOS_YML" > "$TMP"
  mv "$TMP" "$CIRCUS_REPOS_YML"
  log "set wiki: true for $NAME in repos.yml"
else
  log "WARNING: could not locate $NAME entry to update wiki: field — set it manually."
fi

echo "wiki cloned: $DEST"
