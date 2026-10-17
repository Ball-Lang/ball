#!/usr/bin/env bash
# Integration test for tools/release/check_release_freshness.sh's LIVE path
# (PR #881 review finding 4).
#
# WHY THIS EXISTS: `check_release_freshness.sh --self-test` only proves the
# pure `classify()` function in isolation (fabricated release/oldest/now
# inputs). Everything AFTER that — the real `LAST_TAG`/`RANGE`/`OLDEST_ISO`
# computation against actual git state, `classify()` fed from it, the STALE
# branch's `gh pr list` lookup, and the final error-message formatting — was
# previously exercised NOWHERE: `compute_next_release.mjs` (semantic-release
# core) unconditionally refuses to compute a real answer for a `pull_request`
# event or for any branch other than its configured release branch, which is
# exactly the only two ways release-freshness.yml's own `pull_request`
# rehearsal and release.yml's `workflow_dispatch` dry-run rehearsal ever call
# it — so both ALWAYS see `{"release":false}` and this script ALWAYS reports
# FRESH trivially, a "test" that cannot fail by construction. Confirmed from
# this repo's own CI logs (job 117304930214: "This run was triggered by a
# pull request and therefore a new version won't be published" ->
# "nothing releasable on main — nothing to watch"; job 117303849054:
# "configured to only publish from main" -> {"release":false}).
#
# This test runs the REAL script (BALL_REPO_ROOT override, same pattern as
# finish_release_test.sh) against a throwaway local git repo, using
# BALL_FORCE_RELEASE_DUE to stand in for a real "yes, a release is due"
# verdict without needing `compute_next_release.mjs` to ever produce one off
# `main`. Zero network, zero real credentials.
#
#   bash tools/release/test/check_release_freshness_live_test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../check_release_freshness.sh"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "PASS  $1"; }
no() { fail=$((fail + 1)); echo "FAIL  $1"; }

WORK="$WORKDIR/work"
git init -q "$WORK"
git -C "$WORK" config user.name "test"
git -C "$WORK" config user.email "test@example.com"

commit_at() {
  # $1: ISO date. $2: message.
  GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" \
    git -C "$WORK" commit -q --allow-empty -m "$2"
}

echo "seed" > "$WORK/README.md"
git -C "$WORK" add README.md
commit_at "2026-01-01T00:00:00Z" "chore: initial commit"
git -C "$WORK" tag v1.0.0 HEAD

# A commit 10 minutes old since v1.0.0 — far enough in the past that a
# 1-minute window reliably calls it STALE and a 1440-minute (24h) window
# reliably calls it FRESH, with no dependence on how long this test itself
# takes to run.
TEN_MIN_AGO="$(date -u -d "-10 minutes" +%Y-%m-%dT%H:%M:%SZ)"
commit_at "$TEN_MIN_AGO" "feat: something releasable"

# ── stub `gh`: logs argv; answers `pr list` from $GH_PR_LIST_JSON ──────────
STUBDIR="$WORKDIR/stubbin"
mkdir -p "$STUBDIR"
cat > "$STUBDIR/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${GH_LOG:?}"
if [ "$1$2" = "prlist" ]; then
  printf '%s' "${GH_PR_LIST_JSON:-}"
fi
exit 0
EOF
chmod +x "$STUBDIR/gh"

run_check() {
  PATH="$STUBDIR:$PATH" BALL_REPO_ROOT="$WORK" BALL_FORCE_RELEASE_DUE=true \
    MAX_LAG_MINUTES="${MAX_LAG_MINUTES:-1440}" \
    GH_LOG="$WORKDIR/gh_invocations.log" GH_PR_LIST_JSON="${GH_PR_LIST_JSON:-}" \
    bash "$SCRIPT"
}

