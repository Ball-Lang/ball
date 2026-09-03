#!/usr/bin/env bash
# Unit test for the conformance-count drift guard (issue #519).
#
# The guard is itself a gate, so it needs its own regression coverage: a lint
# that stops matching is indistinguishable from a lint that passes, which is the
# exact "nothing ran reads as all passed" trap it was written to close. Every
# case here drives tools/check_conformance_doc_counts.sh against a synthetic
# tree — no repo state, no toolchain, sub-second.
#
# Usage: bash tools/test/test_check_conformance_doc_counts.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/../check_conformance_doc_counts.sh"
[ -f "$GUARD" ] || {
  echo "::error::missing $GUARD"
  exit 1
}

pass=0
fail=0
LAST_OUT=""

# make_tree <fixture-count> <golden-less-count> — a synthetic repo root whose
# derived corpus total is <fixture-count>.
make_tree() {
  local goldens="$1" goldenless="$2" root i
  root="$(mktemp -d "$SCRATCH/tree.XXXXXX")"
  mkdir -p "$root/tests/conformance"
  for ((i = 1; i <= goldens; i++)); do
    printf '{}' >"$root/tests/conformance/$i.ball.json"
    printf 'ok\n' >"$root/tests/conformance/$i.expected_output.txt"
  done
  for ((i = 1; i <= goldenless; i++)); do
    printf '{}' >"$root/tests/conformance/skip$i.ball.json"
  done
  printf '%s' "$root"
}

run_guard() {
  local rc
  LAST_OUT="$(bash "$GUARD" --root "$1" 2>&1)"
  rc=$?
  return "$rc"
}

# expect <name> <want-exit> <root> [substring...]
expect() {
  local name="$1" want="$2" root="$3"
  shift 3
  local rc=0
  run_guard "$root" || rc=$?
  local ok=1
  [ "$rc" -eq "$want" ] || ok=0
  local needle
  for needle in "$@"; do
    case "$LAST_OUT" in
    *"$needle"*) ;;
    *) ok=0 ;;
    esac
  done
  if [ "$ok" -eq 1 ]; then
    pass=$((pass + 1))
    echo "PASS  $name"
  else
    fail=$((fail + 1))
    echo "FAIL  $name: expected exit $want, got $rc"
    printf '%s\n' "$LAST_OUT" | sed 's/^/  /'
  fi
}

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# ── 1. Docs that agree with the DERIVED total pass. ───────────────────────
root="$(make_tree 3 1)"
printf 'engine: `Results: 3 passed, 0 failed, 3 total (1 skipped carve-out)`\n' >"$root/A.md"
printf 'and here too: 3 passed, 0 failed, 3 total\n' >"$root/B.md"
expect "agreeing docs at the derived total -> exit 0" 0 "$root" \
  "expected total 3" "occurrences checked: 2" "OK"

# ── 2. Two docs disagreeing with the derived total are BOTH named. ────────
# The guard is derived, not consensus-based, so "everyone agrees on the wrong
# number" is still a failure — the case a consistency-only lint cannot see.
root="$(make_tree 3 1)"
printf 'stale: `Results: 4 passed, 0 failed, 4 total`\n' >"$root/A.md"
printf 'staler: 5 passed, 0 failed, 5 total\n' >"$root/B.md"
expect "two disagreeing docs -> exit 1 naming both file:line" 1 "$root" \
  "A.md:1:" "B.md:1:" "disagree with the derived total 3"

# ── 3. All docs agreeing with each other but NOT with the repo still fails. ──
root="$(make_tree 3 1)"
printf 'a: 7 passed, 0 failed, 7 total\n' >"$root/A.md"
printf 'b: 7 passed, 0 failed, 7 total\n' >"$root/B.md"
expect "mutually consistent but wrong -> exit 1" 1 "$root" \
  "A.md:1:" "B.md:1:"

