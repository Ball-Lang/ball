#!/usr/bin/env bash
# Wiring test for the ORDER of ci.yml's `cpp` job steps around the compiler-
# cache gate (issues #660 / #599 / #594).
#
# WHY THIS EXISTS: the gate's non-cacheable ceiling is 0 on all three OS legs,
# and on ubuntu/macOS that number is only true because of WHERE the gate step
# sits. `cpp/test/full_e2e.sh`'s compile-and-link smoke prefixes ccache to a
# `g++` invocation that both compiles and links; a link is uncacheable by
# construction, so it adds 4 uncacheable calls. The ubuntu leg's POST-JOB
# ccache summary shows them (`Cacheable calls: 322 / 326`), while the gate's own
# read, taken earlier in the job, sees `322 / 322` and reports 0.
#
# Move the gate below those smoke steps and the leg goes red at 4 against a
# ceiling of 0 — right colour, completely misleading cause ("the cache declined
# 4 compiles", pointing at build types and shared PDBs, when nothing regressed).
# The dependency was documented in THREE places (the gate script's header,
# cpp/test/AGENTS.md, .claude/rules/cpp.md) and enforced in none, which is the
# same "a documented invariant is not a gate" shape #643's review flagged.
#
# So this asserts, from ci.yml itself:
#   (a) the `cpp` job has exactly ONE step that runs
#       check_compiler_cache_applied.sh, and it is named `Compiler cache
#       applied` (the name the three docs quote);
#   (b) at least one step in that job runs full_e2e.sh — without this the order
#       assertion below would be vacuously true the day the smoke steps are
#       removed or renamed away;
#   (c) every full_e2e.sh step comes AFTER the gate step;
#   (d) the job is still ONE steps list over a 3-OS matrix, so (c) holds for
#       every leg rather than for whichever leg someone later split out;
#   (e) the job carries no `continue-on-error`, which would let the gate's exit
#       code evaporate.
#
# HOUSE RULE THIS FILE ALSO ENFORCES ON ITSELF (#700): no pipeline here may end
# in `head`. `head -N` exits as soon as it has its N lines, the producer
# upstream takes SIGPIPE, and `set -o pipefail` turns that into exit 141 — a
# "failure" with nothing wrong, which is what produced RED run 34755211709.
# Every first-line read goes through `awk 'NR == 1'`, which consumes its whole
# input. The `no_head_after_a_pipe` case at the bottom is the negative control.
#
# ...and then proves the assertion is not vacuous with a NEGATIVE CONTROL: the
# real ci.yml, rewritten so the gate step is relocated to the end of the `cpp`
# job, must be REJECTED. A checker that cannot fail is not a checker.
#
# No YAML library, no toolchain, sub-second; wired into ci.yml's always-on
# `proto` job next to the other CI-plumbing tests.
#
# Usage: bash cpp/test/test_cache_gate_step_order.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW="$HERE/../../.github/workflows/ci.yml"
GATE_SCRIPT="$HERE/check_compiler_cache_applied.sh"

for f in "$WORKFLOW" "$GATE_SCRIPT"; do
  [ -f "$f" ] || {
    echo "::error::missing $f"
    exit 1
  }
done

pass=0
fail=0

# assert_cmd <name> <expected exit 0|1> <command...>
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

# ── the extractor ──────────────────────────────────────────────────────────
#
# slice_cpp_job <workflow> — the `cpp:` job block. Top-level jobs sit at two
# spaces of indentation; the block ends at the next such key.
slice_cpp_job() {
  awk '
    /^  cpp:[[:space:]]*$/ { inj = 1; print; next }
    inj && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { inj = 0 }
    inj { print }
  ' "$1"
}

# step_marks <workflow> — one `<step-number> <kind>` line per interesting step
# of the cpp job, where kind is `gate` (runs the compiler-cache gate) or
# `smoke` (runs full_e2e.sh). Steps are numbered in file order.
#
# Matching is SEMANTIC — the command a step runs, not the prose around it — and
# comment lines are excluded, because both scripts are named many times in this
# job's explanatory comments and a comment is not an execution order.
step_marks() {
  slice_cpp_job "$1" | awk '
    /^      - / { step++ }
    /^[[:space:]]*#/ { next }
    step > 0 && /check_compiler_cache_applied\.sh/ { print step " gate" }
    step > 0 && /full_e2e\.sh/ { print step " smoke" }
  ' | sort -u -k1,1n -k2,2
}