# ── Test 1: oldest unreleased commit (10 min old) is within a 24h window
#    -> FRESH, exit 0 ──────────────────────────────────────────────────────
: > "$WORKDIR/gh_invocations.log"
if MAX_LAG_MINUTES=1440 run_check >"$WORKDIR/log1.txt" 2>&1; then
  if grep -q "within the 1440-minute window" "$WORKDIR/log1.txt"; then
    ok "10-minute-old commit, 1440-minute window -> exit 0, FRESH message"
  else
    no "10-minute-old commit, 1440-minute window -> exit 0, FRESH message (got: $(cat "$WORKDIR/log1.txt"))"
  fi
else
  no "10-minute-old commit, 1440-minute window -> script must exit 0 ($(cat "$WORKDIR/log1.txt"))"
fi

# ── Test 2: the SAME commit, now outside a 1-minute window -> STALE,
#    exit 1 — isolates the classifier decision from the git-state
#    computation it's fed from (same repo, only the window changed) ───────
: > "$WORKDIR/gh_invocations.log"
GH_PR_LIST_JSON=''
if MAX_LAG_MINUTES=1 run_check >"$WORKDIR/log2.txt" 2>&1; then
  no "10-minute-old commit, 1-minute window -> script must exit 1 (exited 0: $(cat "$WORKDIR/log2.txt"))"
else
  if grep -q "release-freshness: main has had a releasable commit unreleased for" "$WORKDIR/log2.txt"; then
    ok "10-minute-old commit, 1-minute window -> exit 1, STALE error message"
  else
    no "10-minute-old commit, 1-minute window -> exit 1, STALE error message (got: $(cat "$WORKDIR/log2.txt"))"
  fi
  if grep -qF "Open release PR: NONE" "$WORKDIR/log2.txt"; then
    ok "STALE, no open PR -> 'Open release PR: NONE' (the real gh pr list lookup ran)"
  else
    no "STALE, no open PR -> 'Open release PR: NONE' (got: $(cat "$WORKDIR/log2.txt"))"
  fi
  if grep -qF "pr list --head release/next --state open" "$WORKDIR/gh_invocations.log"; then
    ok "STALE -> gh pr list --head release/next was actually invoked"
  else
    no "STALE -> gh pr list --head release/next was actually invoked (log: $(cat "$WORKDIR/gh_invocations.log"))"
  fi
fi

# ── Test 2b: the same STALE case, but an open release/next PR exists — the
#    error message must surface its URL, not NONE ─────────────────────────
: > "$WORKDIR/gh_invocations.log"
GH_PR_LIST_JSON='https://github.com/Ball-Lang/ball/pull/9999'
if MAX_LAG_MINUTES=1 run_check >"$WORKDIR/log2b.txt" 2>&1; then
  no "STALE with an open PR -> script must exit 1 (exited 0: $(cat "$WORKDIR/log2b.txt"))"
else
  if grep -qF "Open release PR: https://github.com/Ball-Lang/ball/pull/9999" "$WORKDIR/log2b.txt"; then
    ok "STALE with an open PR -> its URL is surfaced, not NONE"
  else
    no "STALE with an open PR -> its URL is surfaced, not NONE (got: $(cat "$WORKDIR/log2b.txt"))"
  fi
fi
GH_PR_LIST_JSON=''

# ── Test 3: a release is "due" but there is no commit since the last tag
#    (HEAD IS the tag) -> UNKNOWN, exit 1, never a silent pass ─────────────
: > "$WORKDIR/gh_invocations.log"
git -C "$WORK" tag v2.0.0 HEAD
if MAX_LAG_MINUTES=1440 run_check >"$WORKDIR/log3.txt" 2>&1; then
  no "no commit since the last tag -> script must exit 1 (exited 0: $(cat "$WORKDIR/log3.txt"))"
else
  if grep -qF "the classifier learned nothing (UNKNOWN), which is itself a failure, never a silent pass" "$WORKDIR/log3.txt"; then
    ok "no commit since the last tag -> UNKNOWN, exit 1 (never a silent pass)"
  else
    no "no commit since the last tag -> UNKNOWN, exit 1 (got: $(cat "$WORKDIR/log3.txt"))"
  fi
fi

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
