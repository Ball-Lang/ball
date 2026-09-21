#!/usr/bin/env bash
# Self-test for tools/ci/compiler_floor.sh — the positive floor + RATCHET the
# four `*-compiler` rows in .github/workflows/conformance-matrix.yml run
# (issue #792).
#
# The bug this exists for is not hypothetical. Every one of those four rows
# carried its own byte-identical copy of an inline bash gate whose ONLY response
# to a measured gain was an advisory annotation:
#
#   if [ "$passed" -gt "$GO_COMPILER_FLOOR" ]; then
#     echo "::notice::Go compiler leg IMPROVED: $passed passed (floor was ...)"
#   fi
#   exit 0
#
# `GO_COMPILER_FLOOR` therefore sat at 291 while the leg measured 297 (PR #738's
# own matrix run 35552669922: `Results: 297 passed, 63 failed, 360 total (floor:
# 291)`) — six fixtures of real, earned gain left unclaimed, and a regression
# back to 292 would have stayed green. A ::notice:: in a CI log is not a gate:
# somebody has to read it and act, and for six fixtures nobody did.
#
# Case `unclaimed_gain_is_red` below is that exact log, and it must be RED: an
# improvement is not green until the floor that locks it in lands in the SAME
# PR, which is what docs/TESTING_STRATEGY.md §2c already required in prose.
#
# It also guards the failure mode that makes a shell gate silently vanish: `[
# "$passed" -lt "$floor" ]` exits 2 when either side is empty or multiline, and
# a failing `[` inside an `if` SKIPS the branch and falls through to `exit 0`.
# Cases `unset_floor_*`, `empty_floor_*`, `non_integer_*` and
# `two_results_lines_*` pin that.
#
# Run: bash tools/test/test_compiler_floor.sh
set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
script="$repo_root/tools/ci/compiler_floor.sh"
matrix="$repo_root/.github/workflows/conformance-matrix.yml"
ci="$repo_root/.github/workflows/ci.yml"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

ran=0
failures=0

fail() {
  echo "FAIL $1"
  failures=$((failures + 1))
}

# run_case <name> <expected-exit> <floor-value|UNSET> <leg-exit> <output-text> [expect-substring]
#
# The floor is passed to the script BY NAME and read back with indirect
# expansion, so the constant the error message tells a human to edit is the same
# one the comparison used — never two spellings that can drift apart. `UNSET`
# exercises a typo'd / removed env var, which must be a hard error rather than a
# comparison against the empty string.
run_case() {
  local name=$1 want_exit=$2 floor=$3 leg_exit=$4 text=$5 expect=${6:-}
  ran=$((ran + 1))

  local out_file="$work/$name.out"
  printf '%s\n' "$text" > "$out_file"

  export GITHUB_OUTPUT="$work/$name.gh_output"
  export GITHUB_STEP_SUMMARY="$work/$name.gh_summary"
  : > "$GITHUB_OUTPUT"
  : > "$GITHUB_STEP_SUMMARY"

  if [ "$floor" = "UNSET" ]; then
    unset TESTLANG_COMPILER_FLOOR
  else
    export TESTLANG_COMPILER_FLOOR="$floor"
  fi

  local got got_exit
  got=$(bash "$script" "TestLang" TESTLANG_COMPILER_FLOOR "$leg_exit" "$out_file" 2>&1)
  got_exit=$?

  if [ "$got_exit" != "$want_exit" ]; then
    fail "[$name]: expected exit $want_exit, got $got_exit"
    echo "--- output ---"
    echo "$got"
    echo "--------------"
    return
  fi
  if [ -n "$expect" ] && ! printf '%s' "$got" | grep -qF -- "$expect"; then
    fail "[$name]: expected output to contain '$expect'"
    echo "--- output ---"
    echo "$got"
    echo "--------------"
    return
  fi
  echo "ok   [$name]"
}

# assert_output_kv <name> <key=value>
assert_output_kv() {
  local name=$1 kv=$2
  ran=$((ran + 1))
  if grep -qxF -- "$kv" "$work/$name.gh_output"; then
    echo "ok   [$name:$kv]"
  else
    fail "[$name]: GITHUB_OUTPUT does not contain '$kv'"
    echo "--- GITHUB_OUTPUT ---"
    cat "$work/$name.gh_output"
    echo "---------------------"
  fi
}

