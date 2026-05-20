#!/usr/bin/env bash
# add-repo.sh <github-url-or-nwo> [--name <local-name>] \
#             [--category owned|contributor|reference] \
#             [--issues-mode local|mirror] \
#             [--upstream-pr from_fork|branch_on_upstream] \
#             [--upstream-url <url>]
#
# Clones a GitHub repo into $CIRCUS_ROOT/repos/<name>/ (owned/contributor) or
# $CIRCUS_ROOT/references/<name>/ (reference), tries to clone the
# wiki into $CIRCUS_ROOT/wikis/<name>/ if the wiki is enabled, then appends
# a stub entry to repos.yml. Does NOT change any GitHub settings.
#
# Acceptable URL forms:
#   git@github.com:owner/repo.git
#   https://github.com/owner/repo.git
#   https://github.com/owner/repo
#   owner/repo
#
# Relies on `repos:` being the last top-level key in repos.yml so a plain
# YAML append lands inside the list. add-repo.sh is the only thing that
# writes repos.yml; if you hand-edit, keep that invariant.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_lib.sh"

usage() {
  cat <<'EOF' >&2
usage: add-repo.sh <url-or-nwo> [opts]
  --name        Local name (default: repo name from URL)
  --category    owned | contributor | reference   (default: owned)
  --issues-mode local | mirror                    (default: local)
  --upstream-pr from_fork | branch_on_upstream    (contributor only)
  --upstream-url <url>                            (contributor only)
EOF
  exit 1
}

[[ $# -ge 1 ]] || usage
SRC="$1"; shift

NAME=""
CATEGORY="owned"
ISSUES_MODE="local"
UPSTREAM_PR=""
UPSTREAM_URL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)         NAME="$2"; shift 2;;
    --category)     CATEGORY="$2"; shift 2;;
    --issues-mode)  ISSUES_MODE="$2"; shift 2;;
    --upstream-pr)  UPSTREAM_PR="$2"; shift 2;;
    --upstream-url) UPSTREAM_URL="$2"; shift 2;;
    *) usage;;
  esac
done

# Normalize SRC to owner/repo (NWO) and a clone URL.
NWO=""
CLONE_URL=""
case "$SRC" in
  git@github.com:*)
    NWO="${SRC#git@github.com:}"
    NWO="${NWO%.git}"
    CLONE_URL="$SRC"
    ;;
  https://github.com/*|http://github.com/*)
    NWO="${SRC#http*://github.com/}"
    NWO="${NWO%.git}"
    NWO="${NWO%/}"
    CLONE_URL="https://github.com/${NWO}.git"
    ;;
  */*)
    NWO="$SRC"
    CLONE_URL="https://github.com/${NWO}.git"
    ;;
  *) die "could not parse: $SRC (try owner/repo or a github URL)";;
esac

[[ "$NWO" == */* ]] || die "expected owner/repo, got: $NWO"
[[ -z "$NAME" ]] && NAME="${NWO##*/}"

if repo_exists "$NAME"; then
  die "repo named '$NAME' already in repos.yml"
fi

# Sanity check repos.yml invariant
LAST_TOP=$(grep -E '^[a-z][a-z_]*:' "$CIRCUS_REPOS_YML" | tail -1 | sed 's/:.*//')
if [[ "$LAST_TOP" != "repos" ]]; then
  die "repos.yml invariant broken: last top-level key is '$LAST_TOP', need 'repos'. Fix the file (move 'repos:' to the bottom) and re-run."
fi

if [[ "$CATEGORY" == "reference" ]]; then
  DEST="$CIRCUS_REFERENCES_DIR/$NAME"
else
  DEST="$CIRCUS_REPOS_DIR/$NAME"
fi
[[ -e "$DEST" ]] && die "destination already exists: $DEST"

log "cloning $CLONE_URL -> $DEST"
git clone "$CLONE_URL" "$DEST"
ensure_trusted "$DEST"

DEFAULT_BRANCH=$(git -C "$DEST" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
[[ -n "$DEFAULT_BRANCH" ]] || DEFAULT_BRANCH=$(git -C "$DEST" rev-parse --abbrev-ref HEAD)
[[ -n "$DEFAULT_BRANCH" ]] || DEFAULT_BRANCH="main"
log "default branch: $DEFAULT_BRANCH"

# Wiki: probe via gh, then try clone. The wiki repo only materializes after
# the first page is created on GitHub, so a 404 after a 'has_wiki: true' is
# normal — we just skip the clone and tell the user.
WIKI_ENABLED="false"
HAS_WIKI=$(gh api "repos/${NWO}" --jq '.has_wiki' 2>/dev/null || echo "false")
WIKI_DEST="$CIRCUS_WIKIS_DIR/$NAME"
if [[ "$HAS_WIKI" == "true" ]]; then
  WIKI_URL="${CLONE_URL%.git}.wiki.git"
  if [[ -e "$WIKI_DEST" ]]; then
    log "wiki dest exists; skipping clone: $WIKI_DEST"
    WIKI_ENABLED="true"
  else
    log "trying wiki clone: $WIKI_URL"
    if git clone "$WIKI_URL" "$WIKI_DEST" 2>/dev/null; then
      WIKI_ENABLED="true"
      log "wiki cloned: $WIKI_DEST"
    else
      log "wiki enabled in settings but empty (no pages yet). Create a Home page on github.com/$NWO/wiki, then run: bin/wiki-clone.sh $NAME"
    fi
  fi
else
  log "wiki disabled in repo settings — not syncing. Enable it in repo settings if you want to use it."
fi

# Append the entry. relies on repos: being last in the file.
{
  echo "  - name: $NAME"
  echo "    category: $CATEGORY"
  echo "    nwo: $NWO"
  echo "    default_branch: $DEFAULT_BRANCH"
  echo "    issues_mode: $ISSUES_MODE"
  echo "    wiki: $WIKI_ENABLED"
  if [[ "$CATEGORY" == "contributor" ]]; then
    [[ -n "$UPSTREAM_PR"  ]] && echo "    upstream_pr: $UPSTREAM_PR"
    [[ -n "$UPSTREAM_URL" ]] && echo "    upstream_remote_url: $UPSTREAM_URL"
  fi
} >> "$CIRCUS_REPOS_YML"

# Verify the file still parses and the new repo is queryable.
if ! repo_exists "$NAME" 2>/dev/null; then
  die "post-append: repo '$NAME' not found in repos.yml — please inspect $CIRCUS_REPOS_YML"
fi

cat <<EOF

repo registered: $NAME
  nwo:            $NWO
  path:           $DEST
  default_branch: $DEFAULT_BRANCH
  category:       $CATEGORY
  issues_mode:    $ISSUES_MODE
  wiki:           $([[ "$WIKI_ENABLED" == "true" ]] && echo "synced to $WIKI_DEST" || echo "not synced")

Edit $CIRCUS_REPOS_YML to set identity / worktree_root / etc. when needed.
EOF
