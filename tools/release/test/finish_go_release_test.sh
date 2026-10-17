#!/usr/bin/env bash
# Self-test for tools/release/finish_go_release.sh (issue #879).
#
# Runs the REAL script (BALL_REPO_ROOT override) against a throwaway local
# git repo with a local bare "origin" remote (so `git push --tags` needs no
# network), and stub `gh`/`python3` binaries on PATH that only log their
# invocation instead of calling the real GitHub API or polling anything —
# the same boundary tools/release/test/finish_release_test.sh draws around
# `gh release create`. `await_workflow_run.py`'s OWN polling/classification
# logic is proven by its own `--self-test` (already CI-gated via
# tools/release/check_go_release_wiring.sh leg 12); this test proves
# finish_go_release.sh finds the right commit, tags it correctly, and hands
# that script the right `--workflow`/`--ref`, never that the poll itself
# behaves — the identical division of labor finish_release_test.sh draws
# around `gh release create`.
#
#   bash tools/release/test/finish_go_release_test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../finish_go_release.sh"

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

# ── stub `gh` and `python3` on PATH: log argv, do nothing else ────────────
STUBDIR="$WORKDIR/stubbin"
mkdir -p "$STUBDIR"
GH_LOG="$WORKDIR/gh_invocations.log"
PY_LOG="$WORKDIR/python3_invocations.log"
cat > "$STUBDIR/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_LOG"
exit 0
EOF
chmod +x "$STUBDIR/gh"
cat > "$STUBDIR/python3" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$PY_LOG"
exit 0
EOF
chmod +x "$STUBDIR/python3"

run_finish_go_release() {
  PATH="$STUBDIR:$PATH" BALL_REPO_ROOT="$WORK" GITHUB_OUTPUT="$WORKDIR/gh_output" bash "$SCRIPT"
}

output_value() {
  local line
  line="$(grep "^$1=" "$WORKDIR/gh_output" 2>/dev/null | tail -1)" || line=""
  printf '%s\n' "${line#*=}"
}

# ── Test 1: a normal (non-release) commit is a true no-op ─────────────────
: > "$GH_LOG"
: > "$PY_LOG"
: > "$WORKDIR/gh_output"
if run_finish_go_release > "$WORKDIR/log1.txt" 2>&1; then
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
  if [ ! -s "$GH_LOG" ] && [ ! -s "$PY_LOG" ]; then
    ok "non-release commit -> neither gh nor python3 invoked"
  else
    no "non-release commit -> neither gh nor python3 invoked (gh: $(cat "$GH_LOG"), python3: $(cat "$PY_LOG"))"
  fi
else
  no "non-release commit -> script must exit 0 ($(cat "$WORKDIR/log1.txt"))"
fi

# ── Test 2: a Go release-PR-merge commit tags + dispatches the tagger ─────
printf 'chore(release): go v0.3.0\n\n## go v0.3.0\n\n* new thing\n' \
  | git -C "$WORK" commit -q --allow-empty -F -

: > "$GH_LOG"
: > "$PY_LOG"
: > "$WORKDIR/gh_output"
if run_finish_go_release > "$WORKDIR/log2.txt" 2>&1; then
  IS_RELEASE="$(output_value is_release)"
  VERSION="$(output_value version)"
  if [ "$IS_RELEASE" = "true" ] && [ "$VERSION" = "0.3.0" ]; then
    ok "release commit -> is_release=true, version=0.3.0"
  else
    no "release commit -> is_release=true, version=0.3.0 (got is_release=$IS_RELEASE version=$VERSION)"
  fi
  NEWLY_TAGGED="$(output_value newly_tagged)"
  if [ "$NEWLY_TAGGED" = "true" ]; then
    ok "release commit -> newly_tagged=true (the one run that should dispatch the tagger)"
  else
    no "release commit -> newly_tagged=true (got: $NEWLY_TAGGED)"
  fi
  if git -C "$WORK" rev-parse --verify refs/tags/go-modules/v0.3.0 >/dev/null 2>&1; then
    ok "release commit -> tag go-modules/v0.3.0 created locally"
  else
    no "release commit -> tag go-modules/v0.3.0 created locally"
  fi
  if git -C "$BARE" rev-parse --verify refs/tags/go-modules/v0.3.0 >/dev/null 2>&1; then
    ok "release commit -> tag go-modules/v0.3.0 pushed to origin"
  else
    no "release commit -> tag go-modules/v0.3.0 pushed to origin"
  fi
  if grep -qF -- '--dispatch --workflow tag-go-modules.yml --ref go-modules/v0.3.0' "$PY_LOG"; then
    ok "release commit -> await_workflow_run.py dispatched for tag-go-modules.yml at go-modules/v0.3.0"
  else
    no "release commit -> await_workflow_run.py dispatched for tag-go-modules.yml at go-modules/v0.3.0 (log: $(cat "$PY_LOG"))"
  fi
  if grep -qF "await_workflow_run.py" "$PY_LOG"; then
    ok "release commit -> the dispatched script is this checkout's own await_workflow_run.py"
  else
    no "release commit -> the dispatched script is this checkout's own await_workflow_run.py (log: $(cat "$PY_LOG"))"
  fi
else
  no "release commit -> script must exit 0 ($(cat "$WORKDIR/log2.txt"))"
fi

