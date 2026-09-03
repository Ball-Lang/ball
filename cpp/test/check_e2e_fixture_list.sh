#!/usr/bin/env bash
# Drift guard for cpp/test/e2e_fixture_list.h (issues #63 / #59, gap flagged by
# #511).
#
# WHY THIS EXISTS: e2e_fixture_list.h is the single list of programs the C++ e2e
# test (cpp/test/test_e2e.cpp) compiles + builds + runs, and that the fast
# coverage driver (cpp/test/corpus_driver.cpp) compiles. It is hand-maintained,
# and NOTHING checked it against the real corpus — so it silently stopped at
# `399_bytes_literal` and missed every fixture from 400 onward until #529
# extended it by hand. A hand-extended list goes stale the same way the next
# time someone adds a fixture; only a gate stops that.
#
# WHAT IT ASSERTS
#   1. Every runnable fixture (a `.ball.json` with a sibling
#      `.expected_output.txt`, in tests/conformance/ or
#      tests/fixtures/dart/_generated/) is either LISTED in the header or named
#      in the known-gaps file next to this script.
#   2. Every name in the header actually resolves to such a fixture — so a
#      rename or deletion cannot leave a phantom entry behind.
#   3. The known-gaps file is a RATCHET, not a dumping ground: an entry that is
#      now listed, or that names a fixture that no longer exists, is an error.
#      The debt can only shrink.
#
# The known-gaps file freezes the 90 fixtures (the 257-397 band) that were
# already unlisted when this guard was written. Closing that backlog means
# wiring each one into the e2e list and deleting its line here; it is
# deliberately NOT done in the same change as the guard, because each addition
# costs a nested per-fixture cmake+g++ build in CI and has to be verified to
# actually pass on the C++ target first.
#
# Wired into ci.yml's always-on `proto` job (no `needs` gate, no job-level
# `if`), next to the other CI-plumbing tests, so it runs on every PR with no
# toolchain. Sub-second.
#
# Usage:
#   bash cpp/test/check_e2e_fixture_list.sh              # check this repo
#   bash cpp/test/check_e2e_fixture_list.sh --self-test  # prove the guard bites
#
# Path overrides (used only by --self-test):
#   BALL_E2E_LIST, BALL_E2E_KNOWN_GAPS, BALL_CONFORMANCE_DIR, BALL_GENERATED_DIR

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

LIST="${BALL_E2E_LIST:-$HERE/e2e_fixture_list.h}"
GAPS="${BALL_E2E_KNOWN_GAPS:-$HERE/e2e_fixture_list_known_gaps.txt}"
CONF_DIR="${BALL_CONFORMANCE_DIR:-$ROOT/tests/conformance}"
GEN_DIR="${BALL_GENERATED_DIR:-$ROOT/tests/fixtures/dart/_generated}"

# ── the check ────────────────────────────────────────────────────────────────

# listed_names — one fixture name per line, from the header's quoted entries.
listed_names() {
  grep -oE '^[[:space:]]*"[^"]+",[[:space:]]*$' "$1" |
    sed -E 's/^[[:space:]]*"//; s/",[[:space:]]*$//' |
    sort -u
}

