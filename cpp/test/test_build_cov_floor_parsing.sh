#!/usr/bin/env bash
# Unit test for cpp/build-cov-floor.sh's lcov-summary percentage parser and its
# awk floor comparison (issues #63 / #59).
#
# WHY THIS EXISTS: build-cov-floor.sh owns the finer per-target C++ coverage
# floors (compiler/encoder/shared) that the single blended aggregate in
# coverage.yml cannot see — a large regression confined to one target is
# arithmetically absorbable by the other two. Before this test, its
# unparseable-summary branch was FAIL-OPEN: it printed `SKIP` and `continue`d
# without setting `fail=1`, so a broken per-target extraction passed silently —
# the exact opposite of coverage.yml's own inline floor step, which correctly
# `exit 1`s on an unparseable percentage. Nothing fed the script a bad summary,
# so nothing noticed.
#
# No C++ toolchain, no real lcov, no coverage build: a stub `lcov` on PATH
# replays synthetic `lcov --summary` output against a scratch copy of the
# script. Sub-second; wired into ci.yml's always-run `proto` job.
#
# Usage: bash cpp/test/test_build_cov_floor_parsing.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../build-cov-floor.sh"
[ -f "$SCRIPT" ] || {
  echo "::error::missing $SCRIPT"
  exit 1
}

pass=0
fail=0

# Real floors, mirrored from build-cov-floor.sh's FLOORS map, so the cases below
# read as "above"/"below" without duplicating the numbers' meaning. Re-derived
# 2026-09-02 from two consecutive coverage.yml runs on main (92.3 / 89.1 / 81.8)
# minus the ~2pt CI-variance buffer, when the script became CI's actual gate.
#   compiler 90, encoder 87, shared 79

# summary_line <pct> — one line in the exact shape `lcov --summary` prints.
summary_line() { printf '  lines......: %s%% (1000 of 1100 lines)\n' "$1"; }

# run_case <name> <expected exit> <compiler summary> <encoder summary> <shared summary>
# Each summary argument is the literal stdout the stub `lcov` returns for that
# target ('' means lcov printed nothing at all).
run_case() {
  local name="$1" want="$2" c="$3" e="$4" s="$5"
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/build-cov" "$tmp/bin"
  cp "$SCRIPT" "$tmp/build-cov-floor.sh"

  # The tracefiles only have to EXIST — the stub lcov reads the sibling
  # .summary file, never the tracefile itself.
  local t
  for t in compiler encoder shared; do : >"$tmp/build-cov/cpp.$t.lcov"; done
  printf '%s' "$c" >"$tmp/build-cov/cpp.compiler.lcov.summary"
  printf '%s' "$e" >"$tmp/build-cov/cpp.encoder.lcov.summary"
  printf '%s' "$s" >"$tmp/build-cov/cpp.shared.lcov.summary"

  # Stub lcov: `lcov --summary <tracefile> --ignore-errors empty` -> replay the
  # synthetic summary for that tracefile. Exits 0, exactly like real lcov does.
  cat >"$tmp/bin/lcov" <<'STUB'
#!/usr/bin/env bash
f=""
prev=""
for a in "$@"; do
  [ "$prev" = "--summary" ] && f="$a"
  prev="$a"
done
[ -n "$f" ] && [ -f "$f.summary" ] && cat "$f.summary"
exit 0
STUB
  chmod +x "$tmp/bin/lcov"

  local out rc
  out="$(cd "$tmp" && PATH="$tmp/bin:$PATH" bash ./build-cov-floor.sh 2>&1)"
  rc=$?
  if [ "$rc" -eq "$want" ]; then
    pass=$((pass + 1))
    echo "PASS  $name (exit $rc)"
  else
    fail=$((fail + 1))
    echo "FAIL  $name: expected exit $want, got $rc"
    printf '  %s\n' "$out"
  fi
  rm -rf "$tmp"
}

# 1. Every target at/above its floor -> exit 0.
run_case "all targets at or above floor" 0 \
  "$(summary_line 92.5)" "$(summary_line 89.1)" "$(summary_line 81.7)"

# 2. One target below its floor -> exit 1 (the gate's whole purpose).
run_case "compiler below floor" 1 \
  "$(summary_line 80.0)" "$(summary_line 89.1)" "$(summary_line 81.7)"

