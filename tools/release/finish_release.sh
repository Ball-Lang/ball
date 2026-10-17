#!/usr/bin/env bash
# PHASE 2 of the root release line (issue #755 — "release via auto-merged
# PR"): runs from its own `finish-release` job in
# `.github/workflows/release.yml` on every `push`, on a recurring `schedule`,
# and on a real (non-dry-run) `workflow_dispatch`. Finds the OLDEST commit
# since the last `vX.Y.Z` tag whose subject is a release-PR merge —
# `chore(release): X.Y.Z`, the subject tools/release/open_release_pr.sh
# commits, optionally followed by the ` (#N)` that `main`'s merge queue
# appends (see RELEASE_SUBJECT_RE below) — and if one exists — ONLY then —
# tags it, creates the GitHub Release, and (via this script's caller)
# dispatches the four downstream publish workflows (npm/C++/Go/pub.dev). No
# such commit anywhere in that range is a true no-op (`is_release=false`).
#
# WHY `schedule` EXISTS AND `push` CANNOT BE TRUSTED ALONE (PR #881 review
# finding 2): `tools/release/open_bot_pr.sh` arms the release PR's auto-merge
# with `gh pr merge --auto`, authenticated with this workflow's own
# `GITHUB_TOKEN`. GitHub's recursion guard ("events triggered by the
# GITHUB_TOKEN... will not create a new workflow run") is not limited to
# actions a workflow performs synchronously — it also covers what GitHub
# itself does later on behalf of an auto-merge *armed* with `GITHUB_TOKEN`:
# the merge-queue entry it creates (whose `merge_group` event starts no
# workflow run, which is why tools/release/service_bot_merge_queue.sh exists)
# and the merge that lands it. See docs/RELEASE.md's "Release via PR" section
# for the citations. So the push that lands the release-PR merge on `main`
# cannot be relied on to trigger an `on: push` run — essentially the one push
# this script exists to react to is the one push whose trigger is suppressed.
# `push` stays wired (a human-merged `main` still works through it) but the
# `schedule` poll is the mechanism this line actually depends on.
#
# WHY HEAD ALONE IS NOT ENOUGH (PR #881 review, round 2, finding 1): the
# `schedule` poll above only runs every 15 minutes, and GitHub documents that
# scheduled workflows can run late under load. If ANY commit — a human
# merge, a Dependabot merge, or a merge-queue merge — lands on `main` between
# the release-PR merge and the next poll tick, HEAD is no longer the release
# commit and a HEAD-only check (the original shape) would never see it: the
# commit stays untagged forever, and the next Phase 1 run recomputes the
# identical version and opens a DUPLICATE `chore(release): X` PR with a
# duplicated CHANGELOG.md entry (`apply_version_bump.mjs`'s
# `prependChangelogEntry` never dedupes). So this script instead scans every
# commit since the last `vX.Y.Z` tag (or the whole history, for the very
# first release) for the OLDEST one whose subject matches the release-PR-merge
# pattern, and tags THAT commit — not HEAD. Oldest first: if more than one
# untagged release commit has piled up (several missed polls in a row), this
# tags exactly one per run; the next invocation (another push, or the next
# poll tick) finds and tags the next one, so two releases are never created
# in the same run.
#
# WHY A REPEATED POLL ON AN ALREADY-FINISHED RELEASE MUST NOT RE-DISPATCH:
# `is_release=true` stays true on every subsequent poll that still sees that
# release as the most recent one (until a new release commit lands), so the
# caller must NOT gate the four downstream publish dispatches on `is_release`
# alone — it would re-publish the same version every ~poll-interval until the
# next release. `newly_tagged` is `true` only the one time this run is the
# one that actually created the tag; every idempotent re-run (poll or
# otherwise) reports `newly_tagged=false`.
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
# of merely reordering two steps that can still race a parallel poll. The
# same job split is what makes the HEAD-only-vs-scan distinction above matter
# in practice: it is specifically the GAP a job split (or a missed poll)
# leaves open that a HEAD-only check cannot recover from.
#
# Outputs (GITHUB_OUTPUT): is_release (true|false), newly_tagged (true|false),
# version (when is_release is true).
set -euo pipefail

# BALL_REPO_ROOT overrides the repo root this operates in — used only by
# tools/release/test/finish_release_test.sh to run the real script against a
# throwaway fixture repo instead of this checkout.
ROOT="${BALL_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$ROOT"

# The release-PR merge's subject, in BOTH shapes it can land on `main` in:
#   chore(release): 1.73.0          — a plain squash honouring the subject
#                                     open_release_pr.sh pins (no merge queue);
#   chore(release): 1.73.0 (#912)   — what `main`'s merge queue actually
#                                     writes (ruleset 17056238's `merge_queue`
#                                     rule, merge_method SQUASH). GitHub's own
#                                     schema says a queue IGNORES the
#                                     commitHeadline/commitBody/mergeMethod
#                                     `gh pr merge --auto` sends
#                                     (EnablePullRequestAutoMergeInput), so the
#                                     repository default applies — for a
#                                     single-commit PR, that commit's subject
#                                     followed by " (#<PR number>)" (every
#                                     queue-merged commit on main has it, e.g.
#                                     009fad1c "… (#905)").
# PR #881 review round 3, finding 1: the `$`-anchored bare-version pattern
# rejected the second shape, so the live lane never tagged anything. The
# version must start with a digit, so the Go lane's own
# `chore(release): go vX.Y.Z (#N)` commits (finish_go_release.sh) can never
# read as a root release.
RELEASE_SUBJECT_RE='^chore\(release\):[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+[^[:space:]]*)([[:space:]]+\(#[0-9]+\))?$'

