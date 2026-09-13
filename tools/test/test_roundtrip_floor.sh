#!/usr/bin/env bash
# Self-test for tools/ci/roundtrip_floor.sh — the positive floor + ratchet the
# four `*-roundtrip` rows in .github/workflows/conformance-matrix.yml run
# (issue #642).
#
# "Measure before gating": prove the instrument itself before trusting a number
# it prints. The bug this guards against is not hypothetical — the four rows
# printed `Results: 0 passed, 349 failed, 349 total` on every run for as long as
# they have existed and went GREEN every time, because the only assertion was
# `total >= 1`. Case `flat_zero_is_red` below is that exact log, and it must be
# RED.
#
# It also guards the failure mode that makes a shell gate silently vanish: `[
# "$passed" -lt "$floor" ]` exits 2 when either side is empty or multiline, and
# a failing `[` inside an `if` SKIPS the branch and falls through to `exit 0`.
# Cases `empty_floor_*`, `non_integer_*` and `two_results_lines_*` pin that.
#
# Run: bash tools/test/test_roundtrip_floor.sh
set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
script="$repo_root/tools/ci/roundtrip_floor.sh"

if [ ! -f "$script" ]; then
  echo "FAIL: $script does not exist"
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

ran=0
failures=0

# run_case <name> <expected-exit> <floor> <leg-exit> <output-text> [expect-substring]
run_case() {
  local name=$1 want_exit=$2 floor=$3 leg_exit=$4 text=$5 expect=${6:-}
  ran=$((ran + 1))

  local out_file="$work/$name.out"
  printf '%s\n' "$text" > "$out_file"

  export GITHUB_OUTPUT="$work/$name.gh_output"
  export GITHUB_STEP_SUMMARY="$work/$name.gh_summary"
  : > "$GITHUB_OUTPUT"
  : > "$GITHUB_STEP_SUMMARY"

  local got
  got=$(bash "$script" "TestLang" "$floor" "$leg_exit" "$out_file" 2>&1)
  local got_exit=$?

  if [ "$got_exit" != "$want_exit" ]; then
    echo "FAIL [$name]: expected exit $want_exit, got $got_exit"
    echo "--- output ---"
    echo "$got"
    echo "--------------"
    failures=$((failures + 1))
    return
  fi
  if [ -n "$expect" ] && ! printf '%s' "$got" | grep -qF -- "$expect"; then
    echo "FAIL [$name]: expected output to contain '$expect'"
    echo "--- output ---"
    echo "$got"
    echo "--------------"
    failures=$((failures + 1))
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
    echo "FAIL [$name]: GITHUB_OUTPUT does not contain '$kv'"
    echo "--- GITHUB_OUTPUT ---"
    cat "$work/$name.gh_output"
    echo "---------------------"
    failures=$((failures + 1))
  fi
}

# ── THE regression this gate exists for: a flat zero must be RED ─────────────
run_case flat_zero_is_red 1 1 1 \
  "Results: 0 passed, 349 failed, 349 total (4 skipped carve-outs)" \
  "round-tripped ZERO of 349 fixtures"

# ── A real, measured count at its floor is GREEN ─────────────────────────────
run_case at_floor_is_green 0 3 1 \
  "Results: 3 passed, 346 failed, 349 total (4 skipped carve-outs)" \
  "Results: 3 passed, 346 failed, 349 total (floor: 3)"
assert_output_kv at_floor_is_green "passed=3"
assert_output_kv at_floor_is_green "failed=346"
assert_output_kv at_floor_is_green "total=349"
assert_output_kv at_floor_is_green "floor=3"

# ── An improvement is GREEN and names the new floor to record ────────────────
run_case above_floor_notices 0 3 1 \
  "Results: 7 passed, 342 failed, 349 total (4 skipped carve-outs)" \
  "IMPROVED: 7 passed (floor was 3). Raise this row's floor to 7"

# ── A drop below the floor is RED (the ratchet half) ─────────────────────────
run_case below_floor_is_red 1 3 1 \
  "Results: 2 passed, 347 failed, 349 total (4 skipped carve-outs)" \
  "REGRESSED: 2 passed, below the floor of 3"

# ── Harness health: the pre-existing total >= 1 gate still fires ─────────────
run_case zero_total_is_red 1 1 1 \
  "Results: 0 passed, 0 failed, 0 total" \
  "reported no fixtures (total=0)"

