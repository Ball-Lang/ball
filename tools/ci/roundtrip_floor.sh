#!/usr/bin/env bash
# Parse a round-trip conformance leg's `Results:` line and gate it on a POSITIVE
# FLOOR plus a per-target RATCHET (issue #642).
#
# Why this exists as a script instead of four copies of inline workflow bash:
# the four `*-roundtrip` rows in .github/workflows/conformance-matrix.yml used
# to carry four byte-identical copies of the parse block and NO floor on the
# `passed` count. Every one of them printed `Results: 0 passed, 349 failed, 349
# total` on every run for as long as the legs have existed, and the jobs went
# green — the only assertion was `total >= 1` (the harness ran at all). Inline
# bash in a workflow cannot be unit-tested; this script can, and is, by
# tools/test/test_roundtrip_floor.sh (run on every PR by ci.yml's `proto` job).
#
# Contract:
#
#   roundtrip_floor.sh <label> <floor> <leg-exit-code> <output-file> [note-file] \
#                      [fail-pattern] [timeout-pattern]
#
#   label           human name for the row, e.g. "C#".
#   floor           the per-target ratchet constant. MUST be an integer >= 1:
#                   an empty or non-numeric value is a hard error, never a
#                   silently disabled gate.
#   leg-exit-code   the leg's own exit status. Reported, never gated on — a
#                   round-trip leg exits non-zero while ANY fixture fails, which
#                   is the expected state until every target round-trips the
#                   whole corpus.
#   output-file     a file holding the leg's combined stdout+stderr.
#   note-file       optional markdown appended to the GitHub step summary. It is
#                   where the row NAMES its remaining gap and the issue tracking
#                   it — a row that still fails most of the corpus must say so
#                   with an issue number, never "expected baseline".
#   fail-pattern    optional ERE matching the leg's per-fixture failure lines;
#                   defaults to Go/Python/Rust's shared `FAILING [name] …`
#                   shape. The FIRST match is echoed verbatim, to stdout and to
#                   the step summary, so the row's log always carries one real,
#                   unabridged diagnosis of the gap rather than a bare count.
#   timeout-pattern optional ERE matching a per-fixture TIMEOUT line; defaults to
#                   the same legs' `FAILING [name] timeout …`. ANY match is a
#                   hard error — see gate 4 below.
#
# Gates, in order:
#   1. the floor itself is a bare integer >= 1;
#   2. a final `^Results: N passed, M failed, T total` line exists and every
#      count is a bare integer (a multiline capture would make `[ … -lt … ]`
#      exit 2, and a failing `[` inside an `if` SKIPS the branch and falls
#      through to exit 0 — a silently disabled gate, see
#      .claude/rules/ci-gates or the C# compiler leg's own comment);
#   3. total >= 1   — the harness discovered fixtures (harness health);
#   4. no fixture TIMED OUT (issue #693). A re-encoded program that never
#      terminates is the #55 class — structurally valid, `ball check`-clean, and
#      it computes nothing. Folded into `failed` it is indistinguishable from an
#      ordinary golden mismatch, and the ratchet can only notice it once enough
#      fixtures hang to push `passed` under the floor, which is exactly how 28
#      loop fixtures hung for as long as they did. Measured at ZERO on all four
#      rows (run 34791323674, main) before this gate was enabled — a gate is
#      switched on at a measured value, never at an aspiration;
#   5. passed >= 1  — the leg actually round-tripped something. THE gate #642
#                     adds: a flat zero is no longer green;
#   6. passed >= floor — ratchet: a fixture that used to round-trip still does.
#
# An improvement prints a ::notice:: naming the exact new floor to record.
# Never lower a floor to turn a red build green — that is what a ratchet is for.
set -uo pipefail

label=${1:-}
floor=${2:-}
leg_exit=${3:-}
output_file=${4:-}
note_file=${5:-}
# Go, Python and Rust all print `FAILING [name] status detail`; C#'s harness
# prints `  <name>: ERROR: …` under a `--- failures ---` header, so that row
# passes its own pattern.
fail_pattern=${6:-'^FAILING \['}
# Anchored on the STATUS field, never on the word "timeout" anywhere in the line:
# `196_timeout` is a FIXTURE NAME, and a looser match would red a leg that never
# hung. C#'s harness prints `  <name>: TIMEOUT`, so that row passes its own.
timeout_pattern=${7:-'^FAILING \[[^]]+\] timeout'}

if [ -z "$label" ] || [ -z "$output_file" ]; then
  echo "::error::roundtrip_floor.sh: usage: roundtrip_floor.sh <label> <floor> <leg-exit-code> <output-file> [note-file]"
  exit 2
fi

if [ ! -f "$output_file" ]; then
  echo "::error::roundtrip_floor.sh: leg output file '$output_file' does not exist — nothing to measure."
  exit 2
fi

# ── 1. The floor must itself be trustworthy ─────────────────────────────────
# A typo'd or unset env var would otherwise make every comparison below error
# out with exit 2 inside an `if`, which bash treats as "false" and skips: the
# gate would disappear while the job stayed green.
case "$floor" in
  ''|*[!0-9]*)
    echo "::error::roundtrip_floor.sh: floor for the $label round-trip leg is '$floor', not a bare integer. Refusing to run an ungated measurement."
    exit 2;;
esac
if [ "$floor" -lt 1 ]; then
  echo "::error::roundtrip_floor.sh: floor for the $label round-trip leg is $floor. A round-trip leg that cannot round-trip a single fixture is not measuring anything — the floor must be >= 1 (issue #642)."
  exit 2
fi

case "$leg_exit" in
  ''|*[!0-9-]*) leg_exit="unknown";;
esac

