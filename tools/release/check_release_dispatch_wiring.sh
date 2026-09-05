#!/usr/bin/env bash
# Static wiring guard for the release pipeline's downstream dispatches (#361).
#
# WHY THIS EXISTS: this repo cuts releases from `release.yml` (semantic-release).
# Its `@semantic-release/git` plugin pushes a `chore(release): X.Y.Z [skip ci]`
# commit, and GitHub's skip-ci recursion protection suppresses the ENTIRE
# workflow run for any `push`-triggered workflow on such a commit — not merely
# the job's own `if:`. Anything hung off `on: push: branches:[main]` +
# `if: contains(head_commit.message, 'chore(release)')` therefore never runs on
# the commits it targets, and the failure is INVISIBLE: no run row appears at
# all, so a dashboard reads "nothing red" while the channel silently never
# ships. That is exactly what happened to `tag-go-modules` — 5+ releases shipped
# and `gh api repos/Ball-Lang/ball/git/matching-refs/tags/go%2F` still returned
# `[]`.
#
# The repo's own documented workaround, already used for npm and C++, is an
# explicit `gh workflow run <file> --ref "v<version>"` step in release.yml,
# guarded on `steps.semrel.outputs.released_version != ''`, pointed at a
# workflow that declares `workflow_dispatch:`. This guard pins that four-part
# contract for every release-reactive channel so a future one cannot be added
# with the unreachable push trigger again.
#
# Deliberately textual/grep-based against the DOCUMENTED pattern (same style as
# tools/check_conformance_doc_counts.sh): it asserts the four things that make a
# channel reachable, not the incidental shape of the YAML around them, so a
# legitimate refactor of dispatch style does not false-red.
#
# Usage: bash tools/release/check_release_dispatch_wiring.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORKFLOWS="$ROOT/.github/workflows"
RELEASE="$WORKFLOWS/release.yml"
RELEASE_TAG="$WORKFLOWS/release-tag.yml"

# Every workflow that must react to a release side effect. Adding a channel here
# without wiring its dispatch is a hard failure, by design.
TARGETS="publish-npm.yml release-cpp.yml tag-go-modules.yml"

pass=0
fail=0

ok() {
  pass=$((pass + 1))
  echo "PASS  $1"
}

no() {
  fail=$((fail + 1))
  echo "FAIL  $1"
  shift
  local line
  for line in "$@"; do printf '  %s\n' "$line"; done
}

for f in "$RELEASE" "$RELEASE_TAG"; do
  [ -f "$f" ] || {
    echo "::error::missing $f"
    exit 1
  }
done

# ── 1..4 per target. ──────────────────────────────────────────────────────
for target in $TARGETS; do
  file="$WORKFLOWS/$target"

  # (1) The dispatch target exists at all.
  if [ -f "$file" ]; then
    ok "$target exists"
  else
    no "$target exists" \
      "release.yml cannot dispatch a workflow file that is not in .github/workflows/"
    # Nothing further about this target is meaningful without the file.
    continue
  fi

  # (2) It accepts workflow_dispatch — without this, `gh workflow run` 422s.
  if grep -qE '^[[:space:]]*workflow_dispatch:' "$file"; then
    ok "$target declares a workflow_dispatch trigger"
  else
    no "$target declares a workflow_dispatch trigger" \
      "gh workflow run cannot invoke a workflow that does not opt into workflow_dispatch"
  fi

  # (3) release.yml actually dispatches it, pinned to the fresh release tag.
  # The `--ref v<released_version>` pin is load-bearing: an unpinned dispatch
  # runs the workflow off the default branch, which for a tag-cutting or
  # asset-uploading channel is a different commit than the one released.
  if grep -qF "gh workflow run $target --ref \"v\${{ steps.semrel.outputs.released_version }}\"" "$RELEASE"; then
    ok "release.yml dispatches $target pinned to the fresh release tag"
  else
    no "release.yml dispatches $target pinned to the fresh release tag" \
      "expected a step running: gh workflow run $target --ref \"v\${{ steps.semrel.outputs.released_version }}\"" \
      "a push-triggered workflow cannot substitute — semantic-release's commit carries [skip ci], which suppresses the whole run"
  fi

  # (4) That dispatch is guarded on a release actually having been cut.
  # Checked by locating the dispatch line and looking back a bounded window for
  # the guard, so an unguarded step cannot borrow a neighbour's `if:`.
  line="$(grep -nF "gh workflow run $target --ref" "$RELEASE" | head -1 | cut -d: -f1)"
  if [ -n "$line" ]; then
    start=$((line - 8))
    [ "$start" -lt 1 ] && start=1
    if sed -n "${start},${line}p" "$RELEASE" |
      grep -qF "if: steps.semrel.outputs.released_version != ''"; then
      ok "the $target dispatch is guarded on released_version != ''"
    else
      no "the $target dispatch is guarded on released_version != ''" \
        "an unguarded dispatch fires on every push to main, releasing or not"
    fi
  else
    no "the $target dispatch is guarded on released_version != ''" \
      "no dispatch line for $target to guard"
  fi
done

# ── 5. Regression guard: the unreachable push trigger must not come back. ──
# tag-go-modules lived in release-tag.yml behind `on: push: branches:[main]` +
# `if: contains(head_commit.message, 'chore(release)')`. That shape is proven
# unreachable for `chore(release): X.Y.Z [skip ci]` commits; re-adding it would
# silently resurrect the dead channel next to the live one.
if grep -q 'tag-go-modules' "$RELEASE_TAG"; then
  no "release-tag.yml no longer carries a tag-go-modules job" \
    "release-tag.yml is push-triggered, so a tag-go-modules job there can never fire on a semantic-release commit" \
    "Go tagging lives in .github/workflows/tag-go-modules.yml, dispatched from release.yml"
else
  ok "release-tag.yml no longer carries a tag-go-modules job"
fi

# ── 6. This guard is itself wired into an always-run CI job. ──────────────
if grep -q 'tools/release/check_release_dispatch_wiring.sh' "$WORKFLOWS/ci.yml"; then
  ok "ci.yml runs this guard"
else
  no "ci.yml runs this guard" "a guard nothing invokes is not a guard"
fi

total=$((pass + fail))
# Positive floor: an exit code plus a zero failure count cannot tell "all
# passed" from "nothing ran". Four assertions per target plus two global ones.
MIN=3
case "$pass$fail$total" in
*[!0-9]*)
  echo "::error::release dispatch wiring guard produced a non-numeric tally"
  exit 1
  ;;
esac
if [ "$total" -lt "$MIN" ]; then
  echo "::error::release dispatch wiring guard ran $total cases, expected at least $MIN — the sweep itself is broken"
  exit 1
fi
echo "Results: $pass passed, $fail failed, $total total"
[ "$fail" -eq 0 ] || exit 1
