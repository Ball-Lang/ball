#!/usr/bin/env bash
# PHASE 2 of the Go module release line (issue #879 — the go-release.yml
# sibling of tools/release/finish_release.sh, issue #755). Runs from its own
# `finish-release` job in `.github/workflows/go-release.yml` on every `push`
# to `main`, on a recurring `schedule`, and on a real (non-dry-run)
# `workflow_dispatch`. Finds the OLDEST commit since the last
# `go-modules/vX.Y.Z` tag whose subject is a Go release-PR merge —
# `chore(release): go vX.Y.Z`, the subject tools/release/open_go_release_pr.sh
# commits, optionally followed by the ` (#N)` `main`'s merge queue appends —
# and if one exists — ONLY then — tags it `go-modules/vX.Y.Z`, creates the GitHub
# Release (mirroring @semantic-release/github's old publish step, which this
# replaces — pure visibility/changelog, nothing downstream reads it), and
# dispatches-and-awaits `tag-go-modules.yml` at that tag (which cuts the six
# `go/<module>/vX.Y.Z` tags proxy.golang.org serves, reading the version back
# out of the go.mod files the tag's own commit carries). No such commit
# anywhere in that range is a true no-op (`is_release=false`).
#
# This is tools/release/finish_release.sh's shape, adapted to the Go lane's
# own tag line and its one extra downstream step (the awaited
# tag-go-modules.yml dispatch, formerly go.releaserc.json's publishCmd — see
# tools/release/await_workflow_run.py's header for the #627 "awaited, not
# fire-and-forget" rationale, unchanged here; tools/release/check_go_release_wiring.sh
# leg 12 pins that this script dispatches through it, at the channel tag). Read finish_release.sh's header for why: the job split
# (not a step reorder) removes the Phase 1/2 race, `schedule` exists because
# `gh pr merge --auto` + `GITHUB_TOKEN` suppresses the merge's own `push`
# trigger, and the scan (not a HEAD-only check) survives a commit landing in
# the gap between a release-PR merge and the next poll tick. All three apply
# here identically — this lane shares the exact same `open_bot_pr.sh`
# auto-merge mechanism.
#
# Outputs (GITHUB_OUTPUT): is_release (true|false), newly_tagged (true|false),
# version (when is_release is true, WITHOUT the leading "v" — the bare form
# go/cli/version.go's moduleVersion constant and this repo's other Go
# tooling use).
set -euo pipefail

# HERE is THIS script's own real location — never overridden — so
# await_workflow_run.py below is always this checkout's copy, even when ROOT
# (the git repo this operates ON) is overridden to a throwaway fixture that
# carries no tools/ directory of its own (tools/release/test/finish_go_release_test.sh).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# BALL_REPO_ROOT overrides the repo root this operates in — used only by
# tools/release/test/finish_go_release_test.sh to run the real script against
# a throwaway fixture repo instead of this checkout.
ROOT="${BALL_REPO_ROOT:-$(cd "$HERE/../.." && pwd)}"
cd "$ROOT"

# Both shapes the Go release-PR merge can land on `main` in — the bare
# subject open_go_release_pr.sh pins, and the " (#<PR number>)"-suffixed one
# `main`'s merge queue actually writes, since a queue ignores the pinned
# subject. See finish_release.sh's RELEASE_SUBJECT_RE comment (PR #881 review
# round 3, finding 1).
RELEASE_SUBJECT_RE='^chore\(release\):[[:space:]]+go[[:space:]]+v([0-9]+\.[0-9]+\.[0-9]+)([[:space:]]+\(#[0-9]+\))?$'

# Nearest `go-modules/vX.Y.Z` tag reachable from HEAD, or "" for a repo with
# none yet (the very first release of this channel — see
# open_go_release_pr.sh's bootstrap step, which runs before this one ever
# could, so in practice this is only empty in a fixture repo). Deliberately
# NOT `|| true` — see finish_release.sh's identical comment (issue #694).
if ! LAST_TAG="$(git describe --tags --abbrev=0 --match 'go-modules/v[0-9]*' HEAD 2>/dev/null)"; then
  LAST_TAG=""
fi