# ── 2. Parse the FINAL `Results:` line only ─────────────────────────────────
# Never a global grep over all output: a leg's own progress chatter can contain
# a second match, which makes the capture MULTILINE. `tail -1` makes that
# unreachable; the integer guard asserts it rather than trusting it. (These
# legs' lines carry a trailing " (N skipped carve-outs)" suffix — the
# `(?= total)` lookahead is unaffected.)
#
# `sed -nE` rather than `grep -oP`: the whole count is extracted from ONE
# anchored pattern per field, so a stray `, 7 total` anywhere else on the line
# cannot be picked up, and it needs no PCRE (GNU grep's `-P` refuses to run
# under a non-UTF-8 locale, which silently turns every capture into the empty
# string — caught by this script's own self-test running on a Windows checkout).
summary=$(grep -E '^Results: [0-9]+ passed, [0-9]+ failed, [0-9]+ total' "$output_file" | tail -1 || true)
passed=$(printf '%s\n' "$summary" | sed -nE 's/^Results: ([0-9]+) passed, [0-9]+ failed, [0-9]+ total.*$/\1/p' | tail -1)
failed=$(printf '%s\n' "$summary" | sed -nE 's/^Results: [0-9]+ passed, ([0-9]+) failed, [0-9]+ total.*$/\1/p' | tail -1)
total=$(printf '%s\n' "$summary" | sed -nE 's/^Results: [0-9]+ passed, [0-9]+ failed, ([0-9]+) total.*$/\1/p' | tail -1)

for v in "$passed" "$failed" "$total"; do
  case "$v" in
    ''|*[!0-9]*)
      echo "::error::$label round-trip leg: could not parse a clean integer count from the Results line (got '$v'). Refusing to report a number this gate cannot trust. Leg exit code was $leg_exit."
      exit 1;;
  esac
done

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "passed=$passed"
    echo "failed=$failed"
    echo "total=$total"
    echo "floor=$floor"
  } >> "$GITHUB_OUTPUT"
fi

# ── 3. The first still-failing fixture, verbatim ────────────────────────────
# A count alone cannot be acted on, and these rows fail most of the corpus by
# construction. Echoing one real, unabridged failure line into the log AND the
# step summary is what keeps "it is a gap" an inspectable claim instead of an
# assertion — and, at `passed = 0`, what stops the row reading healthy while
# measuring nothing.
first_failure=$(grep -E "$fail_pattern" "$output_file" | head -1 || true)

echo ""
echo "=== $label Round-Trip Leg (floored + ratcheted) ==="
echo "Results: $passed passed, $failed failed, $total total (floor: $floor)"
echo "round-trip leg exit code: $leg_exit (non-zero is expected while any fixture still fails)"
if [ -n "$first_failure" ]; then
  echo "first still-failing fixture: $first_failure"
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### $label round-trip leg (floor $floor, ratcheted — issue #642)"
    echo ""
    echo "**$passed/$total** fixtures round-trip Ball -> $label -> Ball -> Dart engine."
    echo ""
    if [ -n "$first_failure" ]; then
      echo "First still-failing fixture:"
      echo ""
      echo '```'
      echo "$first_failure"
      echo '```'
      echo ""
    fi
    if [ -n "$note_file" ] && [ -f "$note_file" ]; then
      cat "$note_file"
      echo ""
    fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

# ── 4. Harness health ────────────────────────────────────────────────────────
if [ "$total" -lt 1 ]; then
  echo "::error::The $label round-trip leg reported no fixtures (total=$total) — it measured nothing. Leg exit code was $leg_exit."
  exit 1
fi

# ── 5. No fixture may HANG (#693) ────────────────────────────────────────────
# Checked before the floor so a hang is named as a hang even on a row that is
# otherwise at or above its ratchet.
# `|| timeout_lines=""` rather than `|| true`: grep exits 1 on NO MATCH, which is
# the healthy case here. Spelling the empty result explicitly keeps the branch
# below driven by the CONTENT, so no exit status is being discarded.
timeout_lines=$(grep -E "$timeout_pattern" "$output_file") || timeout_lines=""
if [ -n "$timeout_lines" ]; then
  first_timeout=$(printf '%s\n' "$timeout_lines" | head -1)
  timeout_count=$(printf '%s\n' "$timeout_lines" | wc -l | tr -d ' ')
  echo "::error::$label round-trip leg: $timeout_count fixture(s) did not TERMINATE and were killed by the leg's per-fixture budget. A re-encoded program that hangs is structurally valid and \`ball check\`-clean, so nothing upstream can see it — it is the issue #55 class, not one more golden mismatch, and it is never absorbed into the failure count (issue #693). First: $first_timeout"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### $label round-trip leg: $timeout_count fixture(s) HUNG (issue #693)"
      echo ""
      echo '```'
      echo "$first_timeout"
      echo '```'
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 1
fi

# ── 6. Positive floor (#642) ─────────────────────────────────────────────────
if [ "$passed" -lt 1 ]; then
  echo "::error::The $label round-trip leg round-tripped ZERO of $total fixtures. A measurement leg that cannot pass a single fixture is not measuring — fix the instrument or name the gap with its issue number, never leave the row green on a flat zero (issue #642)."
  exit 1
fi

# ── 7. Ratchet ───────────────────────────────────────────────────────────────
if [ "$passed" -lt "$floor" ]; then
  echo "::error::$label round-trip leg REGRESSED: $passed passed, below the floor of $floor — a fixture that used to round-trip no longer does."
  exit 1
fi

if [ "$passed" -gt "$floor" ]; then
  echo "::notice::$label round-trip leg IMPROVED: $passed passed (floor was $floor). Raise this row's floor to $passed in .github/workflows/conformance-matrix.yml to lock the gain in."
fi

exit 0
