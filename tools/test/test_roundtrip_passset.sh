#!/usr/bin/env bash
# Self-test for tools/ci/roundtrip_passset.sh — the per-fixture PASS SET
# set-difference gate (issue #836), complementing
# tools/test/test_roundtrip_floor.sh's floor/ratchet coverage.
#
# "Measure before gating": prove the instrument before trusting what it
# prints. The bug this guards against is not hypothetical — a pass-COUNT
# floor cannot distinguish "nothing changed" from "one fixture newly passes
# and a different one newly regresses" (the count is identical either way),
# so case `net_zero_swap_is_red` below is exactly that scenario and must be
# RED even though its total count matches the baseline's.
#
# Run: bash tools/test/test_roundtrip_passset.sh
set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
script="$repo_root/tools/ci/roundtrip_passset.sh"

if [ ! -f "$script" ]; then
  echo "FAIL: $script does not exist"
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

ran=0
failures=0

# block <names...> -> a well-formed "Passing fixtures (<N>, sorted):" block,
# INCLUDING the trailing blank line `format_passing_block`'s caller in
# roundtrip_conformance.rs always prints before the `Results:` line — mirror
# the real contract exactly, so a test here proves the real shape rather than
# a more lenient one.
block() {
  local names=("$@")
  printf 'Passing fixtures (%d, sorted):\n' "${#names[@]}"
  for n in "${names[@]}"; do
    printf '  %s\n' "$n"
  done
  printf '\n'
}