# gate_step_names <workflow> — the `- name:` text of every step that runs the
# gate, so a rename away from the phrase all three docs quote is caught.
gate_step_names() {
  slice_cpp_job "$1" | awk '
    /^      - / { name = ""; hit = 0 }
    /^      - name:/ { name = $0 }
    /^[[:space:]]*#/ { next }
    /check_compiler_cache_applied\.sh/ { if (!hit && name != "") { print name; hit = 1 } }
  '
}

# check_order <workflow> — the whole assertion, exit 0 when it holds.
# Everything it can reject prints a reason first; silence plus exit 0 is the
# only success.
check_order() {
  local wf="$1" marks gates smokes first_smoke rc=0
  marks="$(step_marks "$wf")"

  gates="$(printf '%s\n' "$marks" | awk '$2 == "gate" { print $1 }')"
  smokes="$(printf '%s\n' "$marks" | awk '$2 == "smoke" { print $1 }')"

  local n_gates n_smokes
  n_gates="$(printf '%s' "$gates" | grep -c '[0-9]')"
  n_smokes="$(printf '%s' "$smokes" | grep -c '[0-9]')"

  if [ "$n_gates" -ne 1 ]; then
    echo "::error::the cpp job runs check_compiler_cache_applied.sh in $n_gates step(s); expected exactly 1."
    rc=1
  fi
  # Positive floor on the haystack: with no smoke step the order check below
  # would pass while asserting nothing at all.
  if [ "$n_smokes" -lt 1 ]; then
    echo "::error::the cpp job runs full_e2e.sh in no step — the gate/smoke order assertion would be vacuous."
    rc=1
  fi
  [ "$rc" -eq 0 ] || return 1

  # `awk 'NR == 1'`, never a first-line reader that exits early: see the
  # no_head_after_a_pipe control at the bottom of this file.
  local gate_step
  gate_step="$(printf '%s\n' "$gates" | awk 'NR == 1')"
  first_smoke="$(printf '%s\n' "$smokes" | awk 'NR == 1')"
  if [ "$gate_step" -ge "$first_smoke" ]; then
    echo "::error::the 'Compiler cache applied' step is step $gate_step, at or after the first full_e2e.sh step ($first_smoke). full_e2e.sh's compile-and-link smoke adds uncacheable ccache calls, so the gate MUST read the statistics before it runs or the ubuntu/macOS legs go red at 4 against a ceiling of 0. See issues #660 / #599."
    return 1
  fi

  # `grep -c`, not `grep -q` — see cpp_job_nonempty below for why a `-q` on the
  # far side of a pipe can report SIGPIPE (141) instead of a real result.
  local named
  named="$(gate_step_names "$wf" | grep -c 'Compiler cache applied')"
  if [ "${named:-0}" -lt 1 ]; then
    echo "::error::the step running check_compiler_cache_applied.sh is no longer named 'Compiler cache applied' — cpp/test/AGENTS.md, .claude/rules/cpp.md and the gate script's own header all quote that name."
    return 1
  fi

  # One steps list over the 3-OS matrix is what makes the order above true for
  # EVERY leg. A per-OS split would need its own assertion.
  local oses
  oses="$(slice_cpp_job "$wf" | sed -n 's/^[[:space:]]*os:[[:space:]]*\[\(.*\)\]$/\1/p' | awk 'NR == 1')"
  local n_os
  n_os="$(printf '%s' "$oses" | tr ',' '\n' | grep -c 'latest')"
  if [ "$n_os" -ne 3 ]; then
    echo "::error::the cpp job's matrix lists $n_os '*-latest' runner(s) (\`$oses\`); expected the 3-OS matrix this single steps list is asserted for."
    return 1
  fi

  local coe
  coe="$(slice_cpp_job "$wf" | grep -cE '^[[:space:]]*continue-on-error:')"
  if [ "${coe:-0}" -ge 1 ]; then
    echo "::error::the cpp job declares a continue-on-error step — the compiler-cache gate's exit code would stop reaching the job."
    return 1
  fi

  return 0
}

# ── (a)-(e) against the REAL workflow ──────────────────────────────────────
assert_cmd "the committed ci.yml satisfies the gate/smoke step order" 0 \
  check_order "$WORKFLOW"

# The slice must be non-empty, or every assertion above would run on an empty
# haystack. (check_order's own counts would catch it, but say so explicitly.)
#
# `grep -c`, never `grep -q`, on the far side of a pipe: `-q` exits at the FIRST
# match, and the cpp job slice is far larger than a pipe buffer, so the awk
# producing it takes SIGPIPE and `set -o pipefail` reports 141 — a "failure"
# with nothing wrong. ci.yml's own harness-smoke step carries the same warning.
cpp_job_nonempty() {
  local n
  n="$(slice_cpp_job "$WORKFLOW" | grep -c 'runs-on:')"
  [ "${n:-0}" -ge 1 ]
}
assert_cmd "the cpp job slice is non-empty" 0 cpp_job_nonempty

