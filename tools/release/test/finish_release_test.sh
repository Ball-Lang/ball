#!/usr/bin/env bash
# Self-test for tools/release/finish_release.sh (issue #755).
#
# Runs the REAL script (BALL_REPO_ROOT override) against a throwaway local
# git repo with a local bare "origin" remote (so `git push --tags` needs no
# network), and a stub `gh` on PATH that only logs its invocation instead of
# calling the real GitHub API. Zero network, zero real credentials.
#
#   bash tools/release/test/finish_release_test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../finish_release.sh"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "PASS  $1"; }
no() { fail=$((fail + 1)); echo "FAIL  $1"; }

# ── fixture: a bare "origin" + a working clone, both local-only ───────────
BARE="$WORKDIR/origin.git"
WORK="$WORKDIR/work"
git init --bare -q "$BARE"
git init -q "$WORK"
git -C "$WORK" remote add origin "$BARE"
git -C "$WORK" config user.name "test"
git -C "$WORK" config user.email "test@example.com"
echo "hello" > "$WORK/README.md"
git -C "$WORK" add README.md
git -C "$WORK" commit -q -m "chore: initial commit"
git -C "$WORK" push -q origin HEAD:refs/heads/main

# ── stub `gh` on PATH: logs its argv, does nothing else ────────────────────
STUBDIR="$WORKDIR/stubbin"
mkdir -p "$STUBDIR"
GH_LOG="$WORKDIR/gh_invocations.log"
cat > "$STUBDIR/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_LOG"
exit 0
EOF
chmod +x "$STUBDIR/gh"

run_finish_release() {
  PATH="$STUBDIR:$PATH" BALL_REPO_ROOT="$WORK" GITHUB_OUTPUT="$WORKDIR/gh_output" bash "$SCRIPT"
}

output_value() {
  # $1: key. Reads the last-written value for that key from GITHUB_OUTPUT.
  grep "^$1=" "$WORKDIR/gh_output" | tail -1 | cut -d= -f2-
}

# ── Test 1: a normal (non-release) commit is a true no-op ─────────────────
: > "$GH_LOG"
: > "$WORKDIR/gh_output"
if run_finish_release > "$WORKDIR/log1.txt" 2>&1; then
  IS_RELEASE="$(output_value is_release)"
  if [ "$IS_RELEASE" = "false" ]; then
    ok "non-release commit -> is_release=false"
  else
    no "non-release commit -> is_release=false (got: $IS_RELEASE)"
  fi
  NEWLY_TAGGED="$(output_value newly_tagged)"
  if [ "$NEWLY_TAGGED" = "false" ]; then
    ok "non-release commit -> newly_tagged=false"
  else
    no "non-release commit -> newly_tagged=false (got: $NEWLY_TAGGED)"
  fi
  if [ ! -s "$GH_LOG" ]; then
    ok "non-release commit -> gh never invoked"
  else
    no "non-release commit -> gh never invoked (log: $(cat "$GH_LOG"))"
  fi
else
  no "non-release commit -> script must exit 0 ($(cat "$WORKDIR/log1.txt"))"
fi

# ── Test 2: a release-PR-merge commit tags + creates the GitHub Release ───
printf 'chore(release): 1.73.0\n\n## [1.73.0](url) (2026-10-17)\n\n* new thing\n' \
  | git -C "$WORK" commit -q --allow-empty -F -

: > "$GH_LOG"
: > "$WORKDIR/gh_output"
if run_finish_release > "$WORKDIR/log2.txt" 2>&1; then
  IS_RELEASE="$(output_value is_release)"
  VERSION="$(output_value version)"
  if [ "$IS_RELEASE" = "true" ] && [ "$VERSION" = "1.73.0" ]; then
    ok "release commit -> is_release=true, version=1.73.0"
  else
    no "release commit -> is_release=true, version=1.73.0 (got is_release=$IS_RELEASE version=$VERSION)"
  fi
  NEWLY_TAGGED="$(output_value newly_tagged)"
  if [ "$NEWLY_TAGGED" = "true" ]; then
    ok "release commit -> newly_tagged=true (the one run that should dispatch publishing)"
  else
    no "release commit -> newly_tagged=true (got: $NEWLY_TAGGED)"
  fi
  if git -C "$WORK" rev-parse --verify refs/tags/v1.73.0 >/dev/null 2>&1; then
    ok "release commit -> tag v1.73.0 created locally"
  else
    no "release commit -> tag v1.73.0 created locally"
  fi
  if git -C "$BARE" rev-parse --verify refs/tags/v1.73.0 >/dev/null 2>&1; then
    ok "release commit -> tag v1.73.0 pushed to origin"
  else
    no "release commit -> tag v1.73.0 pushed to origin"
  fi
  if grep -q "^release create v1.73.0 " "$GH_LOG"; then
    ok "release commit -> gh release create v1.73.0 invoked"
  else
    no "release commit -> gh release create v1.73.0 invoked (log: $(cat "$GH_LOG"))"
  fi
else
  no "release commit -> script must exit 0 ($(cat "$WORKDIR/log2.txt"))"
fi

# ── Test 3: re-running on the same already-tagged HEAD is a safe no-op ─────
: > "$GH_LOG"
: > "$WORKDIR/gh_output"
if run_finish_release > "$WORKDIR/log3.txt" 2>&1; then
  IS_RELEASE="$(output_value is_release)"
  if [ "$IS_RELEASE" = "true" ]; then
    ok "re-run on already-tagged HEAD -> is_release=true (idempotent)"
  else
    no "re-run on already-tagged HEAD -> is_release=true (got: $IS_RELEASE)"
  fi
  # PR #881 review finding 2: release.yml now also polls this script on a
  # recurring schedule as the recovery net for a GITHUB_TOKEN-armed
  # auto-merge whose resulting push never triggers release.yml at all. A
  # poll that lands on an already-tagged HEAD (the common case, between the
  # merge and the NEXT push) must NOT look like a fresh release to the
  # caller, or every downstream publish workflow gets re-dispatched on every
  # poll interval forever.
  NEWLY_TAGGED="$(output_value newly_tagged)"
  if [ "$NEWLY_TAGGED" = "false" ]; then
    ok "re-run on already-tagged HEAD -> newly_tagged=false (must not re-dispatch publishing)"
  else
    no "re-run on already-tagged HEAD -> newly_tagged=false (got: $NEWLY_TAGGED)"
  fi
  if [ ! -s "$GH_LOG" ]; then
    ok "re-run on already-tagged HEAD -> gh never invoked again"
  else
    no "re-run on already-tagged HEAD -> gh never invoked again (log: $(cat "$GH_LOG"))"
  fi
else
  no "re-run on already-tagged HEAD -> script must exit 0 ($(cat "$WORKDIR/log3.txt"))"
fi

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
