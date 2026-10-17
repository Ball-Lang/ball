#!/usr/bin/env bash
# PHASE 2 of the root release line (issue #755 — "release via auto-merged
# PR"): runs on every push to `main`. Detects whether HEAD is a release PR
# that just merged (subject `chore(release): X.Y.Z`, written and pinned by
# tools/release/open_release_pr.sh's `--merge-subject`), and if so — ONLY
# then — tags it, creates the GitHub Release, and dispatches the four
# downstream publish workflows (npm/C++/Go/pub.dev). A push that is not a
# release-PR merge is a true no-op (`is_release=false`): this is what makes
# it safe to call unconditionally from `.github/workflows/release.yml`'s
# `push: branches:[main]` trigger.
#
# Why this never races tools/release/open_release_pr.sh's own PHASE 1: a
# push whose HEAD is `chore(release): X.Y.Z` is, by construction, not a
# commit `semantic-release`'s commit-analyzer would itself call releasable
# (a lone "chore" commit with no conventional-commit footer) — so the SAME
# job's phase-1 step (run first) computes "nothing to release" for it and
# phase 2 is the only one that acts.
#
# Outputs (GITHUB_OUTPUT): is_release (true|false), version (when true).
set -euo pipefail

# BALL_REPO_ROOT overrides the repo root this operates in — used only by
# tools/release/test/finish_release_test.sh to run the real script against a
# throwaway fixture repo instead of this checkout.
ROOT="${BALL_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$ROOT"

SUBJECT="$(git log -1 --format=%s)"
if [[ ! "$SUBJECT" =~ ^chore\(release\):[[:space:]]+([^[:space:]]+)$ ]]; then
  echo "finish_release: HEAD ($SUBJECT) is not a release-PR merge — nothing to do"
  echo "is_release=false" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

VERSION="${BASH_REMATCH[1]}"
TAG="v$VERSION"
NOTES="$(git log -1 --format=%b)"

if git rev-parse --verify "refs/tags/$TAG" >/dev/null 2>&1; then
  echo "finish_release: $TAG already exists — this release PR was already finished (safe re-run)"
  echo "is_release=true" >> "${GITHUB_OUTPUT:-/dev/null}"
  echo "version=$VERSION" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
printf '%s\n' "$NOTES" > "$WORKDIR/notes.md"

echo "::group::tag $TAG at HEAD"
git tag "$TAG" HEAD
git push origin "refs/tags/$TAG"
echo "::endgroup::"

echo "::group::create GitHub Release $TAG"
gh release create "$TAG" --title "$VERSION" --notes-file "$WORKDIR/notes.md"
echo "::endgroup::"

echo "is_release=true" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "version=$VERSION" >> "${GITHUB_OUTPUT:-/dev/null}"