# available_names <dir>... — every `<name>.ball.json` that has a sibling
# `<name>.expected_output.txt`. A fixture with no golden is not runnable e2e
# (the 4 resource-limit/sandbox carve-outs), so it is not expected in the list.
available_names() {
  local d f base
  for d in "$@"; do
    [ -d "$d" ] || continue
    for f in "$d"/*.ball.json; do
      [ -e "$f" ] || continue
      base="$(basename "$f" .ball.json)"
      [ -f "$d/$base.expected_output.txt" ] && printf '%s\n' "$base"
    done
  done | sort -u
}

# known_gap_names — the frozen debt list, comments and blanks stripped.
known_gap_names() {
  [ -f "$1" ] || return 0
  sed -E 's/#.*$//; s/[[:space:]]+$//' "$1" | grep -v '^$' | sort -u
}

# run_check — prints its own findings; returns 0 when the list is in sync.
run_check() {
  local listed available gaps
  listed="$(listed_names "$LIST")"
  available="$(available_names "$CONF_DIR" "$GEN_DIR")"
  gaps="$(known_gap_names "$GAPS")"

  local n_listed n_avail rc=0
  n_listed="$(printf '%s' "$listed" | grep -c . || true)"
  n_avail="$(printf '%s' "$available" | grep -c . || true)"

  # Positive floor: an empty haystack would make every diff below vacuously
  # clean, so "nothing was found" must not read as "nothing drifted".
  if [ "$n_listed" -lt 1 ]; then
    echo "::error::$LIST yielded zero fixture names — the parser or the file is broken."
    return 1
  fi
  if [ "$n_avail" -lt 1 ]; then
    echo "::error::found zero runnable fixtures under $CONF_DIR / $GEN_DIR."
    return 1
  fi

  local unlisted stale_listed stale_gap_listed stale_gap_missing
  unlisted="$(comm -23 <(printf '%s\n' "$available") \
    <(printf '%s\n' "$listed" "$gaps" | sort -u))"
  stale_listed="$(comm -23 <(printf '%s\n' "$listed") <(printf '%s\n' "$available"))"
  stale_gap_listed="$(comm -12 <(printf '%s\n' "$gaps") <(printf '%s\n' "$listed"))"
  stale_gap_missing="$(comm -23 <(printf '%s\n' "$gaps") <(printf '%s\n' "$available"))"

  if [ -n "$unlisted" ]; then
    rc=1
    echo "::error::these runnable fixtures are missing from $(basename "$LIST"):"
    printf '  %s\n' $unlisted
    echo "  Add each to program_names() in cpp/test/e2e_fixture_list.h (and make"
    echo "  sure it actually compiles and runs on the C++ target), or, only with"
    echo "  justification, add it to $(basename "$GAPS")."
  fi
  if [ -n "$stale_listed" ]; then
    rc=1
    echo "::error::these entries in $(basename "$LIST") name no runnable fixture:"
    printf '  %s\n' $stale_listed
    echo "  A fixture was renamed or deleted; drop the stale entries."
  fi
  if [ -n "$stale_gap_listed" ]; then
    rc=1
    echo "::error::these entries in $(basename "$GAPS") are already listed:"
    printf '  %s\n' $stale_gap_listed
    echo "  The debt list is a ratchet — remove them so it can only shrink."
  fi
  if [ -n "$stale_gap_missing" ]; then
    rc=1
    echo "::error::these entries in $(basename "$GAPS") name no runnable fixture:"
    printf '  %s\n' $stale_gap_missing
    echo "  Remove them; the debt list must describe fixtures that exist."
  fi

  if [ "$rc" -eq 0 ]; then
    local n_gaps
    n_gaps="$(printf '%s' "$gaps" | grep -c . || true)"
    echo "e2e fixture list in sync: $n_listed listed, $n_avail runnable, $n_gaps known gaps."
  fi
  return "$rc"
}

# ── self-test ────────────────────────────────────────────────────────────────
# Proves the guard actually bites, against synthetic trees. Without this, a
# guard that silently found nothing to compare would report success forever.

self_test() {
  local pass=0 fail=0

  # scenario <name> <expected rc> <fixtures> <listed> <gaps>
  # Each of the last three is a space-separated set of fixture names.
  scenario() {
    local name="$1" want="$2" fixtures="$3" listed="$4" gaps="$5"
    local tmp rc out n
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/conf" "$tmp/gen"
    for n in $fixtures; do
      : >"$tmp/conf/$n.ball.json"
      : >"$tmp/conf/$n.expected_output.txt"
    done
    {
      echo 'inline const std::vector<std::string>& program_names() {'
      echo '    static const std::vector<std::string> names = {'
      for n in $listed; do printf '        "%s",\n' "$n"; done
      echo '    };'
      echo '}'
    } >"$tmp/list.h"
    : >"$tmp/gaps.txt"
    for n in $gaps; do printf '%s\n' "$n" >>"$tmp/gaps.txt"; done

    out="$(BALL_E2E_LIST="$tmp/list.h" BALL_E2E_KNOWN_GAPS="$tmp/gaps.txt" \
      BALL_CONFORMANCE_DIR="$tmp/conf" BALL_GENERATED_DIR="$tmp/gen" \
      bash "$HERE/$(basename "${BASH_SOURCE[0]}")" 2>&1)"
    rc=$?
    rm -rf "$tmp"
    if [ "$rc" -eq "$want" ]; then
      pass=$((pass + 1))
      echo "PASS  $name"
    else
      fail=$((fail + 1))
      echo "FAIL  $name: expected exit $want, got $rc"
      printf '  %s\n' "$out"
    fi
  }

  scenario "list covers every fixture -> exit 0" 0 "a b" "a b" ""
  scenario "a new fixture missing from the list -> exit 1" 1 "a b c" "a b" ""
  scenario "a known gap absorbs an unlisted fixture -> exit 0" 0 "a b c" "a b" "c"
  scenario "a listed name with no fixture -> exit 1" 1 "a" "a zz" ""
  scenario "a known gap that is also listed -> exit 1" 1 "a b" "a b" "b"
  scenario "a known gap naming no fixture -> exit 1" 1 "a b" "a b" "zz"
  scenario "an empty list -> exit 1" 1 "a" "" ""

  local total=$((pass + fail))
  if [ "$total" -lt 1 ]; then
    echo "::error::e2e fixture-list guard self-test ran zero cases"
    exit 1
  fi
  echo "Results: $pass passed, $fail failed, $total total"
  [ "$fail" -eq 0 ] || exit 1
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
else
  for f in "$LIST" "$GAPS"; do
    [ -f "$f" ] || {
      echo "::error::missing $f"
      exit 1
    }
  done
  run_check
fi