# Nearest `vX.Y.Z` tag reachable from HEAD, or "" for a repo with none yet
# (the very first release). Deliberately NOT `|| true`: a non-matching
# `git describe` is an expected, named outcome here, not a swallowed error.
if ! LAST_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD 2>/dev/null)"; then
  LAST_TAG=""
fi

# Prints "<sha> <subject>" for the OLDEST commit in revision range $1 whose
# subject matches a release-PR merge, or nothing if none do; "no match" is
# reported by empty output with a 0 exit. A FAILING `git log` (bad range,
# repo corruption) is a distinct, non-zero-exit outcome — deliberately NOT
# read via a process substitution feeding a `while` loop, which would
# discard that exit status and make "git log itself could not run"
# indistinguishable from "no release commit found" (docs/TESTING_STRATEGY.md
# §3a / issue #694: the whole point of this scan is to decide
# `is_release`/`newly_tagged`, so a silently-swallowed git failure would be
# exactly the "verdict loop that cannot tell a clean answer from a checker
# that never ran" shape that section bans). Capturing the command's own
# output AND status (§3a shape 2) lets a `git log` failure propagate as this
# function's own non-zero return, which the caller assigns via
# `CANDIDATE="$(find_oldest_release_commit …)"` — under `set -e`, that plain
# assignment aborts the script on a non-zero status, so a `git log` failure
# here fails the whole run loud rather than silently acting as "nothing to
# release".
find_oldest_release_commit() {
  local range="$1" output line sha subject
  if ! output="$(git log --reverse --format='%H %s' "$range")"; then
    echo "finish_release: \`git log\` over range '$range' failed — cannot determine whether a release is pending" >&2
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
  TAG="v$VERSION"
  NOTES="$(git log -1 --format=%b "$COMMIT_SHA")"

  if git rev-parse --verify "refs/tags/$TAG" >/dev/null 2>&1; then
    # Should not normally happen — $COMMIT_SHA was found precisely because it
    # sits AFTER $LAST_TAG — but tags can be created out of band, so stay
    # idempotent rather than fail on a tag that already points somewhere.
    echo "finish_release: $TAG already exists — this release PR was already finished (safe re-run)"
    echo "is_release=true" >> "${GITHUB_OUTPUT:-/dev/null}"
    echo "newly_tagged=false" >> "${GITHUB_OUTPUT:-/dev/null}"
    echo "version=$VERSION" >> "${GITHUB_OUTPUT:-/dev/null}"
    exit 0
  fi

  WORKDIR="$(mktemp -d)"
  trap 'rm -rf "$WORKDIR"' EXIT
  printf '%s\n' "$NOTES" > "$WORKDIR/notes.md"

  echo "::group::tag $TAG at $COMMIT_SHA"
  git tag "$TAG" "$COMMIT_SHA"
  git push origin "refs/tags/$TAG"
  echo "::endgroup::"

  echo "::group::create GitHub Release $TAG"
  gh release create "$TAG" --title "$VERSION" --notes-file "$WORKDIR/notes.md"
  echo "::endgroup::"

  echo "is_release=true" >> "${GITHUB_OUTPUT:-/dev/null}"
  echo "newly_tagged=true" >> "${GITHUB_OUTPUT:-/dev/null}"
  echo "version=$VERSION" >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

# No untagged release-PR-merge commit anywhere since $LAST_TAG. If
# $LAST_TAG's own commit IS one (the common case: nothing new has landed
# since the last release this mechanism finished), report that — purely for
# visibility/idempotency parity with a fresh tag-creation run — but
# `newly_tagged=false`, so the caller never re-dispatches for it.
if [ -n "$LAST_TAG" ]; then
  LAST_TAG_SHA="$(git rev-list -n1 "$LAST_TAG")"
  LAST_TAG_SUBJECT="$(git log -1 --format=%s "$LAST_TAG_SHA")"
  if [[ "$LAST_TAG_SUBJECT" =~ $RELEASE_SUBJECT_RE ]]; then
    echo "finish_release: $LAST_TAG already finished this release (no new chore(release) commit since) — safe no-op"
    echo "is_release=true" >> "${GITHUB_OUTPUT:-/dev/null}"
    echo "newly_tagged=false" >> "${GITHUB_OUTPUT:-/dev/null}"
    echo "version=${BASH_REMATCH[1]}" >> "${GITHUB_OUTPUT:-/dev/null}"
    exit 0
  fi
fi

echo "finish_release: no chore(release) commit found since ${LAST_TAG:-the first commit} — nothing to do"
echo "is_release=false" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "newly_tagged=false" >> "${GITHUB_OUTPUT:-/dev/null}"
