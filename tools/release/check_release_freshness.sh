#!/usr/bin/env bash
# Freshness guard for the root release line (issue #755's Definition of Done:
# "fails loud when main has releasable commits but no new release/tag appears
# within a reasonable window" — the sibling of go-freshness.yml/
# pubdev-freshness.yml for THIS channel).
#
# WHY THIS EXISTS: every other guard in this release line is STATIC — it
# proves the shape is right (open_release_pr.sh exists, finish_release.sh is
# wired, etc.), never that a release actually shipped. That is exactly how
# #755 itself went unnoticed for weeks: `release.yml` ran green on every push
# (its one failing step was INSIDE the job, so the run still reported a red
# conclusion, but there was no ALARM — nothing scheduled, nothing comparing
# "main has unreleased commits" against "did a release land"). This answers
# one question, independent of why a prior run passed or failed:
#
#     has main had a releasable commit sitting unreleased for longer than the
#     grace window, with no new tag to show for it?
#
# Classification (the `classify` function below, self-tested in isolation —
# NEVER guess the live verdict without proving the classifier first):
#   FRESH    — nothing releasable, or the oldest unreleased commit is still
#              within the grace window (the release PR may just be waiting on
#              its required checks — this is not an alarm).
#   STALE    — semantic-release says a release IS due, and the oldest
#              unreleased commit is OLDER than MAX_LAG_MINUTES. Hard failure.
#   UNKNOWN  — semantic-release says a release is due but the oldest
#              unreleased commit's age could not be determined. Per the
#              go-freshness.yml precedent, an "I learned nothing" answer is
#              itself a failure, never a silent pass.
#
# Usage:
#   bash tools/release/check_release_freshness.sh --self-test
#   MAX_LAG_MINUTES=1440 bash tools/release/check_release_freshness.sh
set -euo pipefail

MAX_LAG_MINUTES="${MAX_LAG_MINUTES:-1440}" # 24h default — generous; see docs/RELEASE.md.

# @param $1 release  "true" | "false" — semantic-release's dry-run verdict.
# @param $2 oldest   epoch seconds of the oldest unreleased commit, or "".
# @param $3 now      epoch seconds "now".
# @stdout "FRESH" | "STALE <age_minutes>" | "UNKNOWN"
classify() {
  local release="$1" oldest="$2" now="$3"
  if [ "$release" != "true" ]; then
    echo "FRESH"
    return
  fi
  if [ -z "$oldest" ]; then
    echo "UNKNOWN"
    return
  fi
  local age_minutes=$(((now - oldest) / 60))
  if [ "$age_minutes" -gt "$MAX_LAG_MINUTES" ]; then
    echo "STALE $age_minutes"
  else
    echo "FRESH"
  fi
}

