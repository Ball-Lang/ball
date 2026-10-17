#!/usr/bin/env bash
# Parse a compiler conformance leg's `Results:` line and gate it on a POSITIVE
# FLOOR plus a per-target RATCHET THAT IS ENFORCED IN BOTH DIRECTIONS
# (issue #792).
#
# Why this exists as a script instead of four copies of inline workflow bash:
# the four `*-compiler` rows in .github/workflows/conformance-matrix.yml each
# carried a byte-identical copy of the parse block and the comparison, and the
# only response any of them had to a measured GAIN was an advisory annotation:
#
#   if [ "$passed" -gt "$GO_COMPILER_FLOOR" ]; then
#     echo "::notice::Go compiler leg IMPROVED: $passed passed (floor was ...)"
#   fi
#   exit 0
#
# So `GO_COMPILER_FLOOR` sat at 291 while the row measured 297 — PR #738's own
# matrix run 35552669922 printed `Results: 297 passed, 63 failed, 360 total
# (floor: 291)`. Six fixtures of earned gain went unclaimed, and a regression
# back to 292 would have stayed green for as long as the floor stayed stale. A
# ::notice:: in a CI log is not a gate: a human has to read it and act, and for
# six fixtures nobody did. docs/TESTING_STRATEGY.md §2c already required the
# raise — in prose, and prose stops nothing. Inline bash in a workflow cannot
# be unit-tested; this script can, and is, by tools/test/test_compiler_floor.sh
# (run on every PR by ci.yml's `proto` job).
#
# Contract:
#
#   compiler_floor.sh <label> <floor-var-name> <leg-exit-code> <output-file>
#
#   label           human name for the row, e.g. "Go".
#   floor-var-name  the NAME of the row's floor constant, e.g.
#                   GO_COMPILER_FLOOR — not its value. The value is read back
#                   with indirect expansion, so the constant the error message
#                   tells a human to edit is the same one the comparison used;
#                   two spellings cannot drift apart. An unset variable (a typo,
#                   a rename) is a hard error, never a comparison against the
#                   empty string.
#   leg-exit-code   the leg's own exit status. Reported, never gated on — a
#                   compiler leg exits non-zero while ANY fixture fails, which
#                   is the expected state until every target compiles the whole
#                   corpus. It is what names the cause when there is no
#                   `Results:` line to parse at all.
#   output-file     a file holding the leg's combined stdout+stderr.
#
# Gates, in order:
#   1. the floor is set, and is a bare integer >= 1;
#   2. a final `^Results: N passed, M failed, T total` line exists and every
#      count is a bare integer (a multiline capture would make `[ … -lt … ]`
#      exit 2, and a failing `[` inside an `if` SKIPS the branch and falls
#      through to exit 0 — a silently disabled gate);
#   3. total >= 1   — the harness discovered fixtures (harness health,
#                     #439/#444);
#   4. passed >= 1  — the leg actually compiled something;
#   5. passed >= floor — ratchet DOWN: a fixture that used to compile still
#                     does;
#   6. passed <= floor — ratchet UP (#792): an improvement is not green until
#                     the floor that locks it in lands in the SAME PR. The
#                     error names the exact constant and the exact value to
#                     write, so acting on it is a one-line edit, not an
#                     investigation.
#
# Gate 6 is deliberately scoped to the compiler legs. The `*-roundtrip` rows
# keep tools/ci/roundtrip_floor.sh's advisory notice: their floors are climbing
# under #689/#690/#791 and are already raised in the same PR as each gain.
#
# Never lower a floor to turn a red build green — that is what a ratchet is for.
set -uo pipefail

label=${1:-}
floor_var=${2:-}
leg_exit=${3:-}
output_file=${4:-}

if [ -z "$label" ] || [ -z "$floor_var" ] || [ -z "$output_file" ]; then
  echo "::error::compiler_floor.sh: usage: compiler_floor.sh <label> <floor-var-name> <leg-exit-code> <output-file>"
  exit 2
fi

if [ ! -f "$output_file" ]; then
  echo "::error::compiler_floor.sh: leg output file '$output_file' does not exist — nothing to measure."
  exit 2
fi

# ── 1. The floor must itself be trustworthy ─────────────────────────────────
# A typo'd or removed env var would otherwise make every comparison below error
# out with exit 2 inside an `if`, which bash treats as "false" and skips: the
# gate would disappear while the job stayed green.
if [ -z "${!floor_var+isset}" ]; then
  echo "::error::compiler_floor.sh: the $label compiler leg's floor variable \$$floor_var is not set. Refusing to run an ungated measurement."
  exit 2
fi
floor=${!floor_var}
case "$floor" in
  ''|*[!0-9]*)
    echo "::error::compiler_floor.sh: \$$floor_var is '$floor', not a bare integer. Refusing to run an ungated measurement."
    exit 2;;
