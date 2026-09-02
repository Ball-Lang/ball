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
# (a) The workflow wiring — a grep, because this is exactly what a unit test
#     on the script alone structurally cannot prove.
#
#     These assertions are deliberately SCOPED and SEMANTIC rather than
#     whole-file and literal. An earlier draft grepped the whole workflow for
#     exact YAML text (`if [ ! -s "$out" ]`) and for a `continue-on-error:` key
#     ANYWHERE in coverage.yml — so an unrelated edit to the Dart or Rust job,
#     or a harmless rename of `$out`, would have turned this test red while the
#     C++ gate stayed perfectly intact. False reds train people to delete
#     tests. Slice the cpp job (and the gate step inside it) first, then assert
#     the BEHAVIOUR each line is there for.
# ─────────────────────────────────────────────────────────────────────

# slice_job <key> — the block of one top-level job in coverage.yml.
slice_job() {
  awk -v job="$1" '
    $0 ~ "^  " job ":[[:space:]]*$" { inj = 1; print; next }
    inj && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { inj = 0 }
    inj { print }
  ' "$WORKFLOW"
}

# slice_gate_step — the per-target floors step, from its `- name:` line to the
# line before the next step at the same indentation.
slice_gate_step() {
  awk '
    /^      - name: .*[Pp]er-target coverage floors/ { ins = 1; print; next }
    ins && /^      - name: / { ins = 0 }
    ins { print }
  ' "$WORKFLOW"
}

CPP_JOB="$(slice_job cpp)"
GATE_STEP="$(slice_gate_step)"

# Both slices must be non-empty, or every assertion below would run against an
# empty haystack — a negative assertion would then pass vacuously, which is the
# same "nothing ran reads as all passed" trap the gate itself guards against.
in_cpp_job() { printf '%s\n' "$CPP_JOB" | grep -qE "$1"; }
in_gate_step() { printf '%s\n' "$GATE_STEP" | grep -qE "$1"; }
not_in_cpp_job() { ! in_cpp_job "$1"; }

assert_cmd "the cpp job slice is non-empty" 0 \
  in_cpp_job 'runs-on:'
assert_cmd "the per-target gate step slice is non-empty" 0 \
  in_gate_step 'run:'

# The invocation must be a real command, not a prose mention: before this
# change coverage.yml already named build-cov-floor.sh five times, all in
# comments. Tolerant of whitespace and of the path it is spelled with.
assert_cmd "the gate step RUNS build-cov-floor.sh" 0 \
  in_gate_step 'bash[[:space:]]+[^[:space:]]*build-cov-floor\.sh'

# A `continue-on-error:` KEY would swallow the script's exit code and reduce
# the gate to an annotation — the workflow's own comments warn about exactly
# this. Scoped to the cpp job, so another job's (legitimate) use of the key is
# not this test's business.
assert_cmd "the cpp job declares no continue-on-error step" 0 \
  not_in_cpp_job '^[[:space:]]*continue-on-error:'

# The script SKIPs (exit 0) when a tracefile is absent, so the step must prove
# the extraction produced something before trusting the exit code. Asserted as
# "this step contains a non-empty-file test", not as one exact spelling.
assert_cmd "the gate step tests the per-target tracefile is non-empty" 0 \
  in_gate_step '! *-s[[:space:]]'

# ... and must count the OK lines, so "nothing ran" cannot read as "all
# passed".
assert_cmd "the gate step counts the per-target OK lines" 0 \
  in_gate_step 'grep[[:space:]]+-c[[:space:]]+.*OK'

# The script's exit status must reach the step's exit status.
assert_cmd "the gate step propagates the script's exit code" 0 \
  in_gate_step 'exit[[:space:]]+"?\$rc"?'

# ORDER: a below-floor target makes the script exit 1 AND print only 2 OK
# lines. With the OK-count check first, the step went red naming a phantom
# extraction bug instead of the target that actually regressed — right colour,
# wrong cause. Assert the exit-code check comes first.
rc_before_okcount() {
  local rc_ln ok_ln
  rc_ln="$(printf '%s\n' "$GATE_STEP" |
    grep -nE '\$rc"?[[:space:]]+-ne[[:space:]]+0' | head -1 | cut -d: -f1)"
  ok_ln="$(printf '%s\n' "$GATE_STEP" |
    grep -nE '\$\{ok:-0\}"?[[:space:]]+-ne' | head -1 | cut -d: -f1)"
  [ -n "$rc_ln" ] && [ -n "$ok_ln" ] && [ "$rc_ln" -lt "$ok_ln" ]
}
assert_cmd "the gate step reports the script's failure BEFORE the OK-count" 0 \
  rc_before_okcount

# The report-only step PRINTED "(floor NN%, not enforced)" per target plus a
# "these per-target floors are not yet enforced" summary line. Assert nothing
# echoes that any more, matched on the `echo` so the comments above -- which
# quote the old wording to explain what changed -- are not false positives.
assert_cmd "the cpp job no longer PRINTS the floors as not enforced" 0 \
  not_in_cpp_job 'echo .*not (yet )?enforced'

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