# run_case <name> <expected-exit> <output-text> <baseline-text-or-NONE> [expect-substring] [extra-args...]
run_case() {
  local name=$1 want_exit=$2 output_text=$3 baseline_text=$4 expect=${5:-}
  shift 5 || shift $#
  ran=$((ran + 1))

  local out_file="$work/$name.out"
  printf '%s' "$output_text" > "$out_file"

  local baseline_file="$work/$name.baseline"
  if [ "$baseline_text" != "NONE" ]; then
    printf '%s' "$baseline_text" > "$baseline_file"
  else
    rm -f "$baseline_file"
  fi

  export GITHUB_STEP_SUMMARY="$work/$name.gh_summary"
  : > "$GITHUB_STEP_SUMMARY"

  local got
  got=$(bash "$script" "TestLang" "$out_file" "$baseline_file" "$@" 2>&1)
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

# ── THE regression this gate exists for: a net-zero swap must be RED ───────
# Baseline: 100_a, 101_b, 102_c (3 fixtures). Current run: 100_a, 102_c,
# 103_d — same CARDINALITY (3), but 101_b regressed and 103_d is new. A
# pass-count floor would read this as "unchanged, still 3" and stay green.
net_zero_output=$(
  block 100_a 102_c 103_d
  printf 'Results: 3 passed, 1 failed, 4 total\n'
)
run_case net_zero_swap_is_red 1 "$net_zero_output" "100_a
101_b
102_c" "REGRESSED"

ran=$((ran + 1))
if printf '%s' "$(bash "$script" "TestLang" "$work/net_zero_swap_is_red.out" "$work/net_zero_swap_is_red.baseline" 2>&1)" | grep -qF "101_b"; then
  echo "ok   [net_zero_swap_is_red:names the regressed fixture]"
else
  echo "FAIL [net_zero_swap_is_red]: the regressed fixture name '101_b' was not in the output"
  failures=$((failures + 1))
fi

# ── An identical set (same membership) is GREEN ─────────────────────────────
same_output=$(
  block 100_a 101_b 102_c
  printf 'Results: 3 passed, 1 failed, 4 total\n'
)
run_case identical_set_is_green 0 "$same_output" "100_a
101_b
102_c" "no previously-passing fixture regressed"

# ── A STRICT improvement (superset) is GREEN, with a notice naming the gain ─
superset_output=$(
  block 100_a 101_b 102_c 103_d
  printf 'Results: 4 passed, 0 failed, 4 total\n'
)
run_case strict_improvement_is_green 0 "$superset_output" "100_a
101_b
102_c" "newly round-trip"

ran=$((ran + 1))
if printf '%s' "$(bash "$script" "TestLang" "$work/strict_improvement_is_green.out" "$work/strict_improvement_is_green.baseline" 2>&1)" | grep -qF "103_d"; then
  echo "ok   [strict_improvement_is_green:names the new fixture]"
else
  echo "FAIL [strict_improvement_is_green]: the new fixture name '103_d' was not named in the notice"
  failures=$((failures + 1))
fi

# ── A pure regression (subset, lower count too) is RED — the floor's own case,
#    still covered here so the two gates agree on the easy scenario ─────────
subset_output=$(
  block 100_a
  printf 'Results: 1 passed, 3 failed, 4 total\n'
)
run_case pure_regression_is_red 1 "$subset_output" "100_a
101_b
102_c" "REGRESSED"

# ── Missing baseline file is a hard error, never a silently-skipped gate ───
missing_baseline_output=$(
  block 100_a
  printf 'Results: 1 passed, 0 failed, 1 total\n'
)
run_case missing_baseline_is_hard_error 2 "$missing_baseline_output" "NONE" "does not exist"

# ── Missing output file is a hard error ──────────────────────────────────────
ran=$((ran + 1))
got=$(bash "$script" "TestLang" "$work/does-not-exist.txt" "$work/whatever.baseline" 2>&1)
got_exit=$?
if [ "$got_exit" = "2" ] && printf '%s' "$got" | grep -qF "does not exist"; then
  echo "ok   [missing_output_file_is_hard_error]"
else
  echo "FAIL [missing_output_file_is_hard_error]: exit $got_exit, output: $got"
  failures=$((failures + 1))
fi

# ── No "Passing fixtures" block at all is a hard error, never read as an
#    empty (and therefore vacuously non-regressing) set ───────────────────
no_block_output=$(printf 'Results: 3 passed, 1 failed, 4 total\n')
run_case no_passing_block_is_hard_error 1 "$no_block_output" "100_a" "no parseable 'Passing fixtures"

# ── A block whose header count disagrees with its own line count is a hard
#    error — the printer and the parser must agree on ONE number ──────────
mismatched_header_output=$(
  printf 'Passing fixtures (5, sorted):\n  100_a\n  101_b\n\n'
  printf 'Results: 2 passed, 1 failed, 3 total\n'
)
run_case mismatched_header_count_is_hard_error 1 "$mismatched_header_output" "100_a" "disagree"

# ── A block whose count disagrees with the Results: line's own `passed` is a
#    hard error too — the THIRD independent count must also agree ─────────
mismatched_results_output=$(
  printf 'Passing fixtures (2, sorted):\n  100_a\n  101_b\n\n'
  printf 'Results: 5 passed, 1 failed, 6 total\n'
)
run_case mismatched_results_count_is_hard_error 1 "$mismatched_results_output" "100_a" "must be the exact same count"

# ── Defense in depth: the block must terminate correctly even with NO blank
#    line before `Results:` — the real printer always emits one, but the
#    parser's second, independent terminator (anchored on `^Results:`) must
#    not accidentally swallow that line as a (N+1)th fixture name ─────────
no_blank_line_output=$(printf 'Passing fixtures (2, sorted):\n  100_a\n  101_b\nResults: 2 passed, 0 failed, 2 total\n')
run_case no_blank_line_before_results_still_parses_correctly 0 "$no_blank_line_output" "100_a
101_b" "no previously-passing fixture regressed"

# ── An empty baseline file is a hard error, not an honest "nothing to check"
empty_baseline_output=$(
  block 100_a
  printf 'Results: 1 passed, 0 failed, 1 total\n'
)
run_case empty_baseline_is_hard_error 2 "$empty_baseline_output" "" "is empty"

# ── An unsorted or duplicated baseline file is a hard error — it is a
#    generated artifact and must never be hand-edited into a bad shape ─────
unsorted_output=$(
  block 100_a 101_b
  printf 'Results: 2 passed, 0 failed, 2 total\n'
)
run_case unsorted_baseline_is_hard_error 2 "$unsorted_output" "101_b
100_a" "is not sorted"

dup_output=$(
  block 100_a 101_b
  printf 'Results: 2 passed, 0 failed, 2 total\n'
)
run_case duplicated_baseline_is_hard_error 2 "$dup_output" "100_a
100_a
101_b" "duplicate lines"

# ── --write mode regenerates the baseline from the CURRENT run and exits 0 ─
write_output=$(
  block 200_x 201_y
  printf 'Results: 2 passed, 0 failed, 2 total\n'
)
ran=$((ran + 1))
write_out_file="$work/write_mode.out"
write_baseline_file="$work/write_mode.baseline"
printf '%s' "$write_output" > "$write_out_file"
printf '999_stale\n' > "$write_baseline_file"
got=$(bash "$script" "TestLang" "$write_out_file" "$write_baseline_file" --write 2>&1)
got_exit=$?
if [ "$got_exit" = "0" ] && [ "$(cat "$write_baseline_file")" = "$(printf '200_x\n201_y')" ]; then
  echo "ok   [write_mode_regenerates_the_baseline]"
else
  echo "FAIL [write_mode_regenerates_the_baseline]: exit $got_exit, baseline now: $(cat "$write_baseline_file" 2>&1), output: $got"
  failures=$((failures + 1))
fi

# ── Usage: missing arguments is a hard error ─────────────────────────────────
ran=$((ran + 1))
got=$(bash "$script" "TestLang" 2>&1)
got_exit=$?
if [ "$got_exit" = "2" ] && printf '%s' "$got" | grep -qF "usage:"; then
  echo "ok   [missing_arguments_is_a_hard_error]"
else
  echo "FAIL [missing_arguments_is_a_hard_error]: exit $got_exit, output: $got"
  failures=$((failures + 1))
fi

# ── The wiring: the rust-roundtrip row must actually CALL this script, with
#    the committed baseline it ships beside it ─────────────────────────────
matrix="$repo_root/.github/workflows/conformance-matrix.yml"
ran=$((ran + 1))
if grep -qF 'tools/ci/roundtrip_passset.sh" "Rust"' "$matrix"; then
  echo "ok   [wiring:the rust-roundtrip row invokes roundtrip_passset.sh]"
else
  echo "FAIL [wiring]: the rust-roundtrip row in $matrix does not invoke roundtrip_passset.sh"
  failures=$((failures + 1))
fi

ran=$((ran + 1))
baseline_committed="$repo_root/tools/ci/baselines/rust_roundtrip_passing.txt"
if [ -f "$baseline_committed" ]; then
  echo "ok   [wiring:the committed Rust round-trip baseline file exists]"
else
  echo "FAIL [wiring]: $baseline_committed does not exist"
  failures=$((failures + 1))
fi

# ── Positive floor on the self-test itself ───────────────────────────────────
echo ""
echo "Results: $((ran - failures)) passed, $failures failed, $ran total"
if [ "$ran" -lt 18 ]; then
  echo "FAIL: only $ran assertions ran — this self-test measured almost nothing"
  exit 1
fi
if [ "$failures" -gt 0 ]; then
  echo "FAIL: $failures assertion(s) failed"
  exit 1
fi
echo "PASS: roundtrip_passset.sh behaves as specified"
exit 0
