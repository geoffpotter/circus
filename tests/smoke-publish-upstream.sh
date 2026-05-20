#!/usr/bin/env bash
# Smoke test for bin/publish-upstream.sh
#
# Creates two minimal local git repos (source and upstream), makes commits
# on source after a shared ancestor, then verifies:
#   1. --dry-run prints the plan without making changes
#   2. The real run cherry-picks the commits and pushes to the upstream "origin"
#
# gh pr create is stubbed so no GitHub calls are made.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Use known identity so git commit doesn't fail in CI
export GIT_AUTHOR_NAME="Test User"
export GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="Test User"
export GIT_COMMITTER_EMAIL="test@example.com"
# Force git to use 'main' as the default branch regardless of system config
export GIT_DEFAULT_BRANCH=main

# Stub gh: records calls and echoes a fake PR URL
GH_BIN="$TMP/stub-bin/gh"
mkdir -p "$TMP/stub-bin"
cat > "$GH_BIN" <<'STUB'
#!/usr/bin/env bash
printf 'https://github.com/test/upstream/pull/42\n'
STUB
chmod +x "$GH_BIN"
export PATH="$TMP/stub-bin:$PATH"

# Redirect CIRCUS_ROOT so _lib.sh initialisation doesn't touch the real install
export CIRCUS_ROOT="$TMP/fake-circus"
mkdir -p "$CIRCUS_ROOT/missions" "$CIRCUS_ROOT/worktrees" \
         "$CIRCUS_ROOT/repos" "$CIRCUS_ROOT/references" "$CIRCUS_ROOT/wikis"

# ── set up repos ─────────────────────────────────────────────────────────────

# Bare repo that serves as "origin" for the upstream working clone
UPSTREAM_ORIGIN="$TMP/upstream-origin.git"
git init --bare --quiet -b main "$UPSTREAM_ORIGIN"

# Source repo (circus-screeps stand-in)
SOURCE="$TMP/source"
git init --quiet -b main "$SOURCE"
git -C "$SOURCE" commit --allow-empty -m "common: initial commit"
ANCESTOR_SHA=$(git -C "$SOURCE" rev-parse HEAD)

# Push the ancestor to upstream-origin to initialise the main branch
git -C "$SOURCE" remote add _tmp_origin "file://$UPSTREAM_ORIGIN"
git -C "$SOURCE" push --quiet _tmp_origin "HEAD:main"
git -C "$SOURCE" remote remove _tmp_origin

# Upstream working clone (pointed at its bare "origin")
UPSTREAM="$TMP/upstream"
git clone --quiet "file://$UPSTREAM_ORIGIN" "$UPSTREAM"

# Add 2 commits on source after the shared ancestor
git -C "$SOURCE" commit --allow-empty -m "feat: first upstreamable commit"
COMMIT1=$(git -C "$SOURCE" rev-parse HEAD)
git -C "$SOURCE" commit --allow-empty -m "feat: second upstreamable commit"
COMMIT2=$(git -C "$SOURCE" rev-parse HEAD)

# Tell publish-upstream.sh to use our temp source instead of $HERE/..
export PUBLISH_UPSTREAM_SOURCE="$SOURCE"

# ── dry-run test ──────────────────────────────────────────────────────────────

OUTPUT=$(bash "$SCRIPT_DIR/bin/publish-upstream.sh" \
  --dry-run "$UPSTREAM" "test-branch" "$COMMIT1" "$COMMIT2")

echo "[smoke] dry-run output:"
echo "$OUTPUT"

echo "$OUTPUT" | grep -q "DRY RUN" || \
  { echo "[smoke] FAIL: missing 'DRY RUN' in output"; exit 1; }
echo "$OUTPUT" | grep -q "test-branch" || \
  { echo "[smoke] FAIL: missing branch name in output"; exit 1; }
echo "$OUTPUT" | grep -q "first upstreamable commit" || \
  { echo "[smoke] FAIL: missing first commit message in output"; exit 1; }
echo "$OUTPUT" | grep -q "second upstreamable commit" || \
  { echo "[smoke] FAIL: missing second commit message in output"; exit 1; }

# Upstream must be untouched after a dry run
REMOTE_BRANCH=$(git -C "$UPSTREAM_ORIGIN" branch --list "test-branch" 2>/dev/null)
[ -z "$REMOTE_BRANCH" ] || \
  { echo "[smoke] FAIL: dry-run created test-branch in upstream origin"; exit 1; }

echo "[smoke] dry-run: ok"

# ── real run test ─────────────────────────────────────────────────────────────

REAL_OUT=$(bash "$SCRIPT_DIR/bin/publish-upstream.sh" \
  "$UPSTREAM" "test-branch" "$COMMIT1" "$COMMIT2")

echo "[smoke] real-run output:"
echo "$REAL_OUT"

echo "$REAL_OUT" | grep -q "test-branch" || \
  { echo "[smoke] FAIL: branch name missing from real-run output"; exit 1; }
echo "$REAL_OUT" | grep -q "pull/42" || \
  { echo "[smoke] FAIL: fake PR URL missing (stub gh not called?)"; exit 1; }

# Branch must exist in the bare origin
git -C "$UPSTREAM_ORIGIN" rev-parse "test-branch" >/dev/null 2>&1 || \
  { echo "[smoke] FAIL: test-branch not found in upstream origin"; exit 1; }

# Exactly 2 commits on top of the ancestor
COMMIT_COUNT=$(git -C "$UPSTREAM_ORIGIN" \
  rev-list "${ANCESTOR_SHA}..test-branch" --count)
[ "$COMMIT_COUNT" -eq 2 ] || \
  { echo "[smoke] FAIL: expected 2 commits on test-branch, got $COMMIT_COUNT"; exit 1; }

# Commit messages must be preserved
MSGS=$(git -C "$UPSTREAM_ORIGIN" log \
  --format="%s" "${ANCESTOR_SHA}..test-branch" --reverse)
echo "$MSGS" | grep -q "first upstreamable commit" || \
  { echo "[smoke] FAIL: first commit message not found on test-branch"; exit 1; }
echo "$MSGS" | grep -q "second upstreamable commit" || \
  { echo "[smoke] FAIL: second commit message not found on test-branch"; exit 1; }

echo "[smoke] real-run: ok"
echo "[smoke] smoke-publish-upstream: all tests passed"
