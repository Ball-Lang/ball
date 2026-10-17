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
# It also copies the file a `--notes-file` argument names into NOTES_SEEN,
# because finish_release.sh deletes its own temp notes file on exit: without
# the copy a test could only see THAT `gh release create` ran, never WHAT
# notes the GitHub Release would have carried (issue #923 — they went blank).
STUBDIR="$WORKDIR/stubbin"
mkdir -p "$STUBDIR"
GH_LOG="$WORKDIR/gh_invocations.log"
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

# ── the release commit, shaped the way GitHub actually lands it ───────────
# `main` squash-merges with `squash_merge_commit_title: PR_TITLE` and
# `squash_merge_commit_message: BLANK` (issue #881), so a release-PR merge
# reaches `main` as "<PR title>" (+ " (#N)" from the merge queue) with an
# EMPTY body — `git log -1 --format=%b` reads "" — while its TREE still carries
# the CHANGELOG.md entry the release PR's own commit prepended
# (open_release_pr.sh -> apply_version_bump.mjs -> prependChangelogEntry).
# This writes that entry through the REAL prependChangelogEntry, not a bash
# re-implementation of it, so the fixture cannot drift from the writer.
CHANGELOG_LIB="$HERE/../lib/changelog_entry.mjs"
prepend_changelog_entry() {
  # $1: the changelog file to edit in place, $2: the entry (notes) to prepend.
  node --input-type=module -e '
    import { existsSync, readFileSync, writeFileSync } from "node:fs";
    import { pathToFileURL } from "node:url";
    const [lib, file, notes] = process.argv.slice(1);
    const { prependChangelogEntry } = await import(pathToFileURL(lib).href);
    const current = existsSync(file) ? readFileSync(file, "utf8") : "";
    writeFileSync(file, prependChangelogEntry(current, notes));
  ' "$CHANGELOG_LIB" "$1" "$2"
}

# land_release_commit <subject> <changelog entry> [body]
# The body defaults to EMPTY, the only shape `main` produces now; a non-empty
# one is accepted only to prove the notes never come from it.
land_release_commit() {
  prepend_changelog_entry "$WORK/CHANGELOG.md" "$2"
  git -C "$WORK" add CHANGELOG.md
  if [ -n "${3:-}" ]; then
    printf '%s\n\n%s\n' "$1" "$3" | git -C "$WORK" commit -q -F -
  else
    git -C "$WORK" commit -q -m "$1"
  fi
}

# notes_seen: what the last `gh release create --notes-file` carried, or ""
# when gh never got a notes file (a missing file is an expected outcome here,
# named rather than swallowed).
notes_seen() {
  if [ -f "$NOTES_SEEN" ]; then cat "$NOTES_SEEN"; fi
}

run_finish_release() {
  PATH="$STUBDIR:$PATH" BALL_REPO_ROOT="$WORK" GITHUB_OUTPUT="$WORKDIR/gh_output" bash "$SCRIPT"
}

