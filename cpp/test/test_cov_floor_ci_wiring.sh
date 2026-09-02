#!/usr/bin/env bash
# Wiring test for the C++ per-target coverage gate (issues #63 / #59).
#
# WHY THIS EXISTS: cpp/build-cov-floor.sh's floor comparison has been correct
# and unit-pinned (cpp/test/test_build_cov_floor_parsing.sh, 4 cases) since
# #495 — and was invoked by NOTHING. `grep -rn build-cov-floor
# .github/workflows/` returned only prose comments, while coverage.yml's cpp
# job RE-IMPLEMENTED the extraction inline, echoing
# `cpp/<target>: NN% (floor NN%, not enforced)` and never comparing anything.
# A proven-correct exit code that never reaches a job is not a gate, and a
# shell unit test on the script alone can never notice: it only ever runs the
# script directly, never through the workflow.
#
# So this test asserts the two halves that together make the gate real:
#   (a) coverage.yml literally invokes build-cov-floor.sh, does not carry a
#       `continue-on-error` that would swallow its exit code, still asserts the
#       per-target tracefiles are non-empty (the script's missing-tracefile
#       branch is a deliberate non-fatal SKIP), and no longer advertises itself
#       as un-enforced;
#   (b) the script really does propagate a nonzero exit for the below-floor and
#       unparseable-summary scenarios, and zero when every target clears —
#       driven through synthetic tracefiles, so no C++ toolchain, no real lcov
#       and no coverage build are needed. Sub-second.
#
# Wired into ci.yml's always-on `proto` job (no `needs` gate, no job-level
# `if`), next to test_build_cov_floor_parsing.sh, so it runs on every PR.
#
# Usage: bash cpp/test/test_cov_floor_ci_wiring.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../build-cov-floor.sh"
WORKFLOW="$HERE/../../.github/workflows/coverage.yml"

for f in "$SCRIPT" "$WORKFLOW"; do
  [ -f "$f" ] || {
    echo "::error::missing $f"
    exit 1
  }
done

pass=0
fail=0

# assert <name> <expected exit 0|1> <command...>
# The command's own exit status is what is being asserted.
assert_cmd() {
  local name="$1" want="$2"
  shift 2
  local out rc
  out="$("$@" 2>&1)"
  rc=$?
  if [ "$rc" -eq "$want" ]; then
    pass=$((pass + 1))
    echo "PASS  $name"
  else
    fail=$((fail + 1))
    echo "FAIL  $name: expected exit $want, got $rc"
    printf '  %s\n' "$out"
  fi
}

# ─────────────────────────────────────────────────────────────────────
# (a) The workflow wiring — a literal grep, because this is exactly what a
#     unit test on the script alone structurally cannot prove.
# ─────────────────────────────────────────────────────────────────────

# A bare name check is NOT sufficient on its own: before this change
# coverage.yml already mentioned build-cov-floor.sh five times, all in prose
# comments. It is kept as the cheap first signal; the anchored command check
# below is the load-bearing one.
assert_cmd "coverage.yml references build-cov-floor.sh at all" 0 \
  grep -q 'build-cov-floor\.sh' "$WORKFLOW"

# The invocation must be a real command, not just another prose mention: the
# step runs it through bash so the (non-executable, 100644) script is portable.
assert_cmd "coverage.yml RUNS the script (bash cpp/build-cov-floor.sh)" 0 \
  grep -q 'bash cpp/build-cov-floor\.sh' "$WORKFLOW"

# A `continue-on-error:` KEY would swallow the script's exit code and reduce the
# gate to an annotation — the workflow's own comments warn about exactly this.
# Anchored to the YAML key so that warning prose is not itself a false positive.
assert_cmd "coverage.yml declares no continue-on-error step" 1 \
  grep -qE '^[[:space:]]*continue-on-error:' "$WORKFLOW"

# The script SKIPs (exit 0) when a tracefile is absent, so the step must prove
# the extraction produced something before trusting the exit code.
assert_cmd "the gate step asserts the per-target tracefiles are non-empty" 0 \
  grep -q 'if \[ ! -s "\$out" \]' "$WORKFLOW"

# ... and must count the OK lines, so "nothing ran" cannot read as "all passed".
assert_cmd "the gate step asserts a positive per-target OK count" 0 \
  grep -q "grep -c '\^OK ' cov-floor.txt" "$WORKFLOW"

# The report-only step PRINTED "(floor NN%, not enforced)" per target plus a
# "these per-target floors are not yet enforced" summary line. Assert nothing
# echoes that any more, matched on the `echo` so the comment above -- which
# quotes the old wording to explain what changed -- is not a false positive.
assert_cmd "coverage.yml no longer PRINTS the floors as not enforced" 1 \
  grep -qE 'echo .*not (yet )?enforced' "$WORKFLOW"

# ─────────────────────────────────────────────────────────────────────
# (b) Exit-code propagation, through synthetic tracefiles.
#     A stub `lcov` on PATH replays a canned `lcov --summary` for each target
#     against a scratch copy of the script (same harness shape as
#     test_build_cov_floor_parsing.sh, which pins the parser itself).
# ─────────────────────────────────────────────────────────────────────

# summary_line <pct> — one line in the exact shape `lcov --summary` prints.
summary_line() { printf '  lines......: %s%% (1000 of 1100 lines)\n' "$1"; }

# run_script <compiler summary> <encoder summary> <shared summary>
# Echoes nothing; returns the script's exit status.
run_script() {
  local c="$1" e="$2" s="$3"
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/build-cov" "$tmp/bin"
  cp "$SCRIPT" "$tmp/build-cov-floor.sh"

  local t
  for t in compiler encoder shared; do : >"$tmp/build-cov/cpp.$t.lcov"; done
  printf '%s' "$c" >"$tmp/build-cov/cpp.compiler.lcov.summary"
  printf '%s' "$e" >"$tmp/build-cov/cpp.encoder.lcov.summary"
  printf '%s' "$s" >"$tmp/build-cov/cpp.shared.lcov.summary"

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

  local rc
  (cd "$tmp" && PATH="$tmp/bin:$PATH" bash ./build-cov-floor.sh) >/dev/null 2>&1
  rc=$?
  rm -rf "$tmp"
  return "$rc"
}

# Every target clears its floor -> the step must go green.
assert_cmd "all targets above floor -> exit 0" 0 \
  run_script "$(summary_line 92.3)" "$(summary_line 89.1)" "$(summary_line 81.8)"

# One target regresses under its floor -> the step must go red. This is the
# whole point of gating, and the case the old report-only step could not fail.
assert_cmd "one target below floor -> exit 1" 1 \
  run_script "$(summary_line 70.0)" "$(summary_line 89.1)" "$(summary_line 81.8)"

# An unparseable summary is a broken measurement, not an absent one: fail loud
# rather than let an un-checked floor pass.
assert_cmd "unparseable summary -> exit 1" 1 \
  run_script "lcov: ERROR: no valid records found in tracefile" \
  "$(summary_line 89.1)" "$(summary_line 81.8)"

total=$((pass + fail))
# Positive floor: an exit code plus a failure count cannot tell "everything
# passed" from "nothing ran".
if [ "$total" -lt 1 ]; then
  echo "::error::cov-floor CI wiring test ran zero cases"
  exit 1
fi
echo "Results: $pass passed, $fail failed, $total total"
[ "$fail" -eq 0 ] || exit 1