# 3. Empty summary (lcov printed nothing — e.g. an empty/broken extraction)
#    -> MUST exit 1. This is the fail-open branch: before the fix the script
#    printed `SKIP` and exited 0 with the floor never checked.
run_case "empty summary fails loud" 1 \
  "" "$(summary_line 89.1)" "$(summary_line 81.7)"

# 4. Malformed summary (output present, but no parseable `lines...:` line)
#    -> MUST exit 1, same reason.
run_case "malformed summary fails loud" 1 \
  "lcov: ERROR: no valid records found in tracefile" \
  "$(summary_line 89.1)" "$(summary_line 81.7)"

# ── The committed FLOORS table itself (issues #63 / #599) ──────────────────
#
# Cases 1-4 feed SYNTHETIC percentages; nothing in this suite had ever looked at
# the numbers the gate actually compares against. A table that stops parsing is
# a gate that stops gating, silently: build-cov-floor.sh reads each floor
# straight into `awk -v f="$floor"`, where a non-numeric value degrades to 0 —
# `f=` (an emptied entry) and `f=ninety` both make "is coverage below the
# floor?" permanently false, and a renamed/dropped key simply stops checking
# that target. Neither shows up as an error; both read as a green gate.
#
# So: pin the SHAPE of the table (three known targets, each a bare number in
# range) and then drive the real script at those exact numbers — at the floor
# must pass, a tenth of a point under must fail. The boundary cases read the
# committed values rather than hardcoding them, so a ratchet moves them
# automatically and this file never has to be kept in sync by hand.

# floors_of — "<target> <floor>" per line, straight out of the committed script.
floors_of() {
  sed -n '/^declare -A FLOORS=(/,/^)/p' "$SCRIPT" \
    | sed -n 's/^[[:space:]]*\[\([A-Za-z_][A-Za-z0-9_]*\)\]=\(.*\)$/\1 \2/p'
}

floor_for() { floors_of | awk -v t="$1" '$1 == t { print $2; found = 1 } END { exit !found }'; }

table_ok=1
names="$(floors_of | awk '{ print $1 }' | sort | tr '\n' ' ')"
if [ "$names" != "compiler encoder shared " ]; then
  table_ok=0
  echo "FAIL  FLOORS table targets: expected 'compiler encoder shared ', got '$names'"
fi
while read -r t f; do
  case "$f" in
    '' | *[!0-9]*)
      table_ok=0
      echo "FAIL  FLOORS[$t] is '$f' — not a bare integer; awk would read it as 0 and the gate could never fail"
      continue
      ;;
  esac
  if [ "$f" -gt 100 ]; then
    table_ok=0
    echo "FAIL  FLOORS[$t] is $f — a line-coverage floor above 100% can never be met"
  fi
done <<EOF
$(floors_of)
EOF
if [ "$table_ok" -eq 1 ]; then
  pass=$((pass + 1))
  echo "PASS  FLOORS table parses and every floor is a bare number in range ($(floors_of | tr '\n' ';' | sed 's/;$//'))"
else
  fail=$((fail + 1))
fi

# 5-8. Boundary cases against the COMMITTED floors, not synthetic ones.
c_floor="$(floor_for compiler)"
e_floor="$(floor_for encoder)"
s_floor="$(floor_for shared)"
# just_under <int-floor> — a tenth of a point below it, without floating-point
# arithmetic in bash.
just_under() { printf '%s.9\n' "$(($1 - 1))"; }

run_case "every target exactly at its committed floor" 0 \
  "$(summary_line "$c_floor")" "$(summary_line "$e_floor")" "$(summary_line "$s_floor")"
run_case "compiler a tenth of a point under its committed floor" 1 \
  "$(summary_line "$(just_under "$c_floor")")" \
  "$(summary_line "$e_floor")" "$(summary_line "$s_floor")"
run_case "encoder a tenth of a point under its committed floor" 1 \
  "$(summary_line "$c_floor")" \
  "$(summary_line "$(just_under "$e_floor")")" "$(summary_line "$s_floor")"
run_case "shared a tenth of a point under its committed floor" 1 \
  "$(summary_line "$c_floor")" "$(summary_line "$e_floor")" \
  "$(summary_line "$(just_under "$s_floor")")"

total=$((pass + fail))
# Positive floor: an exit code plus a failure count cannot tell "everything
# passed" from "nothing ran".
if [ "$total" -lt 9 ]; then
  echo "::error::floor-parsing test ran only $total case(s) — expected at least 9."
  exit 1
fi
echo "Results: $pass passed, $fail failed, $total total"
[ "$fail" -eq 0 ] || exit 1