# assert_matrix <description> <grep-args...>
assert_matrix() {
  local what=$1
  shift
  ran=$((ran + 1))
  if grep "$@" "$matrix"; then
    echo "ok   [wiring:$what]"
  else
    fail "[wiring]: $what"
  fi
}

# refute_matrix <description> <grep-args...> — the pattern must NOT be present.
refute_matrix() {
  local what=$1
  shift
  ran=$((ran + 1))
  if grep "$@" "$matrix"; then
    fail "[wiring]: $what"
  else
    echo "ok   [wiring:$what]"
  fi
}

if [ ! -f "$script" ]; then
  fail ": $script does not exist — the four compiler legs still gate with inline workflow bash whose only response to a measured gain is an advisory ::notice:: (issue #792). Inline bash in a workflow cannot be unit-tested; a script can."
else
  # ── THE regression this gate exists for ─────────────────────────────────────
  # PR #738's matrix run 35552669922, verbatim. Today this prints a ::notice::
  # and exits 0; it must be RED until GO_COMPILER_FLOOR is raised to 297.
  run_case unclaimed_gain_is_red 1 291 1 \
    "Results: 297 passed, 63 failed, 360 total" \
    "Raise TESTLANG_COMPILER_FLOOR to 297"

  # The numbers must still reach the aggregate job even when the gate fails —
  # the matrix summary renders this row from these outputs, and a red row that
  # reports nothing is a row nobody can read.
  assert_output_kv unclaimed_gain_is_red "passed=297"
  assert_output_kv unclaimed_gain_is_red "failed=63"
  assert_output_kv unclaimed_gain_is_red "total=360"
  assert_output_kv unclaimed_gain_is_red "floor=291"

  # ── The same measurement, with the floor actually raised, is GREEN ──────────
  run_case gain_locked_in_is_green 0 297 1 \
    "Results: 297 passed, 63 failed, 360 total" \
    "Results: 297 passed, 63 failed, 360 total (floor: 297)"
  assert_output_kv gain_locked_in_is_green "passed=297"
  assert_output_kv gain_locked_in_is_green "floor=297"

  ran=$((ran + 1))
  if grep -qF "297/360" "$work/gain_locked_in_is_green.gh_summary"; then
    echo "ok   [gain_locked_in_is_green:in step summary]"
  else
    fail "[gain_locked_in_is_green]: the row is missing from the step summary"
    cat "$work/gain_locked_in_is_green.gh_summary"
  fi

  # ── A drop below the floor is RED (the ratchet half, unchanged) ─────────────
  run_case below_floor_is_red 1 298 1 \
    "Results: 292 passed, 68 failed, 360 total" \
    "REGRESSED: 292 passed, below the floor of 298"

  # A regression to a count that is still above the STALE floor is what the
  # unclaimed gain was hiding: 292 > 291 read as healthy for as long as the
  # floor was not raised.
  run_case regression_hidden_by_a_stale_floor_is_red 1 297 1 \
    "Results: 292 passed, 68 failed, 360 total" \
    "REGRESSED: 292 passed, below the floor of 297"

  # ── A leg that compiles nothing is never green ──────────────────────────────
  run_case flat_zero_is_red 1 1 1 \
    "Results: 0 passed, 360 failed, 360 total" \
    "compiled ZERO of 360 fixtures"

  # ── Harness health: a leg that ran no fixtures measured nothing ─────────────
  run_case zero_total_is_red 1 1 1 \
    "Results: 0 passed, 0 failed, 0 total" \
    "reported no fixtures (total=0)"

  # A crashed harness reports its own exit status, so the log says WHY there is
  # no Results line rather than only that there isn't one.
  run_case crashed_harness_is_red 1 1 7 \
    "panic: harness exploded before printing anything" \
    "Leg exit code was 7"

  # ── Progress chatter containing a second match must not multiline the parse ─
  run_case two_results_lines_uses_last 0 2 1 \
    "Results: 99 passed, 0 failed, 99 total
