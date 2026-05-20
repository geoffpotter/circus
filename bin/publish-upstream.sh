#!/usr/bin/env bash
# publish-upstream.sh [<upstream-repo-path>] <branch-name> <commit...>
#
# Cherry-picks a list of commits from this circus install into a new branch
# in an upstream repo, pushes the branch, and opens a PR via gh.
#
# 3-arg form (explicit upstream path):
#   publish-upstream.sh /path/to/upstream <branch> <commits...>
#
# 2-arg form (upstream_general in repos.yml):
#   publish-upstream.sh <branch> <commits...>
#
# Flags:
#   --force         Delete and recreate <branch> if it already exists
#   --dry-run       Print the plan but don't execute
#   --title "..."   Override the generated PR title
#   --body-file <p> Override the generated PR body with file contents

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_lib.sh"

FORCE=0
DRY_RUN=0
PR_TITLE=""
BODY_FILE=""
POSITIONAL=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)     FORCE=1; shift;;
    --dry-run)   DRY_RUN=1; shift;;
    --title)     PR_TITLE="$2"; shift 2;;
    --body-file) BODY_FILE="$2"; shift 2;;
    --)          shift; POSITIONAL+=("$@"); break;;
    -*)          die "unknown flag: $1";;
    *)           POSITIONAL+=("$1"); shift;;
  esac
done

