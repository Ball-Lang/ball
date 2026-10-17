#!/usr/bin/env bash
# PHASE 2 of the root release line (issue #755 — "release via auto-merged
# PR"): runs from its own `finish-release` job in
# `.github/workflows/release.yml` on every `push`, on a recurring `schedule`,
# and on a real (non-dry-run) `workflow_dispatch`. Detects whether HEAD is a
# release PR that just merged (subject `chore(release): X.Y.Z`, written and
# pinned by tools/release/open_release_pr.sh's `--merge-subject`), and if so
# — ONLY then — tags it, creates the GitHub Release, and (via this script's
# caller) dispatches the four downstream publish workflows (npm/C++/Go/
# pub.dev). A push that is not a release-PR merge is a true no-op
# (`is_release=false`).
#
# WHY `schedule` EXISTS AND `push` CANNOT BE TRUSTED ALONE (PR #881 review
# finding 2): `tools/release/open_bot_pr.sh` arms the release PR's auto-merge
# with `gh pr merge --auto`, authenticated with this workflow's own
# `GITHUB_TOKEN`. GitHub's recursion guard ("events triggered by the
# GITHUB_TOKEN... will not create a new workflow run") is not limited to
# actions a workflow performs synchronously — it also covers the merge
# GitHub itself performs later, once the required checks go green, when that
# merge was *armed* with `GITHUB_TOKEN`. Confirmed against multiple
# independent real-world reports of exactly this shape (native `gh pr merge
# --auto`, not a merge queue) — see docs/RELEASE.md's "Release via PR"
# section for the citations. So the push that lands the release-PR merge on
# `main` is credited to `GITHUB_TOKEN` and triggers NO `on: push` workflow
# run at all — not "sometimes missed", but essentially the one push this
# script exists to react to is, by construction, the one push whose trigger
# never fires. `push` stays wired (a human- or Dependabot-merged `main`, or a
# ruleset change that stops suppressing the auto-merge push, both still work
# through it) but the `schedule` poll is the mechanism this line actually
# depends on.
#
# WHY A REPEATED POLL ON AN ALREADY-FINISHED RELEASE MUST NOT RE-DISPATCH:
# `is_release=true` stays true on every subsequent poll of the same HEAD
# (until the next push moves it), so the caller must NOT gate the four
# downstream publish dispatches on `is_release` alone — it would re-publish
# the same version every ~poll-interval until the next commit. `newly_tagged`
# is `true` only the one time this run is the one that actually created the
# tag; every idempotent re-run (poll or otherwise) reports
# `newly_tagged=false`.
#
# Why this never races tools/release/open_release_pr.sh's own PHASE 1 when
# both react to the SAME push: Phase 1 now runs in a separate job from this
# one (`release`, gated behind the `test` job, so it starts — and does its
# own fresh checkout — several minutes after this job's). By the time Phase
# 1's checkout happens, this job (no `test` dependency, seconds not minutes)
# has already pushed the tag Phase 1's `semantic-release` dry run would see,
# so it correctly computes "nothing new" for the lone "chore" commit (not
# releasable to commit-analyzer on its own). PR #881 review finding 1: when
# both phases ran as sequential STEPS of the SAME job (the original shape),
# running Phase 1 before Phase 2 meant Phase 1's dry run always ran BEFORE
# the tag existed, recomputing the identical version and opening a DUPLICATE
# release PR with a duplicated CHANGELOG entry on every push — including the
# release-PR-merge push itself, on the rare path where that push's trigger
# does fire. The job split removes the ordering dependency entirely instead
# of merely reordering two steps that can still race a parallel poll.
#
# Outputs (GITHUB_OUTPUT): is_release (true|false), newly_tagged (true|false),
# version (when is_release is true).
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
  echo "newly_tagged=false" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

VERSION="${BASH_REMATCH[1]}"
TAG="v$VERSION"
NOTES="$(git log -1 --format=%b)"

if git rev-parse --verify "refs/tags/$TAG" >/dev/null 2>&1; then
  echo "finish_release: $TAG already exists — this release PR was already finished (safe re-run)"
  echo "is_release=true" >> "${GITHUB_OUTPUT:-/dev/null}"
  # NOT newly_tagged: this is an idempotent re-run (a poll tick, a retried
  # job, a push whose trigger did fire after all) seeing a tag a PRIOR run
  # already created. The caller must not re-dispatch the four downstream
  # publish workflows for it — see this script's header.
  echo "newly_tagged=false" >> "${GITHUB_OUTPUT:-/dev/null}"
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
echo "newly_tagged=true" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "version=$VERSION" >> "${GITHUB_OUTPUT:-/dev/null}"
