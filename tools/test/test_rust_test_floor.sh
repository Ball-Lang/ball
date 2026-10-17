#!/usr/bin/env bash
# Self-test for tools/ci/rust_test_floor.sh — the positive floor over named
# Rust tests actually running as `ok` (issue #735).
#
# "A checker nobody has watched fail is not a gate": every case below proves
# the instrument fires on the exact failure mode #735 named, and on the
# shapes that could make a shell gate silently vanish (a malformed exit-code
# argument, an empty log, a test present as `FAILED` rather than missing).
#
# Case `masked_by_earlier_failing_target` reproduces #725's own CI log shape
# verbatim: an earlier target (`compile_reencode_roundtrip`) fails first, and
# the later target's new tests never print anything at all — not `ok`, not
# `FAILED`. That is the log #735 was filed over, and it MUST be red.
#
# Run: bash tools/test/test_rust_test_floor.sh
set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
script="$repo_root/tools/ci/rust_test_floor.sh"

if [ ! -f "$script" ]; then
  echo "FAIL: $script does not exist"
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

ran=0
failures=0

# run_case <name> <expected-exit> <cargo-exit> <log-text> <required-name...-|->  [expect-substring]
#
# <required-names> is a single string of space-separated test names (or `-`
# for none, which is itself an invalid invocation per the script's usage
# gate). [expect-substring] is optional, checked with plain substring
# matching.
run_case() {
  local name=$1 want_exit=$2 cargo_exit=$3 text=$4 names=$5 expect=${6:-}
  ran=$((ran + 1))

  local out_file="$work/$name.out"
  if [ -z "$text" ]; then
    : > "$out_file"
  else
    printf '%s\n' "$text" > "$out_file"
  fi

  local got got_exit
  if [ "$names" = "-" ]; then
    got=$(bash "$script" "$cargo_exit" "$out_file" 2>&1)
  else
    # shellcheck disable=SC2086  — deliberate word-splitting of the names list
    got=$(bash "$script" "$cargo_exit" "$out_file" $names 2>&1)
  fi
  got_exit=$?

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

# ── The positive case: every required test present as ok, exit 0 ───────────
run_case happy_path 0 0 '
running 2 tests
test a_bare_panic_encodes_the_message_rust_itself_prints ... ok
test a_bare_unreachable_encodes_the_message_rust_itself_prints ... ok

test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out
' 'a_bare_panic_encodes_the_message_rust_itself_prints a_bare_unreachable_encodes_the_message_rust_itself_prints' \
  "all 2 required test(s) observed as 'ok'"

# ── #735's own log shape: an earlier target's failure masks a later one ─────
# compile_reencode_roundtrip fails FIRST; compiler_output's tests never print
# anything at all — not `ok`, not `FAILED`. This is the exact PR #725 /
# job 103825892782 scenario the issue names.
run_case masked_by_earlier_failing_target 1 101 '
running 4 tests
test compiled_method_dispatcher_fallback_arm_is_the_mapped_panic_macro ... ok
test dispatcher_fallback_throws_the_target_neutral_message ... FAILED

failures:

---- dispatcher_fallback_throws_the_target_neutral_message stdout ----
thread panicked

test result: FAILED. 1 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out

error: test failed, to rerun pass `-p ball-lang-encoder --test compile_reencode_roundtrip`
' 'an_iife_with_an_early_return_encodes_as_std_invoke_over_a_lambda an_iife_whose_body_uses_the_question_mark_operator_encodes_as_std_invoke' \
  "an_iife_with_an_early_return_encodes_as_std_invoke_over_a_lambda' never appears as 'ok'"

# ── A required test ran and is RED, not merely absent — reported as FAILED ──
run_case required_test_failed 1 101 '
running 1 test
test an_iife_with_an_early_return_encodes_as_std_invoke_over_a_lambda ... FAILED

test result: FAILED. 0 passed; 1 failed
' 'an_iife_with_an_early_return_encodes_as_std_invoke_over_a_lambda' \
  "required test 'an_iife_with_an_early_return_encodes_as_std_invoke_over_a_lambda' ran and FAILED"

# ── Every required test ok, but the cargo invocation itself was red for an
#    unrelated reason (e.g. clippy folded into the same command) — still red,
#    and says so rather than reporting the floor alone as the problem. ───────
run_case ok_tests_but_nonzero_exit 1 101 '
running 1 test
test a_bare_panic_encodes_the_message_rust_itself_prints ... ok

test result: ok. 1 passed; 0 failed
' 'a_bare_panic_encodes_the_message_rust_itself_prints' \
  "cargo test exited 101"

# ── A module-qualified test name (inside a \`mod\` block) still matches ─────
run_case module_qualified_name_matches 0 0 '
running 1 test
test some_mod::a_nested_test ... ok

test result: ok. 1 passed; 0 failed
' 'a_nested_test' ""

# ── A line that contains "test <name> ... ok" as a SUBSTRING, but not at
#    line start, must not be mistaken for the harness's own result line — the
#    match is anchored with \`^test \`, never a bare substring search. ──────
run_case program_output_is_not_mistaken_for_a_result_line 1 0 '
running 1 test
captured stdout mentions: test a_bare_panic_encodes_the_message_rust_itself_prints ... ok
test a_bare_panic_encodes_the_message_rust_itself_prints ... FAILED

test result: FAILED. 0 passed; 1 failed
' 'a_bare_panic_encodes_the_message_rust_itself_prints' \
  "ran and FAILED"

# ── Malformed exit-code argument: a hard error, never a silently skipped gate
run_case non_integer_exit_code 2 'oops' 'test a ... ok' 'a' \
  "not a bare integer"
run_case empty_exit_code 2 '' 'test a ... ok' 'a' ""

# ── Missing/empty log file: a hard error, never "nothing to check means pass"
run_case missing_required_names_arg 2 0 '' '-' "usage: rust_test_floor.sh"
run_case empty_log_file 1 0 '' 'a' "missing or empty"

# ── Too few arguments at all: usage error, exit 2 ───────────────────────────
ran=$((ran + 1))
got=$(bash "$script" 2>&1)
got_exit=$?
if [ "$got_exit" = 2 ] && printf '%s' "$got" | grep -qF -- "usage: rust_test_floor.sh"; then
  echo "ok   [no_args]"
else
  echo "FAIL [no_args]: expected exit 2 with a usage message, got exit $got_exit: $got"
  failures=$((failures + 1))
fi

# ── Wiring: the rust job actually calls this script, with --no-fail-fast ───
ci_yml="$repo_root/.github/workflows/ci.yml"
ran=$((ran + 1))
if grep -qF 'tools/ci/rust_test_floor.sh' "$ci_yml"; then
  echo "ok   [wiring:ci.yml invokes rust_test_floor.sh]"
else
  echo "FAIL [wiring]: $ci_yml does not invoke tools/ci/rust_test_floor.sh"
  failures=$((failures + 1))
fi

ran=$((ran + 1))
if grep -qF -- '--no-fail-fast' "$ci_yml"; then
  echo "ok   [wiring:ci.yml runs cargo test --no-fail-fast]"
else
  echo "FAIL [wiring]: $ci_yml's rust job does not run cargo test with --no-fail-fast — an earlier \
failing target can still mask a later one's tests from ever running at all"
  failures=$((failures + 1))
fi

# ── Positive floor on the self-test itself ──────────────────────────────────
echo ""
echo "Results: $((ran - failures)) passed, $failures failed, $ran total"
if [ "$ran" -lt 12 ]; then
  echo "FAIL: only $ran assertions ran — this self-test measured almost nothing"
  exit 1
fi
if [ "$failures" -gt 0 ]; then
  echo "FAIL: $failures assertion(s) failed"
  exit 1
fi
echo "PASS: rust_test_floor.sh behaves as specified"