# Prints "<sha> <subject>" for the OLDEST commit in revision range $1 whose
# subject matches a Go release-PR merge, or nothing if none do — see
# finish_release.sh's find_oldest_release_commit for the full rationale
# (issue #694: a failing `git log` must propagate as THIS function's own
# non-zero return, never be swallowed by a process substitution).
find_oldest_release_commit() {
  local range="$1" output line sha subject
  if ! output="$(git log --reverse --format='%H %s' "$range")"; then
    echo "finish_go_release: \`git log\` over range '$range' failed — cannot determine whether a release is pending" >&2
    return 1
  fi
  [ -z "$output" ] && return 0
  while IFS= read -r line; do
    sha="${line:0:40}"
    subject="${line:41}"
    if [[ "$subject" =~ $RELEASE_SUBJECT_RE ]]; then
      printf '%s %s\n' "$sha" "$subject"
      return 0
    fi
  done <<< "$output"
  return 0
}

if [ -n "$LAST_TAG" ]; then
  CANDIDATE="$(find_oldest_release_commit "$LAST_TAG..HEAD")"
else
  CANDIDATE="$(find_oldest_release_commit "HEAD")"
fi

if [ -n "$CANDIDATE" ]; then
  COMMIT_SHA="${CANDIDATE:0:40}"
  SUBJECT="${CANDIDATE:41}"
  [[ "$SUBJECT" =~ $RELEASE_SUBJECT_RE ]]
  VERSION="${BASH_REMATCH[1]}"
  TAG="go-modules/v$VERSION"

  if git rev-parse --verify "refs/tags/$TAG" >/dev/null 2>&1; then
    # Should not normally happen — see finish_release.sh's identical comment.
    echo "finish_go_release: $TAG already exists — this release PR was already finished (safe re-run)"
    echo "is_release=true" >> "${GITHUB_OUTPUT:-/dev/null}"
    echo "newly_tagged=false" >> "${GITHUB_OUTPUT:-/dev/null}"
    echo "version=$VERSION" >> "${GITHUB_OUTPUT:-/dev/null}"
    exit 0
  fi

  NOTES="$(git log -1 --format=%b "$COMMIT_SHA")"
  WORKDIR="$(mktemp -d)"
  trap 'rm -rf "$WORKDIR"' EXIT
  printf '%s\n' "$NOTES" > "$WORKDIR/notes.md"

  echo "::group::tag $TAG at $COMMIT_SHA"
  git tag "$TAG" "$COMMIT_SHA"
  git push origin "refs/tags/$TAG"
  echo "::endgroup::"

  echo "::group::create GitHub Release $TAG"
  gh release create "$TAG" --title "go v$VERSION" --notes-file "$WORKDIR/notes.md"
  echo "::endgroup::"

  # Dispatch-and-await the six go/<module>/vX.Y.Z tags, the same awaited
  # call go.releaserc.json's publishCmd used to make (issue #627: a bare
  # `gh workflow run` returns the moment GitHub ACCEPTS the dispatch, so a
  # tagger run that fails, is cancelled, or never starts must not leave this
  # step green).
  echo "::group::dispatch + await tag-go-modules.yml at $TAG"
  python3 "$HERE/await_workflow_run.py" --dispatch \
    --workflow tag-go-modules.yml --ref "$TAG"
  echo "::endgroup::"

  echo "is_release=true" >> "${GITHUB_OUTPUT:-/dev/null}"
  echo "newly_tagged=true" >> "${GITHUB_OUTPUT:-/dev/null}"
  echo "version=$VERSION" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

# No untagged release-PR-merge commit anywhere since $LAST_TAG — see
# finish_release.sh's identical comment for why $LAST_TAG's own commit is
# still checked for visibility/idempotency parity.
if [ -n "$LAST_TAG" ]; then
  LAST_TAG_SHA="$(git rev-list -n1 "$LAST_TAG")"
  LAST_TAG_SUBJECT="$(git log -1 --format=%s "$LAST_TAG_SHA")"
  if [[ "$LAST_TAG_SUBJECT" =~ $RELEASE_SUBJECT_RE ]]; then
    echo "finish_go_release: $LAST_TAG already finished this release (no new chore(release) commit since) — safe no-op"
    echo "is_release=true" >> "${GITHUB_OUTPUT:-/dev/null}"
    echo "newly_tagged=false" >> "${GITHUB_OUTPUT:-/dev/null}"
    echo "version=${BASH_REMATCH[1]}" >> "${GITHUB_OUTPUT:-/dev/null}"
    exit 0
  fi
fi

echo "finish_go_release: no chore(release): go commit found since ${LAST_TAG:-the first commit} — nothing to do"
echo "is_release=false" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "newly_tagged=false" >> "${GITHUB_OUTPUT:-/dev/null}"
