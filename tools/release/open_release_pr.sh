#!/usr/bin/env bash
# PHASE 1 of the root release line (issue #755 — "release via auto-merged
# PR"): compute the next version via a semantic-release DRY RUN, apply its
# file edits to a release branch, and open-or-refresh an auto-merging PR
# against `main`. Creates NO tag, NO GitHub Release, and dispatches NONE of
# the npm/C++/Go/pub.dev publish workflows — those happen only in
# tools/release/finish_release.sh, which runs after this PR has actually
# merged. Invoked by `.github/workflows/release.yml`'s `release` job.
#
# Exits 0 and does nothing (no branch push, no PR) when there is nothing to
# release, OR when the computed next release is identical (same version AND
# notes) to what the existing open release PR (if any) already carries — so a
# run of this script on a push that added no releasable commit is a true
# no-op, not a pointless re-dispatch of every required-check workflow.
#
# Requires `tools/release` toolchain installed (`cd tools/release && npm ci`)
# and `gh`/`git` authenticated as in the caller workflow.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BRANCH="release/next"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

cd "$ROOT"

echo "::group::compute next release (semantic-release dry run)"
node "$HERE/compute_next_release.mjs" > "$WORKDIR/next_release.json"
cat "$WORKDIR/next_release.json" >&2
echo "::endgroup::"

RELEASE="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).release)' "$WORKDIR/next_release.json")"
if [ "$RELEASE" != "true" ]; then
  echo "open_release_pr: nothing releasable on this push — no PR opened"
  echo "opened=false" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

VERSION="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).version)' "$WORKDIR/next_release.json")"
node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).notes)' "$WORKDIR/next_release.json" > "$WORKDIR/notes.md"
NOTES_CONTENT="$(cat "$WORKDIR/notes.md")"

echo "::group::apply version bump ($VERSION) to a fresh branch off origin/main"
git fetch origin main "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" 2>/dev/null || git fetch origin main
git checkout -B "$BRANCH" origin/main
node "$HERE/apply_version_bump.mjs" "$WORKDIR/next_release.json"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add CHANGELOG.md ts/engine/package.json ts/cli/package.json ts/compiler/package.json ts/encoder/package.json
git commit -F - <<EOF
chore(release): $VERSION

$NOTES_CONTENT
EOF
echo "::endgroup::"

# Idempotency short-circuit: a run that computes the exact same tree as the
# already-pushed release/next (every intervening push added nothing
# releasable, or re-added the same releasable content) touches nothing
# further — no force-push, no re-dispatch of every required-check workflow,
# no re-arming auto-merge. Content-based (tree hash), not message-based, so
# it cannot be fooled by cosmetic PR-body formatting.
NEW_TREE="$(git rev-parse HEAD^{tree})"
if git rev-parse --verify "refs/remotes/origin/$BRANCH" >/dev/null 2>&1; then
  OLD_TREE="$(git rev-parse "refs/remotes/origin/$BRANCH^{tree}")"
  if [ "$NEW_TREE" = "$OLD_TREE" ]; then
    echo "open_release_pr: release/next already carries this exact content — nothing to redo"
    echo "opened=false" >> "${GITHUB_OUTPUT:-/dev/null}"
    exit 0
  fi
fi

cat > "$WORKDIR/pr_body.md" <<EOF
Automated version-bump PR for the repo release line (npm packages + the
downstream C++/Go/pub.dev dispatches), computed by \`semantic-release\` from
conventional commits on \`main\`. See [docs/RELEASE.md](https://github.com/Ball-Lang/ball/blob/main/docs/RELEASE.md#release-via-pr-issue-755).

Auto-merges once every required check is green — no human action needed.
Merging this PR tags \`v$VERSION\`, creates the GitHub Release, and dispatches
\`publish-npm.yml\`, \`release-cpp.yml\`, \`go-release.yml\` and
\`pubdev-release.yml\`.

---

$NOTES_CONTENT
EOF

"$HERE/open_bot_pr.sh" \
  --branch "$BRANCH" \
  --title "chore(release): $VERSION" \
  --body-file "$WORKDIR/pr_body.md" \
  --dispatch ci.yml \
  --dispatch regression-gates.yml \
  --merge-method squash \
  --merge-subject "chore(release): $VERSION" \
  --merge-body-file "$WORKDIR/notes.md"

echo "opened=true" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "version=$VERSION" >> "${GITHUB_OUTPUT:-/dev/null}"