# ── the NEGATIVE CONTROL: the same file, gate step relocated ───────────────
# Rewrites the real ci.yml so the `Compiler cache applied` step block moves to
# the END of the cpp job — i.e. after full_e2e.sh's smoke steps, the exact
# reorder this test exists to forbid.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SWAPPED="$TMP/ci-gate-last.yml"

awk '
  /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
    if (injob) { printf "%s", gate; gate = ""; injob = 0; ingate = 0 }
    if ($0 ~ /^  cpp:[[:space:]]*$/) { injob = 1 }
    print; next
  }
  injob && /^      - name:.*Compiler cache applied/ { ingate = 1; gate = gate $0 "\n"; next }
  ingate && /^      - / { ingate = 0 }
  ingate { gate = gate $0 "\n"; next }
  { print }
  END { if (injob) printf "%s", gate }
' "$WORKFLOW" >"$SWAPPED"

# The rewrite must have actually moved something, or the control would be
# testing the committed file twice and "passing" for the wrong reason.
control_is_a_real_swap() {
  cmp -s "$WORKFLOW" "$SWAPPED" && return 1
  grep -q 'check_compiler_cache_applied\.sh' "$SWAPPED" || return 1
  [ "$(step_marks "$SWAPPED" | grep -c ' gate$')" -eq 1 ] || return 1
  return 0
}
assert_cmd "the negative control really relocated the gate step" 0 \
  control_is_a_real_swap

assert_cmd "a ci.yml with the gate step AFTER the smoke steps is rejected" 1 \
  check_order "$SWAPPED"

# ── two more controls, so each rejection branch is exercised ───────────────
NO_SMOKE="$TMP/ci-no-smoke.yml"
# The replacement name must not itself contain `full_e2e.sh`, or the control
# would still match and pass for the wrong reason.
sed 's|full_e2e\.sh|e2e_smoke_harness.sh|g' "$WORKFLOW" >"$NO_SMOKE"
assert_cmd "a ci.yml whose cpp job runs no full_e2e.sh is rejected (vacuous order)" 1 \
  check_order "$NO_SMOKE"

RENAMED="$TMP/ci-renamed-gate.yml"
sed 's|- name: "Compiler cache applied (#594)"|- name: "Cache sanity"|' "$WORKFLOW" >"$RENAMED"
assert_cmd "a ci.yml that renamed the gate step away from the documented name is rejected" 1 \
  check_order "$RENAMED"

# ── the SIGPIPE control (#700 item 4) ──────────────────────────────────────
#
# Nothing in this file may pipe into `head`. `head -N` exits as soon as it has
# its N lines, so the producer upstream takes SIGPIPE, and under
# `set -o pipefail` the whole pipeline reports 141 — a "failure" with nothing
# wrong. That is the shape that produced RED run 34755211709, and the same
# reasoning the `grep -c`, never `grep -q` comment above spells out: the two
# differ only in WHICH command exits early. Every first-line read here goes
# through `awk 'NR==1'`, which consumes its whole input, or through a shell
# variable. This grep is the negative control for that rule.
no_head_after_a_pipe() {
  local n
  n="$(grep -cE '\|[[:space:]]*head([[:space:]]|$)' "${BASH_SOURCE[0]}")"
  if [ "${n:-1}" -ne 0 ]; then
    echo "::error::$n pipeline(s) in this file end in \`head\`, which exits early and makes the upstream producer die of SIGPIPE — exit 141 under \`set -o pipefail\`, a failure with nothing wrong (run 34755211709, #700). Use \`awk 'NR==1'\` or read the value into a variable."
    return 1
  fi
  return 0
}
assert_cmd "no pipeline in this file ends in head (SIGPIPE 141 under pipefail)" 0 \
  no_head_after_a_pipe

total=$((pass + fail))
# Positive floor: an exit code plus a failure count cannot tell "everything
# passed" from "nothing ran". Set AT the number of cases above.
if [ "$total" -lt 7 ]; then
  echo "::error::cache-gate step-order test ran only $total case(s) — expected at least 7."
  exit 1
fi
echo "Results: $pass passed, $fail failed, $total total"
[ "$fail" -eq 0 ] || exit 1
