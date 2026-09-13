#!/usr/bin/env bash
# Parse a coverage-study harness log, enforce the POSITIVE FLOOR, and write the
# job summary (issue #493).
#
#   tools/coverage-study/summarize.sh <language label> <log> [tier prefix]
#
# The tier prefix defaults to "Tier A", so every Tier A job (Dart plus the five
# ports) keeps calling this with two arguments. Tier B passes its own prefix
# ("Tier B", or "Tier B (whole-package)") because its harness prints that line
# instead; the floor and the summary shape are identical, which is why there is
# one summarizer rather than a second copy free to drift from this one.
#
# The floor is the one thing a report-only job still fails on: a run that
# scored zero files proves nothing about the pipeline — it means the checkout
# or the harness broke — and reporting it as "0% clean" would be a lie of the
# most expensive kind, since 0% is also a plausible real answer for a pipeline
# whose round trip is not yet closed. Everything else is reported and exits 0:
# no percentage floor is enforced until several scheduled runs have established
# a baseline (the project's own measure-before-gating rule).
set -euo pipefail

label="${1:?usage: summarize.sh <language label> <log> [tier prefix]}"
log="${2:?usage: summarize.sh <language label> <log> [tier prefix]}"
tier="${3:-Tier A}"

summary="$(grep -m1 "^$tier: " "$log" || true)"
results="$(grep -m1 '^Results: ' "$log" || true)"
if [ -z "$summary" ] || [ -z "$results" ]; then
  echo "::error::the $label $tier harness printed no summary line — treat this as a harness failure, not a 0% result"
  exit 1
fi

scored="$(printf '%s' "$results" | sed -E 's/^Results: [0-9]+ passed, [0-9]+ failed, ([0-9]+) total.*$/\1/')"
if ! printf '%s' "$scored" | grep -Eq '^[0-9]+$' || [ "$scored" -lt 1 ]; then
  echo "::error::$label $tier scored '$scored' files — no package checkout was readable"
  exit 1
fi

# TIER A ONLY: the test-only exclusion count must be present and must be a bare
# integer.
#
# Since the owner's 2026-09-14 methodology decision on issue #491, Tier A scores
# LIBRARY code — a package's own test suite is a different population and is out
# of the denominator, per language, by that language's convention. That makes
# every ratio the study publishes a function of an exclusion RULE, so the count
# is provenance, not decoration: a harness whose rule silently vanished (or
# silently widened) would move every number with nothing saying why. Three of
# the six harnesses used to filter exactly that way, printing nothing.
#
# A MISSING line is therefore a failure, not a zero — the same reasoning as the
# positive floor above, where an absent measurement must never read as a
# flattering result. The bare-integer check is deliberate too: a count that is
# not an integer cannot be compared, and comparing it anyway is how a shell gate
# silently disables itself.
#
# Scoped to Tier A because Tier B has no exclusion rule at all — it substitutes
# whole files into a package's OWN test suite and runs it — so demanding the
# line there would redden a job for a reason that does not apply to it.
# tools/coverage-study/test/summarize_self_test.sh pins every branch of this,
# by exit code, and ci.yml's python job gates it on every PR.
case "$tier" in
  "Tier A"*)
    excluded_line="$(grep -m1 '^  excluded (test-only): ' "$log" || true)"
    if [ -z "$excluded_line" ]; then
      echo "::error::the $label $tier harness printed no 'excluded (test-only): N' line — its test-only exclusion rule is missing, so the denominator cannot be explained (issue #491)"
      exit 1
    fi
    excluded="${excluded_line#  excluded (test-only): }"
    if ! printf '%s' "$excluded" | grep -Eq '^[0-9]+$'; then
      echo "::error::$label $tier reported an exclusion count of '$excluded', which is not a bare integer"
      exit 1
    fi
    ;;
esac

{
  echo "## Coverage study — $tier ($label)"
  echo
  echo '```'
  cat "$log"
  echo '```'
  echo
  echo "Report-only here: this job enforces the positive floor (a run that scored"
  echo "zero files is a harness/checkout failure, never a 0% result) and, for Tier A,"
  echo "the presence of the test-only exclusion count. The QUALITY floors are"
  echo "ratcheted by the \`publish\` job against tools/coverage-study/baseline.json"
  echo "(issue #493)."
} >>"$GITHUB_STEP_SUMMARY"
