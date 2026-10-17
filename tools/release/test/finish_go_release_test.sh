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
# The gh stub also copies the file a `--notes-file` argument names into
# NOTES_SEEN (finish_go_release.sh deletes its own temp copy on exit), so a
# test can assert WHAT the GitHub Release carried, not just that it was
# created — issue #923, where it went silently blank.
STUBDIR="$WORKDIR/stubbin"
mkdir -p "$STUBDIR"
GH_LOG="$WORKDIR/gh_invocations.log"
PY_LOG="$WORKDIR/python3_invocations.log"
NOTES_SEEN="$WORKDIR/notes_seen.md"
cat > "$STUBDIR/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_LOG"
prev=""
for arg in "\$@"; do
  if [ "\$prev" = "--notes-file" ]; then cp "\$arg" "$NOTES_SEEN"; fi
  prev="\$arg"
done
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

# ── the Go release commit, shaped the way GitHub actually lands it ────────
# See tools/release/test/finish_release_test.sh's identical helpers: an EMPTY
# body (`squash_merge_commit_message: BLANK`, issue #881) and a tree carrying
# the go/CHANGELOG.md entry open_go_release_pr.sh's apply_changelog_bump.mjs
# prepended, written through the REAL prependChangelogEntry.
CHANGELOG_LIB="$HERE/../lib/changelog_entry.mjs"
prepend_changelog_entry() {
  node --input-type=module -e '
    import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
    import { dirname } from "node:path";
    import { pathToFileURL } from "node:url";
    const [lib, file, notes] = process.argv.slice(1);
    const { prependChangelogEntry } = await import(pathToFileURL(lib).href);
    const current = existsSync(file) ? readFileSync(file, "utf8") : "";
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, prependChangelogEntry(current, notes));
  ' "$CHANGELOG_LIB" "$1" "$2"
}

# land_go_release_commit <subject> <go/CHANGELOG.md entry>
land_go_release_commit() {
  prepend_changelog_entry "$WORK/go/CHANGELOG.md" "$2"
  git -C "$WORK" add go/CHANGELOG.md
  git -C "$WORK" commit -q -m "$1"
}