esac
if [ "$floor" -lt 1 ]; then
  echo "::error::compiler_floor.sh: \$$floor_var is $floor. A compiler leg that cannot compile a single fixture is not measuring anything — the floor must be >= 1."
  exit 2
fi

case "$leg_exit" in
  ''|*[!0-9-]*) leg_exit="unknown";;
esac

# ── 2. Parse the FINAL `Results:` line only ─────────────────────────────────
# Never a global grep over all output: a leg's own progress chatter can contain
# a second match (the Rust leg prints "320 fixtures emitted Rust, 0 failed to
# compile"), which makes the capture MULTILINE, splits the echo, and makes
# GITHUB_OUTPUT reject the write. `tail -1` makes that unreachable; the integer
# guard below asserts it rather than trusting it.
#
# `sed -nE` rather than `grep -oP`: the whole count is extracted from ONE
# anchored pattern per field, so a stray `, 7 total` anywhere else on the line
# cannot be picked up, and it needs no PCRE (GNU grep's `-P` refuses to run
# under a non-UTF-8 locale, which silently turns every capture into the empty
# string).
summary=$(grep -E '^Results: [0-9]+ passed, [0-9]+ failed, [0-9]+ total' "$output_file" | tail -1 || true)
passed=$(printf '%s\n' "$summary" | sed -nE 's/^Results: ([0-9]+) passed, [0-9]+ failed, [0-9]+ total.*$/\1/p' | tail -1)
failed=$(printf '%s\n' "$summary" | sed -nE 's/^Results: [0-9]+ passed, ([0-9]+) failed, [0-9]+ total.*$/\1/p' | tail -1)
total=$(printf '%s\n' "$summary" | sed -nE 's/^Results: [0-9]+ passed, [0-9]+ failed, ([0-9]+) total.*$/\1/p' | tail -1)

for v in "$passed" "$failed" "$total"; do
  case "$v" in
    ''|*[!0-9]*)
      echo "::error::$label compiler leg: could not parse a clean integer count from the Results line (got '$v'). Refusing to report a number this gate cannot trust. Leg exit code was $leg_exit."
      exit 1;;
  esac
done

# Written BEFORE the gates: the aggregate matrix job renders this row from these
# outputs, and a red row that reports no numbers is a row nobody can read.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "passed=$passed"
    echo "failed=$failed"
    echo "total=$total"
    echo "floor=$floor"
  } >> "$GITHUB_OUTPUT"
fi

echo ""
echo "=== $label Compiler Leg (floored + ratcheted) ==="
echo "Results: $passed passed, $failed failed, $total total (floor: $floor)"
echo "compiler leg exit code: $leg_exit (non-zero is expected while any fixture still fails)"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### $label compiler leg (floor $floor, ratcheted both ways — issue #792)"
    echo ""
    echo "**$passed/$total** fixtures compile Ball -> $label."
    echo ""
  } >> "$GITHUB_STEP_SUMMARY"
fi

# ── 3. Harness health ────────────────────────────────────────────────────────
if [ "$total" -lt 1 ]; then
  echo "::error::The $label compiler leg reported no fixtures (total=$total) — it measured nothing. Leg exit code was $leg_exit."
  exit 1
fi

# ── 4. Positive floor ────────────────────────────────────────────────────────
if [ "$passed" -lt 1 ]; then
  echo "::error::The $label compiler leg compiled ZERO of $total fixtures. A measurement leg that cannot pass a single fixture is not measuring — fix the instrument, never leave the row green on a flat zero."
  exit 1
fi

# ── 5. Ratchet DOWN ──────────────────────────────────────────────────────────
if [ "$passed" -lt "$floor" ]; then
  echo "::error::$label compiler leg REGRESSED: $passed passed, below the floor of $floor — a fixture that used to compile no longer does."
  exit 1
fi

# ── 6. Ratchet UP (#792) ─────────────────────────────────────────────────────
if [ "$passed" -gt "$floor" ]; then
  echo "::error::$label compiler leg IMPROVED to $passed passed, above its floor of $floor — and an improvement is not green until it is LOCKED IN. Raise $floor_var to $passed in .github/workflows/conformance-matrix.yml, in this same PR (docs/TESTING_STRATEGY.md §2c). This used to be an advisory ::notice:: nobody had to act on, which is how the Go leg ran six fixtures above a stale floor of 291 (issue #792)."
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "**Unclaimed gain:** this leg measures $passed, above its floor of $floor."
      echo "Raise \`$floor_var\` to \`$passed\` in \`.github/workflows/conformance-matrix.yml\`."
      echo ""
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 1
fi

exit 0
