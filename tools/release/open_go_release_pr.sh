#!/usr/bin/env bash
# PHASE 1 of the Go module release line (issue #879 — the go-release.yml
# sibling of tools/release/open_release_pr.sh, issue #755). Computes the next
# Go module version via a semantic-release DRY RUN against
# .github/release/go.releaserc.json, applies its file edits (the real
# `bump_go_modules.sh` + a go/CHANGELOG.md prepend — the EXACT prepare-phase
# side effects @semantic-release/exec's prepareCmd and
# @semantic-release/changelog's prepare.js used to make) to a release branch,
# and opens-or-refreshes an auto-merging PR against `main`. Creates NO
# `go-modules/vX.Y.Z` tag and dispatches tag-go-modules.yml for NONE of it —
# that happens only in tools/release/finish_go_release.sh, which runs after
# this PR has actually merged. Invoked by `.github/workflows/go-release.yml`'s
# `open-release-pr` job.
#
# WHY THIS EXISTS: go-release.yml used to run `npx semantic-release` for real
# against `main`, whose @semantic-release/git step pushed the version-bump
# commit straight to it — the exact GH013 shape issue #755 fixed for the root
# npm line, one lane down (docs/RELEASE.md's "What is explicitly NOT fixed
# here" note on PR #881, now closed by this file). This never lets
# semantic-release push to `main` at all; see
# tools/release/compute_next_release.mjs's header for why its ONE core side
# effect that is not plugin-gated (`verifyAuth()`, a `git push --dry-run`) is
# safe against the live `Protect main` ruleset.
#
# THE CHANNEL-TAG BOOTSTRAP is tools/go-module-proxy/bootstrap_channel_tag.sh
# (extracted from go-release.yml's old inline step, unchanged logic, shared
# with that workflow's own dry-run rehearsal — see that script's header for
# the full "why" and the v2-cliff rationale).
#
# Requires `tools/release` toolchain installed (`cd tools/release && npm ci`)
# and `gh`/`git` authenticated as in the caller workflow, with a git identity
# already configured (same contract as open_release_pr.sh).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BRANCH="release/go-next"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

cd "$ROOT"

echo "::group::bootstrap the go-modules channel tag from the published module tags (local only)"
bash "$ROOT/tools/go-module-proxy/bootstrap_channel_tag.sh"
echo "::endgroup::"

echo "::group::compute next Go module release (semantic-release dry run)"
cp "$ROOT/.github/release/go.releaserc.json" "$ROOT/.releaserc.json"
node "$HERE/compute_next_release.mjs" > "$WORKDIR/next_release.json"
rm -f "$ROOT/.releaserc.json"
cat "$WORKDIR/next_release.json" >&2
echo "::endgroup::"

RELEASE="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).release)' "$WORKDIR/next_release.json")"
if [ "$RELEASE" != "true" ]; then
  echo "open_go_release_pr: nothing releasable on go/ since the last go-modules tag — no PR opened"
  echo "opened=false" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

VERSION="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).version)' "$WORKDIR/next_release.json")"
node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).notes)' "$WORKDIR/next_release.json" > "$WORKDIR/notes.md"
NOTES_CONTENT="$(cat "$WORKDIR/notes.md")"

echo "::group::apply version bump (go v$VERSION) to a fresh branch off origin/main"
git fetch origin main "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" 2>/dev/null || git fetch origin main
git checkout -B "$BRANCH" origin/main

# The edit go.releaserc.json's prepareCmd made before #879 removed that hook,
# run directly instead of through semantic-release — deterministic and
# idempotent, see the script's own header.
bash tools/go-module-proxy/bump_go_modules.sh "v$VERSION"
# The REAL @semantic-release/changelog prepare-phase edit.
node "$HERE/apply_changelog_bump.mjs" go/CHANGELOG.md "$WORKDIR/next_release.json"

git add go/go.work go/*/go.mod go/cli/version.go tools/coverage-study/go/go.mod go/CHANGELOG.md
git commit -F - <<EOF
chore(release): go v$VERSION

$NOTES_CONTENT
EOF
echo "::endgroup::"

# Idempotency short-circuit — see open_release_pr.sh's identical check.
NEW_TREE="$(git rev-parse HEAD^{tree})"
if git rev-parse --verify "refs/remotes/origin/$BRANCH" >/dev/null 2>&1; then
  OLD_TREE="$(git rev-parse "refs/remotes/origin/$BRANCH^{tree}")"
  if [ "$NEW_TREE" = "$OLD_TREE" ]; then
    echo "open_go_release_pr: $BRANCH already carries this exact content — nothing to redo"
    echo "opened=false" >> "${GITHUB_OUTPUT:-/dev/null}"
    exit 0
  fi
fi

cat > "$WORKDIR/pr_body.md" <<EOF
Automated version-bump PR for the Go module line, computed by
\`semantic-release\` from conventional commits touching \`go/\`. See
[docs/RELEASE.md](https://github.com/Ball-Lang/ball/blob/main/docs/RELEASE.md#go-modules-lane).

Auto-merges once every required check is green — no human action needed.
Merging this PR tags \`go-modules/v$VERSION\` and dispatches
\`tag-go-modules.yml\`, which cuts the six \`go/<module>/v$VERSION\` tags
proxy.golang.org serves.

---

$NOTES_CONTENT
EOF

"$HERE/open_bot_pr.sh" \
  --branch "$BRANCH" \
  --title "chore(release): go v$VERSION" \
  --body-file "$WORKDIR/pr_body.md" \
  --dispatch ci.yml \
  --dispatch regression-gates.yml \
  --merge-method squash \
  --merge-subject "chore(release): go v$VERSION" \
  --merge-body-file "$WORKDIR/notes.md"

echo "opened=true" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "version=$VERSION" >> "${GITHUB_OUTPUT:-/dev/null}"