notes_seen() {
  if [ -f "$NOTES_SEEN" ]; then cat "$NOTES_SEEN"; fi
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
# Real-shaped (issue #923): EMPTY body, go/CHANGELOG.md entry in its tree. The
# pre-#923 script read `git log --format=%b` — "" — as the Release's notes.
ENTRY_030=$'# [0.3.0](url) (2026-10-17)\n\n### Features\n\n* **go:** new thing'
land_go_release_commit "chore(release): go v0.3.0" "$ENTRY_030"

: > "$GH_LOG"
: > "$PY_LOG"
: > "$WORKDIR/gh_output"
rm -f "$NOTES_SEEN"
if run_finish_go_release > "$WORKDIR/log2.txt" 2>&1; then
  if [ -z "$(git -C "$WORK" log -1 --format=%b HEAD)" ]; then
    ok "fixture -> the Go release commit's body is EMPTY, as squash_merge_commit_message: BLANK writes it"
  else
    no "fixture -> the Go release commit's body is EMPTY (got: $(git -C "$WORK" log -1 --format=%b HEAD))"
  fi
  if [ "$(notes_seen)" = "$ENTRY_030" ]; then
    ok "empty-body Go release commit -> GitHub Release notes are the go/CHANGELOG.md entry it added (non-empty)"
  else
    no "empty-body Go release commit -> GitHub Release notes are the go/CHANGELOG.md entry it added (got: '$(notes_seen)', log: $(cat "$WORKDIR/log2.txt"))"
  fi
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
  if grep -q "^release create go-modules/v0.3.0 " "$GH_LOG"; then
    ok "release commit -> gh release create go-modules/v0.3.0 invoked"
  else
    no "release commit -> gh release create go-modules/v0.3.0 invoked (log: $(cat "$GH_LOG"))"
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
  if [ ! -s "$GH_LOG" ]; then
    ok "re-run on already-tagged HEAD -> gh never invoked again"
  else
    no "re-run on already-tagged HEAD -> gh never invoked again (log: $(cat "$GH_LOG"))"
  fi
else
  no "re-run on already-tagged HEAD -> script must exit 0 ($(cat "$WORKDIR/log3.txt"))"
fi

# ── Test 4: a commit lands in the gap between the release-PR merge and the
# next poll (PR #881 review, round 2, finding 1's shape — the same gap
# tools/release/finish_release_test.sh pins for the root line). ───────────
ENTRY_040=$'# [0.4.0](url) (2026-10-17)\n\n### Features\n\n* **go:** second thing'
land_go_release_commit "chore(release): go v0.4.0" "$ENTRY_040"
RELEASE_COMMIT_SHA="$(git -C "$WORK" rev-parse HEAD)"
git -C "$WORK" commit -q --allow-empty -m "fix: unrelated PR merged before the next poll tick"

: > "$GH_LOG"
: > "$PY_LOG"
: > "$WORKDIR/gh_output"
rm -f "$NOTES_SEEN"
if run_finish_go_release > "$WORKDIR/log4.txt" 2>&1; then
  if [ "$(notes_seen)" = "$ENTRY_040" ]; then
    ok "release commit followed by another commit -> notes are the RELEASE commit's go/CHANGELOG.md entry"
  else
    no "release commit followed by another commit -> notes are the RELEASE commit's go/CHANGELOG.md entry (got: '$(notes_seen)')"
  fi
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
  if grep -q "^release create go-modules/v0.4.0 " "$GH_LOG"; then
    ok "release commit followed by another commit -> gh release create go-modules/v0.4.0 invoked"
  else
    no "release commit followed by another commit -> gh release create go-modules/v0.4.0 invoked (log: $(cat "$GH_LOG"))"
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
  if [ ! -s "$GH_LOG" ]; then
    ok "poll after the gap-commit race -> gh never invoked again"
  else
    no "poll after the gap-commit race -> gh never invoked again (log: $(cat "$GH_LOG"))"
  fi
else
  no "poll after the gap-commit race -> script must exit 0 ($(cat "$WORKDIR/log5.txt"))"
fi

# ── Test 6: the Go release commit as the MERGE QUEUE actually writes it ────
# See tools/release/test/finish_release_test.sh's Test 6: a queue squash is
# "<the PR's title> (#<PR number>)" with an EMPTY body, whatever subject/body
# `gh pr merge --auto --subject` asked for (PR #881 review round 3, finding 1
# — the `$`-anchored pattern never tagged it; issue #923 — the body is gone).
ENTRY_050=$'# [0.5.0](url) (2026-10-17)\n\n### Features\n\n* **go:** queued thing'
land_go_release_commit "chore(release): go v0.5.0 (#913)" "$ENTRY_050"
QUEUE_RELEASE_SHA="$(git -C "$WORK" rev-parse HEAD)"

: > "$GH_LOG"
: > "$PY_LOG"
: > "$WORKDIR/gh_output"
rm -f "$NOTES_SEEN"
if run_finish_go_release > "$WORKDIR/log6.txt" 2>&1; then
  if [ "$(notes_seen)" = "$ENTRY_050" ]; then
    ok "merge-queue squash (empty body) -> notes are the 0.5.0 go/CHANGELOG.md entry alone"
  else
    no "merge-queue squash (empty body) -> notes are the 0.5.0 go/CHANGELOG.md entry alone (got: '$(notes_seen)')"
  fi
  IS_RELEASE="$(output_value is_release)"
  VERSION="$(output_value version)"
  if [ "$IS_RELEASE" = "true" ] && [ "$VERSION" = "0.5.0" ]; then
    ok "merge-queue squash subject '(#913)' -> is_release=true, version=0.5.0"
  else
    no "merge-queue squash subject '(#913)' -> is_release=true, version=0.5.0 (got is_release=$IS_RELEASE version=$VERSION, log: $(cat "$WORKDIR/log6.txt"))"
  fi
  NEWLY_TAGGED="$(output_value newly_tagged)"
  if [ "$NEWLY_TAGGED" = "true" ]; then
    ok "merge-queue squash subject -> newly_tagged=true"
  else
    no "merge-queue squash subject -> newly_tagged=true (got: $NEWLY_TAGGED)"
  fi
  TAG_TARGET_SHA="$(git -C "$BARE" rev-parse --verify --quiet refs/tags/go-modules/v0.5.0^{commit})" || TAG_TARGET_SHA=""
  if [ "$TAG_TARGET_SHA" = "$QUEUE_RELEASE_SHA" ]; then
    ok "merge-queue squash subject -> tag go-modules/v0.5.0 pushed to origin, at the release commit"
  else
    no "merge-queue squash subject -> tag go-modules/v0.5.0 pushed to origin at $QUEUE_RELEASE_SHA (got: '$TAG_TARGET_SHA')"
  fi
  if grep -qF -- '--dispatch --workflow tag-go-modules.yml --ref go-modules/v0.5.0' "$PY_LOG"; then
    ok "merge-queue squash subject -> tag-go-modules.yml dispatched-and-awaited at go-modules/v0.5.0"
  else
    no "merge-queue squash subject -> tag-go-modules.yml dispatched-and-awaited at go-modules/v0.5.0 (log: $(cat "$PY_LOG"))"
  fi
else
  no "merge-queue squash subject -> script must exit 0 ($(cat "$WORKDIR/log6.txt"))"
fi

# ── Test 7: re-polling a queue-shaped Go release is still a safe no-op ────
: > "$GH_LOG"
: > "$PY_LOG"
: > "$WORKDIR/gh_output"
if run_finish_go_release > "$WORKDIR/log7.txt" 2>&1; then
  IS_RELEASE="$(output_value is_release)"
  VERSION="$(output_value version)"
  NEWLY_TAGGED="$(output_value newly_tagged)"
  if [ "$IS_RELEASE" = "true" ] && [ "$VERSION" = "0.5.0" ] && [ "$NEWLY_TAGGED" = "false" ]; then
    ok "re-poll of a queue-shaped Go release -> is_release=true, version=0.5.0, newly_tagged=false"
  else
    no "re-poll of a queue-shaped Go release -> is_release=true, version=0.5.0, newly_tagged=false (got is_release=$IS_RELEASE version=$VERSION newly_tagged=$NEWLY_TAGGED)"
  fi
  if [ ! -s "$PY_LOG" ] && [ ! -s "$GH_LOG" ]; then
    ok "re-poll of a queue-shaped Go release -> neither gh nor python3 invoked again"
  else
    no "re-poll of a queue-shaped Go release -> neither gh nor python3 invoked again (gh: $(cat "$GH_LOG"); python3: $(cat "$PY_LOG"))"
  fi
else
  no "re-poll of a queue-shaped Go release -> script must exit 0 ($(cat "$WORKDIR/log7.txt"))"
fi

# ── Test 8: the ROOT lane's release commit is NOT a Go release ────────────
git -C "$WORK" commit -q --allow-empty -m "chore(release): 1.74.0 (#914)"

: > "$GH_LOG"
: > "$PY_LOG"
: > "$WORKDIR/gh_output"
if run_finish_go_release > "$WORKDIR/log8.txt" 2>&1; then
  NEWLY_TAGGED="$(output_value newly_tagged)"
  VERSION="$(output_value version)"
  if [ "$NEWLY_TAGGED" = "false" ] && [ "$VERSION" = "0.5.0" ]; then
    ok "root release commit on main -> Go lane tags nothing (still reports go v0.5.0, newly_tagged=false)"
  else
    no "root release commit on main -> Go lane tags nothing (got version=$VERSION newly_tagged=$NEWLY_TAGGED, log: $(cat "$WORKDIR/log8.txt"))"
  fi
  if [ ! -s "$PY_LOG" ] && [ ! -s "$GH_LOG" ]; then
    ok "root release commit on main -> Go lane invokes neither gh nor python3"
  else
    no "root release commit on main -> Go lane invokes neither gh nor python3 (gh: $(cat "$GH_LOG"); python3: $(cat "$PY_LOG"))"
  fi
else
  no "root release commit on main -> script must exit 0 ($(cat "$WORKDIR/log8.txt"))"
fi

# ── Test 9: a Go release commit with no go/CHANGELOG.md entry FAILS LOUD ──
# Empty body (as always now) and a tree that adds an entry to the ROOT
# CHANGELOG.md only — so this also pins that the Go lane reads ITS OWN
# changelog, never whichever one happens to have grown. The pre-#923 script
# tagged it, created a notes-less GitHub Release and dispatched the tagger,
# green. It must instead fail before tagging or dispatching anything. LAST on
# purpose: this untagged release commit stays the oldest candidate for every
# later run against this fixture.
prepend_changelog_entry "$WORK/CHANGELOG.md" $'# [1.74.0](url) (2026-10-17)\n\n* root-lane entry, not a Go one'
git -C "$WORK" add CHANGELOG.md
git -C "$WORK" commit -q -m "chore(release): go v0.6.0 (#916)"

: > "$GH_LOG"
: > "$PY_LOG"
: > "$WORKDIR/gh_output"
rm -f "$NOTES_SEEN"
if run_finish_go_release > "$WORKDIR/log9.txt" 2>&1; then
  no "Go release commit with no go/CHANGELOG.md entry -> script must exit NON-zero (it exited 0: $(cat "$WORKDIR/log9.txt"))"
else
  ok "Go release commit with no go/CHANGELOG.md entry -> script exits non-zero (fails loud)"
fi
if grep -q "go/CHANGELOG.md" "$WORKDIR/log9.txt"; then
  ok "Go release commit with no go/CHANGELOG.md entry -> the error names go/CHANGELOG.md"
else
  no "Go release commit with no go/CHANGELOG.md entry -> the error names go/CHANGELOG.md (log: $(cat "$WORKDIR/log9.txt"))"
fi
if git -C "$BARE" rev-parse --verify --quiet refs/tags/go-modules/v0.6.0 >/dev/null ||
   git -C "$WORK" rev-parse --verify --quiet refs/tags/go-modules/v0.6.0 >/dev/null; then
  no "Go release commit with no go/CHANGELOG.md entry -> tag go-modules/v0.6.0 must NOT be created or pushed (it was)"
else
  ok "Go release commit with no go/CHANGELOG.md entry -> tag go-modules/v0.6.0 is neither created nor pushed"
fi
if [ ! -s "$GH_LOG" ] && [ ! -s "$PY_LOG" ]; then
  ok "Go release commit with no go/CHANGELOG.md entry -> no GitHub Release, no tagger dispatch"
else
  no "Go release commit with no go/CHANGELOG.md entry -> no GitHub Release, no tagger dispatch (gh: $(cat "$GH_LOG"); python3: $(cat "$PY_LOG"))"
fi

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
