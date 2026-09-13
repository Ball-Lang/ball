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

# EVERY percentage in this file is DERIVED from build-cov-floor.sh's committed
# FLOORS map — floor + 1 for "above", floor - 0.1 for "below" — so a ratchet
# moves the whole suite on its own and no measurement is ever pasted in here.
# Until #660, case 1 hard-coded the day's measurement (94.6 / 99.0 / 94.3), so
# the first ratchet past any of those numbers would have reddened a PARSING
# test for a reason that has nothing to do with parsing; the future-ratchet
# simulation at the bottom of this file is the negative control for exactly
# that, and it fails if anyone reintroduces a literal.
# (The floors' own provenance — the six coverage.yml runs on main they were
# ratcheted from, minus the ~2pt CI-variance buffer — lives in
# build-cov-floor.sh's header, which is the one place it belongs.)

# floors_of — "<target> <floor>" per line, straight out of the committed script.
floors_of() {
  sed -n '/^declare -A FLOORS=(/,/^)/p' "$SCRIPT" \
    | sed -n 's/^[[:space:]]*\[\([A-Za-z_][A-Za-z0-9_]*\)\]=\(.*\)$/\1 \2/p'
}

floor_for() { floors_of | awk -v t="$1" '$1 == t { print $2; found = 1 } END { exit !found }'; }

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

# The per-target floors, read out of the committed table ONCE. Every case below
# that needs an "above floor" or "below floor" percentage derives it from these,
# so a ratchet moves this whole file on its own (#660).
c_floor="$(floor_for compiler)"
e_floor="$(floor_for encoder)"
s_floor="$(floor_for shared)"
# just_over / just_under <int-floor> — a point above / a tenth of a point below
# it, without floating-point arithmetic in bash.
just_over() { printf '%s\n' "$(($1 + 1))"; }
just_under() { printf '%s.9\n' "$(($1 - 1))"; }

# 1. Every target above its floor -> exit 0.
run_case "all targets above their committed floors" 0 \
  "$(summary_line "$(just_over "$c_floor")")" \
  "$(summary_line "$(just_over "$e_floor")")" \
  "$(summary_line "$(just_over "$s_floor")")"

# 2. One target below its floor -> exit 1 (the gate's whole purpose).
run_case "compiler below floor" 1 \
  "$(summary_line "$(just_under "$c_floor")")" \
  "$(summary_line "$(just_over "$e_floor")")" \
  "$(summary_line "$(just_over "$s_floor")")"

# 3. Empty summary (lcov printed nothing — e.g. an empty/broken extraction)
#    -> MUST exit 1. This is the fail-open branch: before the fix the script
#    printed `SKIP` and exited 0 with the floor never checked.
run_case "empty summary fails loud" 1 \
  "" "$(summary_line "$(just_over "$e_floor")")" \
  "$(summary_line "$(just_over "$s_floor")")"

# 4. Malformed summary (output present, but no parseable `lines...:` line)
#    -> MUST exit 1, same reason.
run_case "malformed summary fails loud" 1 \
  "lcov: ERROR: no valid records found in tracefile" \
  "$(summary_line "$(just_over "$e_floor")")" \
  "$(summary_line "$(just_over "$s_floor")")"

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

# 5-8. Boundary cases against the COMMITTED floors: exactly at one must pass,
#      a tenth of a point under it must fail. (c_floor/e_floor/s_floor and
#      just_under are defined with the other derived values at the top.)
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


# ── 10. The FUTURE-RATCHET simulation (issue #660) ────────────────────────
#
# Case 1 above feeds the "above floor" percentages. Until #660 it hand-wrote
# them as the measurement of the day (94.6 / 99.0 / 94.3), which made this
# suite go red the first time a ratchet moved a floor past one of those
# numbers — a PARSING test failing for a reason that has nothing to do with
# parsing, and the same staleness class #643's commit 3 removed from the
# sibling wiring test.
#
# This is the negative control for that. It ratchets a SCRATCH copy of
# build-cov-floor.sh to floors that sit ABOVE the numbers case 1 used to
# hard-code, drops a scratch copy of this very file next to it, and runs it:
# a suite whose "above floor" inputs are derived from the table it is testing
# stays green under any ratchet, one that hard-codes them does not.
#
# The scratch run is told not to recurse (it would fork forever otherwise).
if [ "${BALL_COV_FLOOR_TEST_RATCHET_SIM:-}" != "1" ]; then
  sim="$(mktemp -d)"
  mkdir -p "$sim/cpp/test"
  # Floors chosen to exceed the compiler/shared measurements case 1 used to
  # hard-code (94.6 / 94.3) while staying low enough that floor+1 is still a
  # legal percentage for every target.
  awk '
    /^[[:space:]]*\[compiler\]=/ { print "  [compiler]=96"; next }
    /^[[:space:]]*\[encoder\]=/  { print "  [encoder]=98";  next }
    /^[[:space:]]*\[shared\]=/   { print "  [shared]=96";   next }
    { print }
  ' "$SCRIPT" >"$sim/cpp/build-cov-floor.sh"
  cp "${BASH_SOURCE[0]}" "$sim/cpp/test/test_build_cov_floor_parsing.sh"

  # The rewrite must have actually landed, or this control would "pass"
  # against the committed floors and prove nothing.
  sim_floors="$(sed -n '/^declare -A FLOORS=(/,/^)/p' "$sim/cpp/build-cov-floor.sh" |
    sed -n 's/^[[:space:]]*\[[A-Za-z_]*\]=\(.*\)$/\1/p' | sort -n | tr '\n' ' ')"
  if [ "$sim_floors" != "96 96 98 " ]; then
    fail=$((fail + 1))
    echo "FAIL  future-ratchet simulation: scratch floors are '$sim_floors', expected '96 96 98 '"
  else
    sim_out="$(BALL_COV_FLOOR_TEST_RATCHET_SIM=1 \
      bash "$sim/cpp/test/test_build_cov_floor_parsing.sh" 2>&1)"
    sim_rc=$?
    if [ "$sim_rc" -eq 0 ]; then
      pass=$((pass + 1))
      echo "PASS  this suite survives a ratchet to floors 96/98/96 (inputs derived, not hard-coded)"
    else
      fail=$((fail + 1))
      echo "FAIL  this suite goes red under a ratchet to floors 96/98/96 — its 'above floor' inputs are hard-coded, not read from the FLOORS table (exit $sim_rc)"
      printf '  %s\n' "$sim_out"
    fi
  fi
  rm -rf "$sim"
fi

total=$((pass + fail))
# Positive floor: an exit code plus a failure count cannot tell "everything
# passed" from "nothing ran".
# The ratchet simulation below re-runs this file, and that inner run must not
# recurse into it again — so the inner run has one case fewer.
min_cases=10
[ "${BALL_COV_FLOOR_TEST_RATCHET_SIM:-}" = "1" ] && min_cases=9
if [ "$total" -lt "$min_cases" ]; then
  echo "::error::floor-parsing test ran only $total case(s) — expected at least $min_cases."
  exit 1
fi
echo "Results: $pass passed, $fail failed, $total total"
[ "$fail" -eq 0 ] || exit 1