# ── Test 3: re-running on the same already-tagged HEAD is a safe no-op ────
: > "$GH_LOG"
: > "$PY_LOG"
: > "$WORKDIR/gh_output"
if run_finish_go_release > "$WORKDIR/log3.txt" 2>&1; then
  IS_RELEASE="$(output_value is_release)"
  if [ "$IS_RELEASE" = "true" ]; then
    ok "re-run on already-tagged HEAD -> is_release=true (idempotent)"
  else
    no "re-run on already-tagged HEAD -> is_release=true (got: $IS_RELEASE)"
  fi
  NEWLY_TAGGED="$(output_value newly_tagged)"
  if [ "$NEWLY_TAGGED" = "false" ]; then
    ok "re-run on already-tagged HEAD -> newly_tagged=false (must not re-dispatch the tagger)"
  else
    no "re-run on already-tagged HEAD -> newly_tagged=false (got: $NEWLY_TAGGED)"
  fi
  if [ ! -s "$PY_LOG" ]; then
    ok "re-run on already-tagged HEAD -> python3 never invoked again"
  else
    no "re-run on already-tagged HEAD -> python3 never invoked again (log: $(cat "$PY_LOG"))"
  fi
else
  no "re-run on already-tagged HEAD -> script must exit 0 ($(cat "$WORKDIR/log3.txt"))"
fi

# ── Test 4: a commit lands in the gap between the release-PR merge and the
# next poll (PR #881 review, round 2, finding 1's shape — the same gap
# tools/release/finish_release_test.sh pins for the root line). ───────────
printf 'chore(release): go v0.4.0\n\n## go v0.4.0\n\n* second thing\n' \
  | git -C "$WORK" commit -q --allow-empty -F -
RELEASE_COMMIT_SHA="$(git -C "$WORK" rev-parse HEAD)"
git -C "$WORK" commit -q --allow-empty -m "fix: unrelated PR merged before the next poll tick"

: > "$GH_LOG"
: > "$PY_LOG"
: > "$WORKDIR/gh_output"
if run_finish_go_release > "$WORKDIR/log4.txt" 2>&1; then
  IS_RELEASE="$(output_value is_release)"
  VERSION="$(output_value version)"
  if [ "$IS_RELEASE" = "true" ] && [ "$VERSION" = "0.4.0" ]; then
    ok "release commit followed by another commit -> is_release=true, version=0.4.0 (found despite not being at HEAD)"
  else
    no "release commit followed by another commit -> is_release=true, version=0.4.0 (got is_release=$IS_RELEASE version=$VERSION, log: $(cat "$WORKDIR/log4.txt"))"
  fi
  NEWLY_TAGGED="$(output_value newly_tagged)"
  if [ "$NEWLY_TAGGED" = "true" ]; then
    ok "release commit followed by another commit -> newly_tagged=true"
  else
    no "release commit followed by another commit -> newly_tagged=true (got: $NEWLY_TAGGED)"
  fi
  TAG_TARGET_SHA="$(git -C "$WORK" rev-parse refs/tags/go-modules/v0.4.0^{commit} 2>/dev/null || true)"
  if [ "$TAG_TARGET_SHA" = "$RELEASE_COMMIT_SHA" ]; then
    ok "release commit followed by another commit -> tag go-modules/v0.4.0 points at the RELEASE commit, not HEAD"
  else
    no "release commit followed by another commit -> tag go-modules/v0.4.0 points at the release commit $RELEASE_COMMIT_SHA (got: $TAG_TARGET_SHA)"
  fi
  if grep -qF -- '--ref go-modules/v0.4.0' "$PY_LOG"; then
    ok "release commit followed by another commit -> await_workflow_run.py dispatched at go-modules/v0.4.0"
  else
    no "release commit followed by another commit -> await_workflow_run.py dispatched at go-modules/v0.4.0 (log: $(cat "$PY_LOG"))"
  fi
else
  no "release commit followed by another commit -> script must exit 0 ($(cat "$WORKDIR/log4.txt"))"
fi

# ── Test 5: polling again after the gap-commit race is still a safe no-op ─
: > "$GH_LOG"
: > "$PY_LOG"
: > "$WORKDIR/gh_output"
if run_finish_go_release > "$WORKDIR/log5.txt" 2>&1; then
  IS_RELEASE="$(output_value is_release)"
  VERSION="$(output_value version)"
  if [ "$IS_RELEASE" = "true" ] && [ "$VERSION" = "0.4.0" ]; then
    ok "poll after the gap-commit race -> is_release=true, version=0.4.0 (still reports the last release)"
  else
    no "poll after the gap-commit race -> is_release=true, version=0.4.0 (got is_release=$IS_RELEASE version=$VERSION)"
  fi
  NEWLY_TAGGED="$(output_value newly_tagged)"
  if [ "$NEWLY_TAGGED" = "false" ]; then
    ok "poll after the gap-commit race -> newly_tagged=false (must not re-dispatch the tagger)"
  else
    no "poll after the gap-commit race -> newly_tagged=false (got: $NEWLY_TAGGED)"
  fi
  if [ ! -s "$PY_LOG" ]; then
    ok "poll after the gap-commit race -> python3 never invoked again"
  else
    no "poll after the gap-commit race -> python3 never invoked again (log: $(cat "$PY_LOG"))"
  fi
else
  no "poll after the gap-commit race -> script must exit 0 ($(cat "$WORKDIR/log5.txt"))"
fi

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