# ── 4. The line wrapped across a newline is still found. ──────────────────
# Several real docs break the paragraph between `... passed,` and `0 failed,`;
# a line-at-a-time matcher silently misses those, which is how .claude/rules/
# go.md and rust/AGENTS.md drifted unnoticed.
root="$(make_tree 3 1)"
printf 'wrapped (`Results: 9 passed,\n0 failed, 9 total`) here\n' >"$root/A.md"
printf 'fine: 3 passed, 0 failed, 3 total\n' >"$root/B.md"
expect "a wrapped occurrence is detected -> exit 1" 1 "$root" "A.md:1:"

# ── 5. A `corpus-count: historical` line is deliberately skipped. ─────────
root="$(make_tree 3 1)"
printf 'phase log: 1 passed, 0 failed, 1 total <!-- corpus-count: historical -->\n' >"$root/A.md"
printf 'current: 3 passed, 0 failed, 3 total\n' >"$root/B.md"
expect "a historical-marked line is skipped -> exit 0" 0 "$root" \
  "historical occurrences skipped" "occurrences checked: 1"

# ── 6. CHANGELOG.md is never rewritten, so it is never gated. ─────────────
root="$(make_tree 3 1)"
printf 'release log: 1 passed, 0 failed, 1 total\n' >"$root/CHANGELOG.md"
printf 'current: 3 passed, 0 failed, 3 total\n' >"$root/B.md"
expect "CHANGELOG.md is excluded -> exit 0" 0 "$root" "occurrences checked: 1"

# ── 7. The degenerate all-zero sentinel is a quoted counter-example. ──────
root="$(make_tree 3 1)"
printf 'guard prose: a literal "0 passed, 0 failed, 0 total" must not pass\n' >"$root/A.yml"
printf 'current: 3 passed, 0 failed, 3 total\n' >"$root/B.md"
expect "the 0/0/0 sentinel is skipped -> exit 0" 0 "$root" \
  "sentinel quotes skipped: 1" "occurrences checked: 1"

# ── 8. Passed and total must AGREE with each other, not just with N. ──────
root="$(make_tree 3 1)"
printf 'half-updated: 3 passed, 0 failed, 4 total\n' >"$root/A.md"
expect "passed != total -> exit 1" 1 "$root" "A.md:1:"

# ── 9. Zero scanned occurrences is a FAILURE, not a pass. ─────────────────
# Positive floor: a lint whose pattern drifted must go red, not quietly green.
root="$(make_tree 3 1)"
printf 'no numbers here at all\n' >"$root/A.md"
expect "zero occurrences scanned -> exit 1" 1 "$root" "scanned zero current-status occurrences"

# ── 10. An empty/moved fixture dir cannot silently become the ground truth. ──
root="$(make_tree 0 0)"
printf 'anything: 3 passed, 0 failed, 3 total\n' >"$root/A.md"
expect "no golden-having fixtures -> exit 1" 1 "$root" "cannot derive the corpus total"

# ── 11. --expect overrides the derivation (used to pin a measured CI value). ──
root="$(make_tree 3 1)"
printf 'x: 11 passed, 0 failed, 11 total\n' >"$root/A.md"
out_rc=0
LAST_OUT="$(bash "$GUARD" --root "$root" --expect 11 2>&1)" || out_rc=$?
if [ "$out_rc" -eq 0 ]; then
  pass=$((pass + 1))
  echo "PASS  --expect overrides the derived total -> exit 0"
else
  fail=$((fail + 1))
  echo "FAIL  --expect overrides the derived total: expected exit 0, got $out_rc"
  printf '%s\n' "$LAST_OUT" | sed 's/^/  /'
fi

total=$((pass + fail))
if [ "$total" -lt 1 ]; then
  echo "::error::conformance-count guard test ran zero cases"
  exit 1
fi
echo "Results: $pass passed, $fail failed, $total total"
[ "$fail" -eq 0 ] || exit 1
