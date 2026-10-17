#!/usr/bin/env bash
# Set-difference gate for a round-trip conformance leg's PASSING FIXTURE SET
# (issue #836), complementing tools/ci/roundtrip_floor.sh's pass-COUNT floor.
#
# SHARED BY ALL FOUR ROUND-TRIP LEGS — rust-roundtrip, csharp-roundtrip,
# go-roundtrip and python-roundtrip (issue #896 generalized this script from
# a Rust-only gate to every leg). There is no per-language variant and none
# is needed: each leg's own harness (rust/engine/tests/roundtrip_conformance.rs,
# csharp/engine/conformance/PassingFixtures.cs, go/engine/conformance/support.go,
# python/engine/conformance/roundtrip.py) prints the identical
# `Passing fixtures (<N>, sorted):` block shape, so this one script and its
# `<label>`/baseline-file arguments are the whole generalization — see each
# language's own `.claude/rules/<lang>.md` for its printer's name.
#
# Why this exists: a pass-count floor cannot distinguish "nothing changed"
# from "one fixture newly passes and a different one newly regresses" — the
# count is identical either way (run 35575539330 measured the Rust leg at
# exactly its floor, 138 of 362), so a real regression can land invisibly as
# long as some unrelated fixture happens to start passing in the same PR. This
# script diffs the SET of currently-passing fixture names against a committed
# baseline and fails if any baseline-named fixture is missing from the current
# set — even when the total count held steady or rose.
#
# Contract:
#
#   roundtrip_passset.sh <label> <output-file> <baseline-file> [--write]
#
#   label         human name for the row, e.g. "Rust".
#   output-file   a file holding the leg's combined stdout+stderr. Must
#                 contain a `Passing fixtures (<N>, sorted):` block (one
#                 two-space-indented fixture name per line, up to the next
#                 blank line) and a final `Results: N passed, M failed, T
#                 total` line — the exact, byte-identical shape every one of
#                 the four round-trip legs prints:
#                 rust/engine/tests/roundtrip_conformance.rs's
#                 `format_passing_block`, csharp/engine/conformance/
#                 PassingFixtures.cs's `Format`, go/engine/conformance/
#                 support.go's `FormatPassingBlock`, and python/engine/
#                 conformance/roundtrip.py's `_format_passing_block`.
#   baseline-file a committed, sorted, deduplicated, one-name-per-line list of
#                 fixtures that must keep passing. Must exist and be well
#                 formed — never a silently-skipped gate on a missing or
#                 corrupt baseline.
#   --write       instead of gating, overwrite baseline-file with the CURRENT
#                 passing set (sorted, deduplicated) and exit 0. Use this to
#                 lock in a measured improvement, mirroring
#                 roundtrip_floor.sh's "raise the floor" convention — never
#                 hand-edit the baseline file.
#
# Gates, in order (mirrors roundtrip_floor.sh's structure and the project's
# "fail loud, never a silently disabled gate" rule):
#   1. usage + both input files exist;
#   2. the baseline file is itself well-formed: non-empty, sorted, no
#      duplicate lines — a hand-edited baseline that violates this is a hard
#      error, not a gate that silently compares against a wrong set;
#   3. the output file carries a parseable `Passing fixtures (<N>, sorted):`
#      block, and N matches both the block's own line count AND the `passed`
#      count on the `Results:` line — three independent counts of the same
#      thing. A mismatch anywhere means the printer or this parser drifted,
#      and the gate refuses to compare a set it cannot trust;
#   4. the set-difference itself: any baseline fixture missing from the
#      current passing set is a hard error naming every one of them.
#
# A newly-passing fixture not yet in the baseline is NOT a failure — it is an
# improvement, printed as a `::notice::` naming the fixtures and the `--write`
# invocation that locks them in. Never silently drop them from the notice: an
# improvement nobody records is a floor that only ever looks stale.
set -uo pipefail

label=${1:-}
output_file=${2:-}
baseline_file=${3:-}
write_mode=0
if [ "${4:-}" = "--write" ]; then
  write_mode=1
fi

if [ -z "$label" ] || [ -z "$output_file" ] || [ -z "$baseline_file" ]; then
  echo "::error::roundtrip_passset.sh: usage: roundtrip_passset.sh <label> <output-file> <baseline-file> [--write]"
  exit 2
fi

if [ ! -f "$output_file" ]; then
  echo "::error::roundtrip_passset.sh: leg output file '$output_file' does not exist — nothing to measure."
  exit 2
fi

# ── Extract the `Passing fixtures (<N>, sorted):` block ────────────────────
# Everything strictly between the header line and the next blank line,
# stripped of its two-space indent. Never a global grep: a leg's own progress
# chatter could contain a line shaped like a fixture name, so only the text
# inside the ONE delimited block counts.
header_count=$(grep -oE '^Passing fixtures \([0-9]+, sorted\):' "$output_file" | tail -1 | grep -oE '[0-9]+' || true)
case "$header_count" in
  ''|*[!0-9]*)
    echo "::error::roundtrip_passset.sh: the $label round-trip leg's output has no parseable 'Passing fixtures (<N>, sorted):' header — the harness must print it (issue #836). Got header count '$header_count'."
    exit 1;;
esac

