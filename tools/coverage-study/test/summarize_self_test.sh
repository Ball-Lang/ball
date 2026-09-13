#!/usr/bin/env bash
# Self-test for tools/coverage-study/summarize.sh (issues #493, #491).
#
# WHY A SHELL GATE NEEDS ITS OWN TEST. summarize.sh is the only thing a
# report-only coverage-study job still FAILS on, and this project has been
# burned by shell gates that disabled themselves: a `[ … -lt … ]` that exits 2
# inside an `if` skips the branch and falls through to `exit 0`, green with the
# floor never checked. Every assertion below therefore runs the real script and
# checks its EXIT CODE, not its prose.
#
# WHAT IT PINS.
#
#  1. the pre-existing positive floor: a run that scored zero files, or that
#     printed no summary line at all, is a harness/checkout failure — never a
#     0% result;
#  2. the test-only exclusion line the owner's 2026-09-14 methodology decision
#     on #491 introduced. Tier A now takes a package's own tests OUT of the
#     denominator, so `excluded (test-only): N` is load-bearing provenance for
#     every ratio the study publishes. A Tier A log that does not carry it is a
#     harness whose exclusion rule vanished, and reading that as "excluded 0"
#     would publish a denominator nobody can explain. It must be REQUIRED, and
#     it must be required as a BARE INTEGER — a count that is not an integer
#     cannot be compared, and comparing it anyway is how a gate silently
#     disables itself;
#  3. and that the requirement is scoped to TIER A. summarize.sh is shared with
#     Tier B, whose harness substitutes whole files into a package's own test
#     suite and has no exclusion rule at all. Demanding the line there would
#     redden a job for a reason that does not apply to it.
#
# Run from the repo root:
#   bash tools/coverage-study/test/summarize_self_test.sh
set -uo pipefail

script="$(cd "$(dirname "$0")/.." && pwd)/summarize.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

passed=0
failed=0

check() {
  local name="$1" ok="$2" detail="${3:-}"
  if [ "$ok" = "yes" ]; then
    passed=$((passed + 1))
    echo "PASS  $name"
  else
    failed=$((failed + 1))
    echo "FAIL  $name"
    [ -n "$detail" ] && printf '      %s\n' "$detail"
  fi
}

# Runs summarize.sh over a log and echoes its exit code. The step summary goes
# to a scratch file so a failing assertion cannot pollute a real CI summary.
run_summarize() {
  local log="$1" label="$2" tier="${3:-}"
  local out="$work/summary.md"
  : >"$out"
  if [ -n "$tier" ]; then
    GITHUB_STEP_SUMMARY="$out" bash "$script" "$label" "$log" "$tier" >/dev/null 2>&1
  else
    GITHUB_STEP_SUMMARY="$out" bash "$script" "$label" "$log" >/dev/null 2>&1
  fi
  echo $?
}

write_log() {
  local path="$work/$1"
  shift
  printf '%s\n' "$@" >"$path"
  echo "$path"
}

good="$(write_log good.log \
  '  clean: 65' \
  '  fixpoint-drift: 41' \
  '  excluded (test-only): 12' \
  'Funnel (scored files that survived each stage):' \
  '  1 encoded: 106/106' \
  'Tier A: 65/106 clean (61%)' \
  'Results: 65 passed, 41 failed, 106 total')"
code="$(run_summarize "$good" Dart)"
check "a well-formed Tier A log passes" "$([ "$code" = 0 ] && echo yes || echo no)" "exit=$code"

zero_excl="$(write_log zero.log \
  '  clean: 4' \
  '  excluded (test-only): 0' \
  'Tier A: 4/4 clean (100%)' \
  'Results: 4 passed, 0 failed, 4 total')"
code="$(run_summarize "$zero_excl" Dart)"
check "an exclusion count of zero is a valid count, not a missing line" \
  "$([ "$code" = 0 ] && echo yes || echo no)" "exit=$code"

missing_excl="$(write_log missing.log \
  '  clean: 65' \
  'Tier A: 65/106 clean (61%)' \
  'Results: 65 passed, 41 failed, 106 total')"
code="$(run_summarize "$missing_excl" Dart)"
check "a Tier A log with NO exclusion count fails — the rule vanished" \
  "$([ "$code" = 1 ] && echo yes || echo no)" "exit=$code"

bad_excl="$(write_log bad.log \
  '  clean: 65' \
  '  excluded (test-only): many' \
  'Tier A: 65/106 clean (61%)' \
  'Results: 65 passed, 41 failed, 106 total')"
code="$(run_summarize "$bad_excl" Dart)"
check "an exclusion count that is not a bare integer fails" \
  "$([ "$code" = 1 ] && echo yes || echo no)" "exit=$code"

scored_zero="$(write_log scoredzero.log \
  '  excluded (test-only): 3' \
  'Tier A: 0/0 clean (0%)' \
  'Results: 0 passed, 0 failed, 0 total')"
code="$(run_summarize "$scored_zero" Dart)"
check "the positive floor still fires: a run that scored nothing fails" \
  "$([ "$code" = 1 ] && echo yes || echo no)" "exit=$code"

no_summary="$(write_log nosummary.log '  clean: 3' 'nothing useful here')"
code="$(run_summarize "$no_summary" Dart)"
check "a log with no summary line fails" \
  "$([ "$code" = 1 ] && echo yes || echo no)" "exit=$code"

# Tier B has no exclusion rule — it substitutes files into a package's own test
# suite — so the requirement must NOT apply to it.
tier_b="$(write_log tierb.log \
  '  clean: 100' \
  '  behavioral-drift: 6' \
  'Tier B: 100/106 clean (94%)' \
  'Results: 100 passed, 6 failed, 106 total')"
code="$(run_summarize "$tier_b" Dart "Tier B")"
check "a Tier B log passes WITHOUT an exclusion count — the rule is Tier A's" \
  "$([ "$code" = 0 ] && echo yes || echo no)" "exit=$code"

total=$((passed + failed))
echo "Results: $passed passed, $failed failed, $total total"
if [ "$total" -lt 1 ]; then
  echo "ERROR: the self-test asserted nothing." >&2
  exit 1
fi
[ "$failed" -eq 0 ]