self_test() {
  local pass=0 fail=0
  check() {
    local desc="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
      pass=$((pass + 1))
      echo "PASS  $desc"
    else
      fail=$((fail + 1))
      echo "FAIL  $desc (got: '$got', want: '$want')"
    fi
  }

  check "nothing releasable -> FRESH" "$(classify false "" 1000)" "FRESH"
  check "releasable, 10 min old, 1440 min window -> FRESH" "$(classify true 400 1000)" "FRESH"
  check "releasable, exactly at the window boundary -> FRESH (strictly greater-than fails)" \
    "$(classify true 0 $((MAX_LAG_MINUTES * 60)))" "FRESH"
  check "releasable, one minute past the window -> STALE" \
    "$(classify true 0 $(((MAX_LAG_MINUTES + 1) * 60)))" "STALE $((MAX_LAG_MINUTES + 1))"
  check "releasable but oldest-commit age unknown -> UNKNOWN (never a silent pass)" \
    "$(classify true "" 1000)" "UNKNOWN"

  echo
  echo "pass=$pass fail=$fail"
  [ "$fail" -eq 0 ]
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit $?
fi

ROOT="${BALL_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$ROOT"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# BALL_FORCE_RELEASE_DUE overrides the semantic-release dry-run verdict below
# — used ONLY by tools/release/test/check_release_freshness_live_test.sh
# (PR #881 review finding 4) to exercise this script's LIVE path (the
# LAST_TAG/RANGE/OLDEST_ISO computation, the classify() call against real
# git state, and the STALE branch's `gh pr list` lookup + error message)
# against a throwaway fixture repo. `compute_next_release.mjs` itself calls
# semantic-release's core, which unconditionally refuses to compute a real
# answer for a `pull_request` event (sets `isPr`, logs "a new version won't
# be published") OR for any branch other than its configured release branch
# (logs "configured to only publish from main") — so this script's live path
# (everything after the `RELEASE != true` check) is NOT exercisable through
# release-freshness.yml's own `pull_request` rehearsal or release.yml's
# `workflow_dispatch` dry-run rehearsal on a topic branch: both always see
# `{"release":false}` and this script always reports FRESH trivially, never
# touching the logic that would actually need to be correct the one time it
# matters. Confirmed from this very PR's own CI runs — see docs/RELEASE.md's
# "Release via PR" section. Never set in the real `release-freshness.yml`
# workflow.
if [ -n "${BALL_FORCE_RELEASE_DUE:-}" ]; then
  RELEASE="$BALL_FORCE_RELEASE_DUE"
else
  node "$ROOT/tools/release/compute_next_release.mjs" > "$WORKDIR/next.json"
  RELEASE="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).release)' "$WORKDIR/next.json")"
fi

if [ "$RELEASE" != "true" ]; then
  echo "release-freshness: nothing releasable on main — nothing to watch"
  exit 0
fi

LAST_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD 2>/dev/null || true)"
RANGE="HEAD"
[ -n "$LAST_TAG" ] && RANGE="$LAST_TAG..HEAD"
OLDEST_ISO="$(git log "$RANGE" --format=%cI | tail -1)"

if [ -z "$OLDEST_ISO" ]; then
  echo "::error::release-freshness: semantic-release says a release IS due, but no commit was found in range '$RANGE' — the classifier learned nothing (UNKNOWN), which is itself a failure, never a silent pass"
  exit 1
fi

OLDEST_EPOCH="$(date -d "$OLDEST_ISO" +%s)"
NOW_EPOCH="$(date +%s)"
VERDICT="$(classify true "$OLDEST_EPOCH" "$NOW_EPOCH")"

if [ "${VERDICT%% *}" = "STALE" ]; then
  AGE_MINUTES="${VERDICT##* }"
  OPEN_PR="$(gh pr list --head release/next --state open --json number,url --jq '.[0].url // ""' 2>/dev/null || true)"
  # PR #881 review finding 4 turned up a second, independent bug while
  # writing the first-ever live-path test for this branch: bash's parser
  # treats an unescaped `'` inside a `${var:-word}` default as opening a
  # quoted region, even when the whole expansion sits inside a double-quoted
  # string — and with TWO such apostrophes on one line ("repo's", "yml's"),
  # it silently swallows everything between them into the (unused, since
  # LAST_TAG is normally non-empty) `${LAST_TAG:-...}` default, truncating
  # the echoed message right after `$LAST_TAG`'s value and before "Open
  # release PR:" ever printed — this alarm's single most actionable line,
  # dropped on every real STALE verdict, caught by no self-test because
  # `--self-test` never calls this branch with the real git/gh plumbing
  # live. Neither default below spells an apostrophe now.
  echo "::error::release-freshness: main has had a releasable commit unreleased for ${AGE_MINUTES} minutes (> ${MAX_LAG_MINUTES}), oldest at ${OLDEST_ISO} since ${LAST_TAG:-the very first commit}. Open release PR: ${OPEN_PR:-NONE — check recent release.yml runs and tools/release/open_release_pr.sh}"
  exit 1
fi

echo "release-freshness: oldest unreleased commit ($OLDEST_ISO) is within the ${MAX_LAG_MINUTES}-minute window — nothing to alarm about"
