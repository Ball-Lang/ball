#!/usr/bin/env bash
# Parse a Tier A harness log, enforce the POSITIVE FLOOR, and write the job
# summary (issue #493).
#
#   tools/coverage-study/summarize.sh <language label> <tier_a.log>
#
# The floor is the one thing a report-only job still fails on: a run that
# scored zero files proves nothing about the pipeline — it means the checkout
# or the harness broke — and reporting it as "0% clean" would be a lie of the
# most expensive kind, since 0% is also a plausible real answer for a pipeline
# whose round trip is not yet closed. Everything else is reported and exits 0:
# no percentage floor is enforced until several scheduled runs have established
# a baseline (the project's own measure-before-gating rule).
set -euo pipefail

label="${1:?usage: summarize.sh <language label> <tier_a.log>}"
log="${2:?usage: summarize.sh <language label> <tier_a.log>}"

summary="$(grep -m1 '^Tier A: ' "$log" || true)"
results="$(grep -m1 '^Results: ' "$log" || true)"
if [ -z "$summary" ] || [ -z "$results" ]; then
  echo "::error::the $label Tier A harness printed no summary line — treat this as a harness failure, not a 0% result"
  exit 1
fi

scored="$(printf '%s' "$results" | sed -E 's/^Results: [0-9]+ passed, [0-9]+ failed, ([0-9]+) total.*$/\1/')"
if ! printf '%s' "$scored" | grep -Eq '^[0-9]+$' || [ "$scored" -lt 1 ]; then
  echo "::error::$label Tier A scored '$scored' files — no package checkout was readable"
  exit 1
fi

{
  echo "## Coverage study — Tier A ($label)"
  echo
  echo '```'
  cat "$log"
  echo '```'
  echo
  echo "Report-only: no floor is enforced until a baseline exists (issue #493)."
} >>"$GITHUB_STEP_SUMMARY"
