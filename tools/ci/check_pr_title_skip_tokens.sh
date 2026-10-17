#!/usr/bin/env bash
# PR-title skip-CI token guard (issue #881).
#
# WHY THIS EXISTS. The repo now squash-merges with `squash_merge_commit_title:
# PR_TITLE` and `squash_merge_commit_message: BLANK` (owner decision,
# 2026-10-17 — verify live with
# `gh api repos/Ball-Lang/ball --jq '{t:.squash_merge_commit_title,m:.squash_merge_commit_message}'`).
# That means a PR's TITLE — unedited, exactly as typed — becomes `main`'s
# squash commit SUBJECT (as "<PR title> (#N)"), with an empty body, for every
# PR, including ones that go through the merge queue (a queue ignores any
# commit headline/body/method `gh pr merge` sends and uses these repository
# defaults instead — see docs/RELEASE.md).
#
# GitHub skips starting any `push`/`pull_request`-triggered workflow run for a
# commit whose message contains one of a handful of literal, case-insensitive
# tokens — https://docs.github.com/en/actions/managing-workflow-runs-and-deployments/managing-workflow-runs/skipping-workflow-runs:
# `[skip ci]`, `[ci skip]`, `[no ci]`, `[skip actions]`, `[actions skip]`, or a
# `skip-checks: true` git trailer. Before this title->subject mapping, only a
# COMMIT message could carry one of these by accident; now a PR TITLE can too,
# and if it does, the squash commit that lands on `main` silently skips EVERY
# push-triggered workflow for that merge — including `release.yml`, which is
# how PR #881's merge commit 6be2d949 (titled with a literal `[skip ci]`
# inherited from its branch commits) skipped the first run of the whole new
# release flow. A PR's own `pull_request`-triggered checks do not see the
# title text become a commit message at all (that substitution only happens
# at squash-merge time), so nothing else in the required-status-check set
# catches this before it reaches `main`.
#
# WHAT THIS GUARD CHECKS: the PR's title (from `github.event.pull_request.title`,
# passed in by the caller as the `PR_TITLE` env var — NEVER interpolated into
# a shell command, so a title cannot inject shell syntax) against the same
# token set GitHub's own docs name, matched case-insensitively and as a plain
# substring (GitHub's own matching is a literal, case-insensitive substring
# search over the whole commit message, not a word-boundary or anchored
# match). `skip-checks: true` is a commit-FOOTER trailer per GitHub's docs,
# which a one-line PR title cannot structurally form on its own — but a title
# that contains that exact `key: value` text is still refused, both because a
# single-line commit message (empty body, exactly this repo's new shape) is
# literally its own last paragraph, and because refusing it costs nothing and
# a false negative here is the dangerous direction.
#
# WHEN THIS RUNS: only `pull_request` carries `github.event.pull_request.title`
# at all. `merge_group` and `push` (and `schedule`/`workflow_dispatch`) carry no
# PR title, so the guard SKIPS CLEANLY on those events — there is nothing to
# check, and that is not a gap: by the time a merge group or a push exists, the
# PR title is already fixed and this guard already ran against it on the PR's
# own `pull_request` event. A `pull_request` event with no title at all (the
# `PR_TITLE` env var unset or empty) is instead a WIRING failure — GitHub PRs
# always have a non-empty title — and fails loud rather than silently passing.
#
# POSITIVE FLOOR: a self-test that drove zero cases, or a run that inspected an
# empty token set, must not report success.
#
# Usage:
#   bash tools/ci/check_pr_title_skip_tokens.sh              # gate the repo
#   bash tools/ci/check_pr_title_skip_tokens.sh --self-test  # drive the cases
#   bash tools/ci/check_pr_title_skip_tokens.sh --title "..." --event-name pull_request
#
# Reads PR_TITLE and GITHUB_EVENT_NAME from the environment when --title /
# --event-name are not given (GITHUB_EVENT_NAME is a GitHub Actions runner
# default — https://docs.github.com/en/actions/writing-workflows/choosing-what-your-workflow-does/store-information-in-variables#default-environment-variables
# — so the caller never needs to set it explicitly; only PR_TITLE needs an
# explicit `env:` entry sourcing `github.event.pull_request.title`).
#
# Needs only bash + grep (POSIX, no toolchain), so it runs in ci.yml's
# always-on `Proto Checks` job on every PR.

set -uo pipefail

TITLE=""
TITLE_SET=0
EVENT_NAME="${GITHUB_EVENT_NAME:-}"
SELF_TEST=0

while [ $# -gt 0 ]; do
  case "$1" in
  --title)
    TITLE="$2"
    TITLE_SET=1
    shift 2
    ;;
  --title=*)
    TITLE="${1#--title=}"
    TITLE_SET=1
    shift
    ;;
  --event-name)
    EVENT_NAME="$2"
    shift 2
    ;;
  --event-name=*)
    EVENT_NAME="${1#--event-name=}"
    shift
    ;;
  --self-test)
    SELF_TEST=1
    shift
    ;;
  -h | --help)
    sed -n '2,45p' "${BASH_SOURCE[0]}"
    exit 0
    ;;
  *)
    echo "::error::unknown argument: $1" >&2
    exit 2
    ;;
  esac
done

if [ "$TITLE_SET" -eq 0 ]; then
  TITLE="${PR_TITLE:-}"
fi