# ── A harness that printed nothing must never read as a silent pass ──────────
run_case no_results_line_is_red 1 1 1 \
  "panic: harness exploded before printing anything" \
  "could not parse a clean integer count"

# ── Progress chatter containing a second match must not multiline the parse ──
run_case two_results_lines_uses_last 0 2 1 \
  "Results: 99 passed, 0 failed, 99 total
some chatter in between
Results: 2 passed, 347 failed, 349 total (4 skipped carve-outs)" \
  "Results: 2 passed, 347 failed, 349 total (floor: 2)"
assert_output_kv two_results_lines_uses_last "passed=2"

# ── A floor that is empty/garbage must be a hard error, never an open gate ───
run_case empty_floor_is_hard_error 2 "" 1 \
  "Results: 0 passed, 349 failed, 349 total" \
  "not a bare integer"

run_case non_integer_floor_is_hard_error 2 "three" 1 \
  "Results: 5 passed, 344 failed, 349 total" \
  "not a bare integer"

# ── A zero floor is refused outright: it would re-open the #642 hole ─────────
run_case zero_floor_is_hard_error 2 0 1 \
  "Results: 0 passed, 349 failed, 349 total" \
  "the floor must be >= 1"

# ── A missing output file is a hard error, not a green no-op ─────────────────
ran=$((ran + 1))
export GITHUB_OUTPUT="$work/missing.gh_output"
export GITHUB_STEP_SUMMARY="$work/missing.gh_summary"
: > "$GITHUB_OUTPUT"
: > "$GITHUB_STEP_SUMMARY"
missing_out=$(bash "$script" "TestLang" 1 1 "$work/does-not-exist.txt" 2>&1)
missing_exit=$?
if [ "$missing_exit" = "2" ] && printf '%s' "$missing_out" | grep -qF "does not exist"; then
  echo "ok   [missing_output_file_is_hard_error]"
else
  echo "FAIL [missing_output_file_is_hard_error]: exit $missing_exit, output: $missing_out"
  failures=$((failures + 1))
fi

# ── The wiring: every round-trip row must actually CALL this script ──────────
# A parser test that runs the script directly cannot notice that the workflow
# re-implements the comparison inline and never invokes it — the exact hole
# cpp/test/test_cov_floor_ci_wiring.sh exists to close for the C++ coverage
# floor. Assert the wiring statically, here, on every PR.
matrix="$repo_root/.github/workflows/conformance-matrix.yml"
for row in CSHARP PYTHON GO RUST; do
  ran=$((ran + 1))
  if grep -qE "^ +${row}_ROUNDTRIP_FLOOR: \"[0-9]+\"" "$matrix"; then
    echo "ok   [wiring:${row}_ROUNDTRIP_FLOOR declared]"
  else
    echo "FAIL [wiring]: ${row}_ROUNDTRIP_FLOOR is not declared as a quoted integer in $matrix"
    failures=$((failures + 1))
  fi
  ran=$((ran + 1))
  if grep -qF "roundtrip_floor.sh \"${row}" "$matrix" ||
    grep -qF "\$${row}_ROUNDTRIP_FLOOR" "$matrix"; then
    echo "ok   [wiring:${row} row invokes roundtrip_floor.sh]"
  else
    echo "FAIL [wiring]: the ${row} round-trip row does not pass ${row}_ROUNDTRIP_FLOOR to roundtrip_floor.sh"
    failures=$((failures + 1))
  fi
done

ran=$((ran + 1))
invocations=$(grep -cF 'bash "$GITHUB_WORKSPACE/tools/ci/roundtrip_floor.sh"' "$matrix" || true)
if [ "$invocations" -eq 4 ]; then
  echo "ok   [wiring:exactly 4 roundtrip_floor.sh invocations]"
else
  echo "FAIL [wiring]: expected exactly 4 roundtrip_floor.sh invocations in $matrix, found $invocations"
  failures=$((failures + 1))
fi

# ── Positive floor on the self-test itself ───────────────────────────────────
# An exit code plus a failure count cannot tell "all passed" from "nothing ran".
echo ""
echo "Results: $((ran - failures)) passed, $failures failed, $ran total"
if [ "$ran" -lt 20 ]; then
  echo "FAIL: only $ran assertions ran — this self-test measured almost nothing"
  exit 1
fi
if [ "$failures" -gt 0 ]; then
  echo "FAIL: $failures assertion(s) failed"
  exit 1
fi
echo "PASS: roundtrip_floor.sh behaves as specified"
exit 0