# Terminates on the first blank line OR the `Results:` line, whichever comes
# first — the real printer always emits a blank line before `Results:`
# (belt), but the `Results:` anchor is a second, independent terminator
# (suspenders) so a caller that ever drops that blank line still parses
# correctly instead of silently swallowing the Results line as a 4th "name".
block=$(awk '
  /^Passing fixtures \(/ { found = 1; next }
  found && (/^[[:space:]]*$/ || /^Results:/) { exit }
  found { print }
' "$output_file")
current=$(printf '%s\n' "$block" | sed -E 's/^[[:space:]]+//' | sed '/^$/d' | sort)
current_count=$(printf '%s\n' "$current" | grep -c '^' || true)
if [ -z "$current" ]; then
  current_count=0
fi

if [ "$current_count" -ne "$header_count" ]; then
  echo "::error::roundtrip_passset.sh: the $label leg's 'Passing fixtures' header claims $header_count but the block lists $current_count names — the printer and this parser disagree, so the set cannot be trusted."
  exit 1
fi

# ── Cross-check against the leg's OWN `Results:` line ───────────────────────
# A third independent count of the same thing: the block could be well-formed
# and still be the WRONG set (e.g. printed before a later fixture mutated the
# counter) if nothing ties it back to `passed`.
results_line=$(grep -E '^Results: [0-9]+ passed, [0-9]+ failed, [0-9]+ total' "$output_file" | tail -1 || true)
results_passed=$(printf '%s\n' "$results_line" | sed -nE 's/^Results: ([0-9]+) passed,.*$/\1/p')
case "$results_passed" in
  ''|*[!0-9]*)
    echo "::error::roundtrip_passset.sh: the $label leg's output has no parseable 'Results: N passed, ...' line to cross-check the passing-set count against."
    exit 1;;
esac
if [ "$results_passed" -ne "$current_count" ]; then
  echo "::error::roundtrip_passset.sh: the $label leg's Results line reports $results_passed passed, but the 'Passing fixtures' block lists $current_count names — these must be the exact same count."
  exit 1
fi

# ── --write: lock the current set in as the new baseline ───────────────────
if [ "$write_mode" -eq 1 ]; then
  printf '%s\n' "$current" > "$baseline_file"
  echo "::notice::roundtrip_passset.sh: wrote $current_count fixture name(s) to $baseline_file as the new $label round-trip baseline."
  exit 0
fi

if [ ! -f "$baseline_file" ]; then
  echo "::error::roundtrip_passset.sh: baseline file '$baseline_file' does not exist. Create it once with 'roundtrip_passset.sh \"$label\" \"$output_file\" \"$baseline_file\" --write' from a known-good run, then commit it — never a silently-skipped gate on a missing baseline."
  exit 2
fi

# ── The baseline file must itself be trustworthy ─────────────────────────────
baseline_raw=$(cat "$baseline_file")
if [ -z "$baseline_raw" ]; then
  echo "::error::roundtrip_passset.sh: baseline file '$baseline_file' is empty — a round-trip leg that has never passed a single fixture has nothing to protect against regression, and an empty baseline is almost certainly a mistake rather than an honest zero."
  exit 2
fi
baseline_sorted=$(printf '%s\n' "$baseline_raw" | sort)
if [ "$baseline_raw" != "$baseline_sorted" ]; then
  echo "::error::roundtrip_passset.sh: baseline file '$baseline_file' is not sorted. It is a generated artifact (regenerate with --write); never hand-edit it."
  exit 2
fi
baseline_unique=$(printf '%s\n' "$baseline_raw" | sort -u)
if [ "$baseline_sorted" != "$baseline_unique" ]; then
  echo "::error::roundtrip_passset.sh: baseline file '$baseline_file' contains duplicate lines — it is a generated artifact (regenerate with --write); never hand-edit it."
  exit 2
fi

# ── The set-difference: any baseline fixture now missing is a REGRESSION ────
missing=$(comm -23 <(printf '%s\n' "$baseline_sorted") <(printf '%s\n' "$current"))
if [ -n "$missing" ]; then
  missing_count=$(printf '%s\n' "$missing" | grep -c '^')
  first_missing=$(printf '%s\n' "$missing" | head -1)
  echo "::error::$label round-trip leg REGRESSED: $missing_count fixture(s) that used to round-trip no longer do, even though the total pass count is $current_count (baseline: $(printf '%s\n' "$baseline_sorted" | grep -c '^')). A pass-count floor cannot see this — a different, unrelated fixture newly passing hides the regression from the count alone (issue #836). First regressed fixture: $first_missing"
  echo "Every regressed fixture:"
  printf '%s\n' "$missing" | sed 's/^/  /'
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### $label round-trip leg: $missing_count fixture(s) REGRESSED (issue #836)"
      echo ""
      echo "A pass-count floor held or rose while these previously-passing fixtures stopped round-tripping:"
      echo ""
      echo '```'
      printf '%s\n' "$missing"
      echo '```'
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 1
fi

# ── A newly-passing fixture is an improvement, named so it can be locked in ──
new_passes=$(comm -13 <(printf '%s\n' "$baseline_sorted") <(printf '%s\n' "$current"))
if [ -n "$new_passes" ]; then
  new_count=$(printf '%s\n' "$new_passes" | grep -c '^')
  echo "::notice::$label round-trip leg: $new_count fixture(s) newly round-trip and are not yet in the baseline. Run 'bash tools/ci/roundtrip_passset.sh \"$label\" \"$output_file\" \"$baseline_file\" --write' and commit $baseline_file to lock the gain in."
  printf '%s\n' "$new_passes" | sed 's/^/  + /'
fi

echo "$label round-trip leg: no previously-passing fixture regressed ($current_count passing, 0 missing from the baseline)."
exit 0