# ── the check itself ────────────────────────────────────────────────────────
# $1 = title, $2 = event name. Prints findings and returns 0/1/2:
#   0 = clean (or cleanly skipped — see the "skip" line below)
#   1 = a skip-CI token was found
#   2 = a wiring failure (pull_request event, empty/unset title)
check_title() {
  local title="$1" event="$2"
  local -a tokens=(
    '\[skip ci\]'
    '\[ci skip\]'
    '\[no ci\]'
    '\[skip actions\]'
    '\[actions skip\]'
    'skip-checks:[[:space:]]*true'
  )

  if [ "$event" != "pull_request" ]; then
    echo "SKIP: event is '${event:-<unset>}', not 'pull_request' — github.event.pull_request.title does not exist on this event (merge_group/push/schedule/workflow_dispatch carry no PR; the PR's own pull_request run already checked its title before either could happen). Nothing to check."
    return 0
  fi

  if [ -z "$title" ]; then
    echo "::error::event is 'pull_request' but the title is empty — PR_TITLE was not wired through (github.event.pull_request.title), or GitHub sent an empty title, which should never happen. Treating this as a wiring failure, not a clean pass."
    return 2
  fi

  local tok hit=0
  for tok in "${tokens[@]}"; do
    if printf '%s' "$title" | grep -qiE -- "$tok"; then
      echo "::error::PR title contains the GitHub skip-CI token matching /${tok}/i: \"${title}\""
      hit=1
    fi
  done

  if [ "$hit" -ne 0 ]; then
    echo "::error::This title becomes main's squash commit SUBJECT verbatim (squash_merge_commit_title: PR_TITLE) with an EMPTY body (squash_merge_commit_message: BLANK) — see docs/RELEASE.md. A skip-CI token in it silently skips every push-triggered workflow on main for this merge, including Release (issue #881). Remove the token from the PR title."
    return 1
  fi

  echo "OK: PR title carries no GitHub skip-CI token: \"${title}\""
  return 0
}

# ── self-test ───────────────────────────────────────────────────────────────
self_test() {
  local pass=0 fail=0

  case_run() {
    local name="$1" expect="$2" title="$3" event="$4"
    local out rc
    out="$(check_title "$title" "$event" 2>&1)"
    rc=$?
    if [ "$rc" -eq "$expect" ]; then
      pass=$((pass + 1))
      echo "PASS  $name (exit $rc)"
    else
      fail=$((fail + 1))
      echo "FAIL  $name (exit $rc, wanted $expect)"
      printf '  %s\n' "$out"
    fi
  }

  # ── negative controls (the real token, every documented spelling) ────────
  case_run "bracket [skip ci] rejected" 1 "chore: bump a dep [skip ci]" "pull_request"
  case_run "bracket [ci skip] rejected" 1 "chore: bump a dep [ci skip]" "pull_request"
  case_run "bracket [no ci] rejected" 1 "chore: bump a dep [no ci]" "pull_request"
  case_run "bracket [skip actions] rejected" 1 "chore: bump a dep [skip actions]" "pull_request"
  case_run "bracket [actions skip] rejected" 1 "chore: bump a dep [actions skip]" "pull_request"
  case_run "skip-checks: true trailer rejected" 1 "chore: bump a dep skip-checks: true" "pull_request"
  case_run "skip-checks:true (no space) rejected" 1 "chore: bump a dep skip-checks:true" "pull_request"
  case_run "mixed case [Skip CI] rejected" 1 "fix: thing [Skip CI]" "pull_request"
  case_run "upper case [SKIP CI] rejected" 1 "fix: thing [SKIP CI]" "pull_request"
  case_run "token mid-title rejected" 1 "fix(ci): [skip ci] re-run the release lane" "pull_request"
  case_run "token with trailing text rejected" 1 "fix: thing [skip ci] (refs #881)" "pull_request"

  # ── positive controls (clean titles that must pass) ───────────────────────
  case_run "ordinary title accepted" 0 "fix(ci): PR titles become main's squash subject (refs #881)" "pull_request"
  case_run "title mentioning CI with no token accepted" 0 "ci: speed up the CI matrix" "pull_request"
  case_run "title saying 'skip' without brackets accepted" 0 "docs: explain why we no longer skip ci accidentally" "pull_request"
  case_run "title saying 'skipping' (substring near but not the token) accepted" 0 "fix: stop skipping ci steps on flaky retries" "pull_request"
  case_run "title mentioning skip-checks without true accepted" 0 "docs: document the skip-checks trailer" "pull_request"
  case_run "title with an unrelated bracketed tag accepted" 0 "fix(go): [go-modules] bump the proxy version" "pull_request"

  # ── event-gating controls ─────────────────────────────────────────────────
  case_run "merge_group with a tainted title is skipped cleanly" 0 "chore: x [skip ci]" "merge_group"
  case_run "push with a tainted title is skipped cleanly" 0 "chore: x [skip ci]" "push"
  case_run "schedule with a tainted title is skipped cleanly" 0 "chore: x [skip ci]" "schedule"
  case_run "workflow_dispatch with a tainted title is skipped cleanly" 0 "chore: x [skip ci]" "workflow_dispatch"
  case_run "unset event name is skipped cleanly, not treated as pull_request" 0 "chore: x [skip ci]" ""

  # ── wiring-failure controls ────────────────────────────────────────────────
  case_run "pull_request with an empty title is a wiring failure, not a pass" 2 "" "pull_request"

  local total=$((pass + fail))
  # Positive floor: nothing run must not look like nothing wrong.
  if [ "$total" -lt 19 ]; then
    echo "::error::self-test ran $total case(s), expected at least 19"
    return 1
  fi
  echo "Results: $pass passed, $fail failed, $total total"
  [ "$fail" -eq 0 ] || return 1
  return 0
}

if [ "$SELF_TEST" -eq 1 ]; then
  self_test
  exit $?
fi

check_title "$TITLE" "$EVENT_NAME"
rc=$?
# A wiring failure (exit 2) is still a hard failure for the gate's own exit
# code — only the SELF-TEST distinguishes it from a found-token failure.
[ "$rc" -eq 0 ] && exit 0
exit 1
