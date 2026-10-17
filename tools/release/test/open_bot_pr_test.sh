#!/usr/bin/env bash
# Self-test for tools/release/open_bot_pr.sh (issue #755).
#
# Runs the REAL script against a throwaway local git repo with a local bare
# "origin" remote (so the force-push needs no network) and a stub `gh` on
# PATH that logs every invocation and answers `pr list`/`repo view`/`pr
# create` from env-controlled canned output instead of calling the real
# GitHub API. Zero network, zero real credentials.
#
#   bash tools/release/test/open_bot_pr_test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../open_bot_pr.sh"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "PASS  $1"; }
no() { fail=$((fail + 1)); echo "FAIL  $1"; }

BARE="$WORKDIR/origin.git"
WORK="$WORKDIR/work"
git init --bare -q "$BARE"
git init -q "$WORK"
git -C "$WORK" remote add origin "$BARE"
git -C "$WORK" config user.name "test"
git -C "$WORK" config user.email "test@example.com"
echo "hello" > "$WORK/README.md"
git -C "$WORK" add README.md
git -C "$WORK" commit -q -m "chore(release): 1.73.0" -m "## [1.73.0](url) (2026-10-17)"
git -C "$WORK" push -q origin HEAD:refs/heads/main
git -C "$WORK" checkout -q -b release/next

STUBDIR="$WORKDIR/stubbin"
mkdir -p "$STUBDIR"
GH_LOG="$WORKDIR/gh_invocations.log"
cat > "$STUBDIR/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "repo view") echo "test-owner/test-repo" ;;
  # The real script pipes `gh pr list --json number --jq '.[0].number // ""'`
  # straight into a variable; this stub stands in for the WHOLE `gh`
  # invocation (including its embedded jq), so it answers with the
  # already-filtered result the real jq expression would have produced,
  # not raw JSON.
  "pr list") printf '%s' "${GH_STUB_PR_LIST_JSON:-}" ;;
  "pr create") echo "https://github.com/test-owner/test-repo/pull/${GH_STUB_PR_NUMBER:-42}" ;;
esac
exit 0
STUB
chmod +x "$STUBDIR/gh"

BODY_FILE="$WORKDIR/body.md"
echo "pr body" > "$BODY_FILE"

run_open_bot_pr() {
  PATH="$STUBDIR:$PATH" GH_LOG="$GH_LOG" GH_STUB_PR_LIST_JSON="${GH_STUB_PR_LIST_JSON:-}" GH_STUB_PR_NUMBER="${GH_STUB_PR_NUMBER:-}" \
    bash "$SCRIPT" --branch release/next --title "chore(release): 1.73.0" --body-file "$BODY_FILE" \
      --dispatch ci.yml --dispatch regression-gates.yml \
      --merge-method squash --merge-subject "chore(release): 1.73.0" --merge-body-file "$BODY_FILE"
}

# ── Test 1: no existing open PR -> create, dispatch both, arm auto-merge ──
: > "$GH_LOG"
export GH_STUB_PR_LIST_JSON=""
export GH_STUB_PR_NUMBER="42"
if (cd "$WORK" && run_open_bot_pr) > "$WORKDIR/log1.txt" 2>&1; then
  ok "no existing PR -> script exits 0"
else
  no "no existing PR -> script exits 0 ($(cat "$WORKDIR/log1.txt"))"
fi
if git -C "$BARE" rev-parse --verify refs/heads/release/next >/dev/null 2>&1; then
  ok "no existing PR -> branch force-pushed to origin"
else
  no "no existing PR -> branch force-pushed to origin"
fi
if grep -q "^pr create " "$GH_LOG"; then
  ok "no existing PR -> gh pr create invoked"
else
  no "no existing PR -> gh pr create invoked (log: $(cat "$GH_LOG"))"
fi
if grep -q "^workflow run ci.yml" "$GH_LOG" && grep -q "^workflow run regression-gates.yml" "$GH_LOG"; then
  ok "no existing PR -> both required-check workflows dispatched"
else
  no "no existing PR -> both required-check workflows dispatched (log: $(cat "$GH_LOG"))"
fi
if grep -Eq "^pr merge 42 .*--auto .*--squash" "$GH_LOG"; then
  ok "no existing PR -> auto-merge armed (squash) on PR 42"
else
  no "no existing PR -> auto-merge armed (squash) on PR 42 (log: $(cat "$GH_LOG"))"
fi
if grep -q -- "--subject chore(release): 1.73.0" "$GH_LOG"; then
  ok "no existing PR -> merge subject pinned"
else
  no "no existing PR -> merge subject pinned (log: $(cat "$GH_LOG"))"
fi

# ── Test 2: an existing open PR -> edit instead of create, same dispatch ──
: > "$GH_LOG"
export GH_STUB_PR_LIST_JSON="7"
export GH_STUB_PR_NUMBER=""
if (cd "$WORK" && run_open_bot_pr) > "$WORKDIR/log2.txt" 2>&1; then
  ok "existing open PR -> script exits 0"
else
  no "existing open PR -> script exits 0 ($(cat "$WORKDIR/log2.txt"))"
fi
if grep -q "^pr edit 7 " "$GH_LOG"; then
  ok "existing open PR -> gh pr edit 7 invoked, no gh pr create"
else
  no "existing open PR -> gh pr edit 7 invoked, no gh pr create (log: $(cat "$GH_LOG"))"
fi
if grep -q "^pr create " "$GH_LOG"; then
  no "existing open PR -> must NOT call gh pr create"
else
  ok "existing open PR -> did not call gh pr create"
fi
if grep -q "^pr merge 7 " "$GH_LOG"; then
  ok "existing open PR -> auto-merge armed on PR 7"
else
  no "existing open PR -> auto-merge armed on PR 7 (log: $(cat "$GH_LOG"))"
fi

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