320 fixtures emitted Go, 0 failed to compile
Results: 2 passed, 358 failed, 360 total" \
    "Results: 2 passed, 358 failed, 360 total (floor: 2)"
  assert_output_kv two_results_lines_uses_last "passed=2"

  # ── A floor that is unset/empty/garbage is a hard error, not an open gate ───
  run_case unset_floor_is_hard_error 2 UNSET 1 \
    "Results: 297 passed, 63 failed, 360 total" \
    "is not set"

  run_case empty_floor_is_hard_error 2 "" 1 \
    "Results: 297 passed, 63 failed, 360 total" \
    "not a bare integer"

  run_case non_integer_floor_is_hard_error 2 "two hundred" 1 \
    "Results: 297 passed, 63 failed, 360 total" \
    "not a bare integer"

  # A zero floor would re-open the hole a positive floor exists to close.
  run_case zero_floor_is_hard_error 2 0 1 \
    "Results: 0 passed, 360 failed, 360 total" \
    "must be >= 1"

  # ── A missing output file is a hard error, not a green no-op ────────────────
  ran=$((ran + 1))
  export TESTLANG_COMPILER_FLOOR=1
  export GITHUB_OUTPUT="$work/missing.gh_output"
  export GITHUB_STEP_SUMMARY="$work/missing.gh_summary"
  : > "$GITHUB_OUTPUT"
  : > "$GITHUB_STEP_SUMMARY"
  missing_out=$(bash "$script" "TestLang" TESTLANG_COMPILER_FLOOR 1 "$work/does-not-exist.txt" 2>&1)
  missing_exit=$?
  if [ "$missing_exit" = "2" ] && printf '%s' "$missing_out" | grep -qF "does not exist"; then
    echo "ok   [missing_output_file_is_hard_error]"
  else
    fail "[missing_output_file_is_hard_error]: exit $missing_exit, output: $missing_out"
  fi

  # ── A call with missing arguments is a hard error ───────────────────────────
  ran=$((ran + 1))
  usage_out=$(bash "$script" "TestLang" 2>&1)
  usage_exit=$?
  if [ "$usage_exit" = "2" ] && printf '%s' "$usage_out" | grep -qF "usage"; then
    echo "ok   [missing_arguments_is_hard_error]"
  else
    fail "[missing_arguments_is_hard_error]: exit $usage_exit, output: $usage_out"
  fi
fi

# ── The wiring: every compiler row must actually CALL this script ─────────────
# A parser test that runs the script directly cannot notice that the workflow
# re-implements the comparison inline and never invokes it — the exact hole
# cpp/test/test_cov_floor_ci_wiring.sh exists to close for the C++ coverage
# floor, and the hole #792 fell through for the Go compiler leg. Assert the
# wiring statically, here, on every PR.
for row in CSHARP RUST GO PYTHON; do
  assert_matrix "${row}_COMPILER_FLOOR declared as a quoted integer" \
    -qE "^ +${row}_COMPILER_FLOOR: \"[0-9]+\""
  assert_matrix "the ${row} compiler row invokes compiler_floor.sh with ${row}_COMPILER_FLOOR" \
    -qE "compiler_floor\.sh\".*${row}_COMPILER_FLOOR"
done

ran=$((ran + 1))
invocations=$(grep -cF 'bash "$GITHUB_WORKSPACE/tools/ci/compiler_floor.sh"' "$matrix" || true)
if [ "$invocations" -eq 4 ]; then
  echo "ok   [wiring:exactly 4 compiler_floor.sh invocations]"
else
  fail "[wiring]: expected exactly 4 compiler_floor.sh invocations in $matrix, found $invocations"
fi

# The defect itself, spelled out: no row may answer a measured gain with an
# advisory annotation and `exit 0`.
refute_matrix "no compiler row still answers a gain with an advisory ::notice::" \
  -qE '::notice::.*compiler leg IMPROVED'
refute_matrix "no compiler row still compares against its floor inline" \
  -qE -e '-(gt|lt) "\$[A-Z_]+_COMPILER_FLOOR"'

# ── The CI wiring: this self-test has to RUN ─────────────────────────────────
ran=$((ran + 1))
if grep -qF 'tools/test/test_compiler_floor.sh' "$ci"; then
  echo "ok   [wiring:ci.yml runs this self-test]"
else
  fail "[wiring]: ci.yml does not run tools/test/test_compiler_floor.sh — a gate nobody runs is not a gate"
fi

# ── Positive floor on the self-test itself ───────────────────────────────────
# An exit code plus a failure count cannot tell "all passed" from "nothing ran".
echo ""
echo "Results: $((ran - failures)) passed, $failures failed, $ran total"
if [ "$ran" -lt 30 ]; then
  echo "FAIL: only $ran assertions ran — this self-test measured almost nothing"
  exit 1
fi
if [ "$failures" -gt 0 ]; then
  echo "FAIL: $failures assertion(s) failed"
  exit 1
fi
echo "PASS: compiler_floor.sh behaves as specified"
exit 0