output_value() {
  # $1: key. Reads the last-written value for that key from GITHUB_OUTPUT, or
  # "" if the script never wrote that key at all (the true-no-op path writes
  # no `version=` line — under `set -o pipefail` a bare `grep | tail | cut`
  # trips `set -e` the moment `grep` finds nothing, since tail/cut still exit
  # 0 and pipefail then reports grep's own non-zero status; this explicit
  # `|| line=""` names that expected outcome instead of swallowing it blind).
  local line
  line="$(grep "^$1=" "$WORKDIR/gh_output" 2>/dev/null | tail -1)" || line=""
  printf '%s\n' "${line#*=}"
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
# The commit is real-shaped (issue #923): EMPTY body, CHANGELOG.md entry in
# its tree. Before #923 the script read the notes from `git log --format=%b`,
# which is "" here, so the GitHub Release would have shipped with no notes.
ENTRY_173=$'## [1.73.0](url) (2026-10-17)\n\n### Features\n\n* new thing'
land_release_commit "chore(release): 1.73.0" "$ENTRY_173"

: > "$GH_LOG"
: > "$WORKDIR/gh_output"
rm -f "$NOTES_SEEN"
if run_finish_release > "$WORKDIR/log2.txt" 2>&1; then
  BODY="$(git -C "$WORK" log -1 --format=%b HEAD)"
  if [ -z "$BODY" ]; then
    ok "fixture -> the release commit's body is EMPTY, as squash_merge_commit_message: BLANK writes it"
  else
    no "fixture -> the release commit's body is EMPTY (got: $BODY)"
  fi
  if [ "$(notes_seen)" = "$ENTRY_173" ]; then
    ok "empty-body release commit -> GitHub Release notes are the CHANGELOG.md entry it added (non-empty)"
  else
    no "empty-body release commit -> GitHub Release notes are the CHANGELOG.md entry it added (got: '$(notes_seen)', log: $(cat "$WORKDIR/log2.txt"))"
  fi
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

# ── Test 4: a commit lands in the gap between the release-PR merge and the
# next poll — the release commit is no longer at HEAD (PR #881 review, round
# 2, finding 1). Against the pre-fix script (HEAD-only `git log -1`), this
# reproduces the exact bug: HEAD is "fix: unrelated", does not match
# `chore(release): …`, and v2.0.0 is NEVER tagged. The fix scans every commit
# since the last tag for the release commit instead of trusting HEAD.
# This one release commit DOES carry a body, and a stale one, to pin issue
# #923's other half: the notes come from the tree, never from the message,
# whatever a future squash setting puts there. ───────────────────────────
ENTRY_200=$'# [2.0.0](url) (2026-10-17)\n\n### Features\n\n* second thing'
land_release_commit "chore(release): 2.0.0" "$ENTRY_200" "stale body -- must never become the release notes"
RELEASE_COMMIT_SHA="$(git -C "$WORK" rev-parse HEAD)"
git -C "$WORK" commit -q --allow-empty -m "fix: unrelated PR merged before the next poll tick"
GAP_HEAD_SHA="$(git -C "$WORK" rev-parse HEAD)"

: > "$GH_LOG"
: > "$WORKDIR/gh_output"
rm -f "$NOTES_SEEN"
if run_finish_release > "$WORKDIR/log4.txt" 2>&1; then
  if [ "$(notes_seen)" = "$ENTRY_200" ]; then
    ok "release commit followed by another commit -> notes are ITS changelog entry, not its (stale) body"
  else
    no "release commit followed by another commit -> notes are ITS changelog entry, not its (stale) body (got: '$(notes_seen)')"
  fi
  IS_RELEASE="$(output_value is_release)"
  VERSION="$(output_value version)"
  if [ "$IS_RELEASE" = "true" ] && [ "$VERSION" = "2.0.0" ]; then
    ok "release commit followed by another commit -> is_release=true, version=2.0.0 (found despite not being at HEAD)"
  else
    no "release commit followed by another commit -> is_release=true, version=2.0.0 (got is_release=$IS_RELEASE version=$VERSION, log: $(cat "$WORKDIR/log4.txt"))"
  fi
  NEWLY_TAGGED="$(output_value newly_tagged)"
  if [ "$NEWLY_TAGGED" = "true" ]; then
    ok "release commit followed by another commit -> newly_tagged=true"
  else
    no "release commit followed by another commit -> newly_tagged=true (got: $NEWLY_TAGGED)"
  fi
  if git -C "$BARE" rev-parse --verify refs/tags/v2.0.0 >/dev/null 2>&1; then
    ok "release commit followed by another commit -> tag v2.0.0 pushed to origin"
  else
    no "release commit followed by another commit -> tag v2.0.0 pushed to origin"
  fi
  TAG_TARGET_SHA="$(git -C "$WORK" rev-parse refs/tags/v2.0.0^{commit} 2>/dev/null || true)"
  if [ "$TAG_TARGET_SHA" = "$RELEASE_COMMIT_SHA" ]; then
    ok "release commit followed by another commit -> tag v2.0.0 points at the RELEASE commit, not HEAD"
  else
    no "release commit followed by another commit -> tag v2.0.0 points at the release commit $RELEASE_COMMIT_SHA (got: $TAG_TARGET_SHA, HEAD was $GAP_HEAD_SHA)"
  fi
  if grep -q "^release create v2.0.0 " "$GH_LOG"; then
    ok "release commit followed by another commit -> gh release create v2.0.0 invoked"
  else
    no "release commit followed by another commit -> gh release create v2.0.0 invoked (log: $(cat "$GH_LOG"))"
  fi
else
  no "release commit followed by another commit -> script must exit 0 ($(cat "$WORKDIR/log4.txt"))"
fi

# ── Test 5: polling again after the gap-commit race is still a safe no-op,
# even though HEAD is the unrelated commit, not a tagged one ───────────────
: > "$GH_LOG"
: > "$WORKDIR/gh_output"
if run_finish_release > "$WORKDIR/log5.txt" 2>&1; then
  IS_RELEASE="$(output_value is_release)"
  VERSION="$(output_value version)"
  if [ "$IS_RELEASE" = "true" ] && [ "$VERSION" = "2.0.0" ]; then
    ok "poll after the gap-commit race -> is_release=true, version=2.0.0 (still reports the last release)"
  else
    no "poll after the gap-commit race -> is_release=true, version=2.0.0 (got is_release=$IS_RELEASE version=$VERSION)"
  fi
  NEWLY_TAGGED="$(output_value newly_tagged)"
  if [ "$NEWLY_TAGGED" = "false" ]; then
    ok "poll after the gap-commit race -> newly_tagged=false (must not re-dispatch publishing)"
  else
    no "poll after the gap-commit race -> newly_tagged=false (got: $NEWLY_TAGGED)"
  fi
  if [ ! -s "$GH_LOG" ]; then
    ok "poll after the gap-commit race -> gh never invoked again"
  else
    no "poll after the gap-commit race -> gh never invoked again (log: $(cat "$GH_LOG"))"
  fi
else
  no "poll after the gap-commit race -> script must exit 0 ($(cat "$WORKDIR/log5.txt"))"
fi

# ── Test 6: the release commit as the MERGE QUEUE actually writes it ───────
# `main` requires a merge queue (ruleset 17056238's `merge_queue` rule,
# merge_method SQUASH). A queue squash ignores the subject/body
# `gh pr merge --auto --subject` asked for and uses the repository defaults,
# `squash_merge_commit_title: PR_TITLE` / `squash_merge_commit_message: BLANK`
# (issue #881): "<the PR's title> (#<PR number>)" with NO body at all
# (https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/incorporating-changes-from-a-pull-request/about-pull-request-merges#merge-message-for-a-squash-merge;
# every queue-merged commit on main has this shape, e.g. 009fad1c "… (#905)").
# PR #881 review round 3, finding 1: the `$`-anchored subject pattern rejected
# the suffix, so a real release commit was never tagged and nothing published.
ENTRY_210=$'# [2.1.0](url) (2026-10-17)\n\n### Features\n\n* queued thing'
land_release_commit "chore(release): 2.1.0 (#912)" "$ENTRY_210"
QUEUE_RELEASE_SHA="$(git -C "$WORK" rev-parse HEAD)"

: > "$GH_LOG"
: > "$WORKDIR/gh_output"
rm -f "$NOTES_SEEN"
if run_finish_release > "$WORKDIR/log6.txt" 2>&1; then
  if [ "$(notes_seen)" = "$ENTRY_210" ]; then
    ok "merge-queue squash (empty body) -> notes are the 2.1.0 changelog entry alone, none of the older entries"
  else
    no "merge-queue squash (empty body) -> notes are the 2.1.0 changelog entry alone (got: '$(notes_seen)')"
  fi
  IS_RELEASE="$(output_value is_release)"
  VERSION="$(output_value version)"
  if [ "$IS_RELEASE" = "true" ] && [ "$VERSION" = "2.1.0" ]; then
    ok "merge-queue squash subject '(#912)' -> is_release=true, version=2.1.0 (the PR number is not part of the version)"
  else
    no "merge-queue squash subject '(#912)' -> is_release=true, version=2.1.0 (got is_release=$IS_RELEASE version=$VERSION, log: $(cat "$WORKDIR/log6.txt"))"
  fi
  NEWLY_TAGGED="$(output_value newly_tagged)"
  if [ "$NEWLY_TAGGED" = "true" ]; then
    ok "merge-queue squash subject -> newly_tagged=true"
  else
    no "merge-queue squash subject -> newly_tagged=true (got: $NEWLY_TAGGED)"
  fi
  TAG_TARGET_SHA="$(git -C "$BARE" rev-parse --verify --quiet refs/tags/v2.1.0^{commit})" || TAG_TARGET_SHA=""
  if [ "$TAG_TARGET_SHA" = "$QUEUE_RELEASE_SHA" ]; then
    ok "merge-queue squash subject -> tag v2.1.0 pushed to origin, at the release commit"
  else
    no "merge-queue squash subject -> tag v2.1.0 pushed to origin at $QUEUE_RELEASE_SHA (got: '$TAG_TARGET_SHA')"
  fi
  if grep -q "^release create v2.1.0 --title 2.1.0 " "$GH_LOG"; then
    ok "merge-queue squash subject -> gh release create v2.1.0 --title 2.1.0"
  else
    no "merge-queue squash subject -> gh release create v2.1.0 --title 2.1.0 (log: $(cat "$GH_LOG"))"
  fi
else
  no "merge-queue squash subject -> script must exit 0 ($(cat "$WORKDIR/log6.txt"))"
fi

# ── Test 7: re-polling a queue-shaped release is still a safe no-op ───────
# This walks the OTHER subject match: no candidate since v2.1.0, so the
# script falls back to reporting v2.1.0's own commit, whose subject carries
# the same "(#912)" suffix.
: > "$GH_LOG"
: > "$WORKDIR/gh_output"
if run_finish_release > "$WORKDIR/log7.txt" 2>&1; then
  IS_RELEASE="$(output_value is_release)"
  VERSION="$(output_value version)"
  NEWLY_TAGGED="$(output_value newly_tagged)"
  if [ "$IS_RELEASE" = "true" ] && [ "$VERSION" = "2.1.0" ] && [ "$NEWLY_TAGGED" = "false" ]; then
    ok "re-poll of a queue-shaped release -> is_release=true, version=2.1.0, newly_tagged=false"
  else
    no "re-poll of a queue-shaped release -> is_release=true, version=2.1.0, newly_tagged=false (got is_release=$IS_RELEASE version=$VERSION newly_tagged=$NEWLY_TAGGED)"
  fi
  if [ ! -s "$GH_LOG" ]; then
    ok "re-poll of a queue-shaped release -> gh never invoked again"
  else
    no "re-poll of a queue-shaped release -> gh never invoked again (log: $(cat "$GH_LOG"))"
  fi
else
  no "re-poll of a queue-shaped release -> script must exit 0 ($(cat "$WORKDIR/log7.txt"))"
fi

# ── Test 8: the Go lane's release commit is NOT a root release ────────────
# Both lanes share the `chore(release):` prefix and the same `main`, so the
# root pattern must never read "go v0.5.0" as a root version (it would cut a
# bogus `vgo` tag and dispatch npm/C++/Go/pub.dev for it).
git -C "$WORK" commit -q --allow-empty -m "chore(release): go v0.5.0 (#913)"

: > "$GH_LOG"
: > "$WORKDIR/gh_output"
if run_finish_release > "$WORKDIR/log8.txt" 2>&1; then
  NEWLY_TAGGED="$(output_value newly_tagged)"
  VERSION="$(output_value version)"
  if [ "$NEWLY_TAGGED" = "false" ] && [ "$VERSION" = "2.1.0" ]; then
    ok "Go release commit on main -> root lane tags nothing (still reports v2.1.0, newly_tagged=false)"
  else
    no "Go release commit on main -> root lane tags nothing (got version=$VERSION newly_tagged=$NEWLY_TAGGED, log: $(cat "$WORKDIR/log8.txt"))"
  fi
  if [ ! -s "$GH_LOG" ]; then
    ok "Go release commit on main -> root lane never invokes gh"
  else
    no "Go release commit on main -> root lane never invokes gh (log: $(cat "$GH_LOG"))"
  fi
else
  no "Go release commit on main -> script must exit 0 ($(cat "$WORKDIR/log8.txt"))"
fi

# ── Test 9: a release commit with no notes anywhere FAILS LOUD (#923) ─────
# Empty body (as always now) AND a tree that adds no CHANGELOG.md entry: there
# are no notes to publish. The pre-#923 script tagged it and created a GitHub
# Release with an empty body, green — the silent downgrade #923 reports. It
# must instead fail before tagging anything, so the next poll retries from a
# clean state once a human has looked. LAST on purpose: this untagged release
# commit stays the oldest candidate for every later run against this fixture.
git -C "$WORK" commit -q --allow-empty -m "chore(release): 2.2.0 (#915)"

: > "$GH_LOG"
: > "$WORKDIR/gh_output"
rm -f "$NOTES_SEEN"
if run_finish_release > "$WORKDIR/log9.txt" 2>&1; then
  no "release commit with no changelog entry -> script must exit NON-zero (it exited 0: $(cat "$WORKDIR/log9.txt"))"
else
  ok "release commit with no changelog entry -> script exits non-zero (fails loud)"
fi
if grep -q "CHANGELOG.md" "$WORKDIR/log9.txt"; then
  ok "release commit with no changelog entry -> the error names CHANGELOG.md"
else
  no "release commit with no changelog entry -> the error names CHANGELOG.md (log: $(cat "$WORKDIR/log9.txt"))"
fi
if git -C "$BARE" rev-parse --verify --quiet refs/tags/v2.2.0 >/dev/null; then
  no "release commit with no changelog entry -> tag v2.2.0 must NOT be pushed (it was)"
else
  ok "release commit with no changelog entry -> tag v2.2.0 is not pushed"
fi
if git -C "$WORK" rev-parse --verify --quiet refs/tags/v2.2.0 >/dev/null; then
  no "release commit with no changelog entry -> tag v2.2.0 must NOT be created locally (it was)"
else
  ok "release commit with no changelog entry -> tag v2.2.0 is not created locally"
fi
if [ ! -s "$GH_LOG" ]; then
  ok "release commit with no changelog entry -> gh never invoked (no notes-less GitHub Release)"
else
  no "release commit with no changelog entry -> gh never invoked (log: $(cat "$GH_LOG"))"
fi

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