[[ ${#POSITIONAL[@]} -ge 2 ]] || {
  cat >&2 <<'EOF'
usage: publish-upstream.sh [<upstream-repo-path>] <branch-name> <commit...>

  upstream-repo-path  Path to the upstream git repo (optional when
                      upstream_general.path is set in repos.yml)
  branch-name         Branch to create in the upstream repo
  commit...           Commit SHAs from this repo to cherry-pick (oldest first)

Flags:
  --force             Delete and recreate branch if it already exists
  --dry-run           Print the plan but don't execute
  --title "..."       Override the generated PR title
  --body-file <path>  Replace the generated PR body with file contents
EOF
  exit 1
}

# Resolve the upstream path: explicit directory arg or lookup from repos.yml
if [[ -d "${POSITIONAL[0]}" ]]; then
  UPSTREAM_PATH="${POSITIONAL[0]}"
  BRANCH_NAME="${POSITIONAL[1]}"
  COMMITS=("${POSITIONAL[@]:2}")
else
  UP=$(yq -r '
    .repos[] | select(.upstream_general.path != null) | .upstream_general.path
  ' "$CIRCUS_REPOS_YML" 2>/dev/null | head -1)
  [[ -n "$UP" && "$UP" != "null" ]] || \
    die "no upstream-repo-path given and no upstream_general.path in repos.yml"
  UPSTREAM_PATH="$UP"
  BRANCH_NAME="${POSITIONAL[0]}"
  COMMITS=("${POSITIONAL[@]:1}")
fi

[[ ${#COMMITS[@]} -ge 1 ]] || die "no commits specified"

# PUBLISH_UPSTREAM_SOURCE may be set by tests to override the default source
SOURCE_PATH="$(cd "${PUBLISH_UPSTREAM_SOURCE:-$HERE/..}" && pwd)"
UPSTREAM_PATH="$(cd "$UPSTREAM_PATH" && pwd)"

# Verify upstream is a git repo with an origin remote
[[ -d "$UPSTREAM_PATH/.git" || -f "$UPSTREAM_PATH/.git" ]] || \
  die "not a git repo: $UPSTREAM_PATH"
git -C "$UPSTREAM_PATH" remote get-url origin >/dev/null 2>&1 || \
  die "upstream repo has no 'origin' remote: $UPSTREAM_PATH"

# Verify each commit exists in the source repo and collect summaries
declare -a COMMIT_SUMMARIES=()
for sha in "${COMMITS[@]}"; do
  git -C "$SOURCE_PATH" cat-file -e "${sha}^{commit}" 2>/dev/null || \
    die "commit not found in source repo: $sha"
  short=$(git -C "$SOURCE_PATH" rev-parse --short "$sha")
  msg=$(git -C "$SOURCE_PATH" log -1 --format="%s" "$sha")
  COMMIT_SUMMARIES+=("$short  $msg")
done

# ── dry run ──────────────────────────────────────────────────────────────────
if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '[publish-upstream] DRY RUN — no changes will be made\n'
  printf 'source:   %s\n' "$SOURCE_PATH"
  printf 'upstream: %s\n' "$UPSTREAM_PATH"
  printf 'branch:   %s\n' "$BRANCH_NAME"
  printf 'commits (oldest first):\n'
  for s in "${COMMIT_SUMMARIES[@]}"; do
    printf '  %s\n' "$s"
  done
  exit 0
fi

# ── pre-flight checks ────────────────────────────────────────────────────────
log "checking upstream repo state"
git -C "$UPSTREAM_PATH" fetch origin --quiet

# Resolve default branch from upstream's origin/HEAD
git -C "$UPSTREAM_PATH" remote set-head origin --auto >/dev/null 2>&1 || true
DEFAULT_BRANCH=$(
  git -C "$UPSTREAM_PATH" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
    | sed 's|refs/remotes/origin/||' \
  || echo "main"
)
[[ -n "$DEFAULT_BRANCH" ]] || DEFAULT_BRANCH="main"

# Upstream working tree must be clean
if ! git -C "$UPSTREAM_PATH" diff --quiet || \
   ! git -C "$UPSTREAM_PATH" diff --cached --quiet; then
  die "upstream has uncommitted changes: $UPSTREAM_PATH"
fi

# Upstream default branch must be in sync with origin
LOCAL_SHA=$(git -C "$UPSTREAM_PATH" rev-parse "$DEFAULT_BRANCH" 2>/dev/null || echo "")
REMOTE_SHA=$(git -C "$UPSTREAM_PATH" rev-parse "origin/$DEFAULT_BRANCH" 2>/dev/null || echo "")
if [[ -n "$LOCAL_SHA" && -n "$REMOTE_SHA" && "$LOCAL_SHA" != "$REMOTE_SHA" ]]; then
  die "upstream $DEFAULT_BRANCH is out of sync with origin/$DEFAULT_BRANCH; pull first"
fi

# Handle pre-existing branch
LOCAL_EXISTS=$(git -C "$UPSTREAM_PATH" branch --list "$BRANCH_NAME")
REMOTE_EXISTS=$(git -C "$UPSTREAM_PATH" ls-remote --heads origin "$BRANCH_NAME" 2>/dev/null | head -1)
if [[ -n "$LOCAL_EXISTS" || -n "$REMOTE_EXISTS" ]]; then
  if [[ "$FORCE" -eq 0 ]]; then
    die "branch '$BRANCH_NAME' already exists; use --force to overwrite"
  fi
  log "removing existing branch: $BRANCH_NAME"
  [[ -n "$LOCAL_EXISTS" ]] && git -C "$UPSTREAM_PATH" branch -D "$BRANCH_NAME"
  [[ -n "$REMOTE_EXISTS" ]] && git -C "$UPSTREAM_PATH" push origin --delete "$BRANCH_NAME" 2>/dev/null || true
fi

# ── add source as a temporary remote so its commits are reachable ─────────────
TEMP_REMOTE="_pub_src_$$"
TMP_WORKTREE=""
CHERRY_PICK_FAILED=0

cleanup() {
  if [[ -n "$TMP_WORKTREE" && "$CHERRY_PICK_FAILED" -eq 0 ]]; then
    git -C "$UPSTREAM_PATH" worktree remove --force "$TMP_WORKTREE" 2>/dev/null || true
    git -C "$UPSTREAM_PATH" worktree prune 2>/dev/null || true
  fi
  git -C "$UPSTREAM_PATH" remote remove "$TEMP_REMOTE" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

log "fetching commits from source"
git -C "$UPSTREAM_PATH" remote add "$TEMP_REMOTE" "file://$SOURCE_PATH"
git -C "$UPSTREAM_PATH" fetch "$TEMP_REMOTE" --quiet

# ── create an isolated worktree for the cherry-picks ─────────────────────────
TMP_WORKTREE="$(mktemp -d)"
log "creating branch '$BRANCH_NAME' off origin/$DEFAULT_BRANCH"
git -C "$UPSTREAM_PATH" worktree add \
  "$TMP_WORKTREE" -b "$BRANCH_NAME" "origin/$DEFAULT_BRANCH"

# ── cherry-pick commits (oldest first) ───────────────────────────────────────
log "cherry-picking ${#COMMITS[@]} commit(s)"
for sha in "${COMMITS[@]}"; do
  msg=$(git -C "$SOURCE_PATH" log -1 --format="%s" "$sha")
  log "  $sha — $msg"
  if ! git -C "$TMP_WORKTREE" cherry-pick --allow-empty "$sha"; then
    CHERRY_PICK_FAILED=1
    printf '\n[circus][error] cherry-pick failed on %s (%s)\n' "$sha" "$msg" >&2
    printf '[circus][error] unresolved files:\n' >&2
    git -C "$TMP_WORKTREE" diff --name-only --diff-filter=U 2>/dev/null \
      | sed 's/^/  /' >&2 || true
    printf '\nThe branch is in conflicted state. To abort:\n' >&2
    printf '  git -C %q cherry-pick --abort\n' "$TMP_WORKTREE" >&2
    printf 'Worktree: %s\n' "$TMP_WORKTREE" >&2
    exit 1
  fi
done

# ── push branch and open PR ───────────────────────────────────────────────────
log "pushing '$BRANCH_NAME' to origin"
git -C "$TMP_WORKTREE" push -u origin "$BRANCH_NAME"

N="${#COMMITS[@]}"
PLURAL=$([ "$N" -ne 1 ] && echo 's' || true)

if [[ -n "$BODY_FILE" ]]; then
  PR_BODY=$(cat "$BODY_FILE")
else
  PR_BODY="Upstream sync from circus-screeps ($N commit${PLURAL})

Commits (oldest first):
$(for s in "${COMMIT_SUMMARIES[@]}"; do printf -- '- %s\n' "$s"; done)

---
Source install: $SOURCE_PATH"
fi

[[ -n "$PR_TITLE" ]] || PR_TITLE="Upstream sync from circus-screeps ($N commit${PLURAL})"

UPSTREAM_REMOTE_URL=$(git -C "$UPSTREAM_PATH" remote get-url origin)
UPSTREAM_NWO=$(printf '%s' "$UPSTREAM_REMOTE_URL" \
  | sed -E 's|^git@github\.com:|https://github.com/|; s|\.git$||; s|^https?://[^/]+/||')

log "opening PR on ${UPSTREAM_NWO:-$UPSTREAM_PATH}"
PR_URL=$(gh pr create \
  ${UPSTREAM_NWO:+--repo "$UPSTREAM_NWO"} \
  --head "$BRANCH_NAME" \
  --base "$DEFAULT_BRANCH" \
  --title "$PR_TITLE" \
  --body "$PR_BODY" 2>&1 | tail -1)

printf '[publish-upstream] done\nbranch:   %s\nupstream: %s\npr:       %s\n' \
  "$BRANCH_NAME" "$UPSTREAM_PATH" "$PR_URL"
