#!/usr/bin/env bash
# Line-coverage floor check for cpp/{compiler,encoder,shared} hand-written
# code (issue #63). Run after build-cov-report.sh has produced the
# per-target build-cov/cpp.<target>.lcov files.
#
# Not wired into CI yet (.github/workflows/coverage.yml already runs the
# cpp coverage job and uploads to Codecov without a floor gate — adding one
# there is a natural follow-up, deliberately left to a separate change so it
# doesn't collide with sibling coverage work touching the same shared
# workflow file). This script is the standalone building block for that:
# run manually, or wire as a new `run:` step in the existing `cpp` job.
#
# Usage: ./build-cov-floor.sh
#   Exits 1 and prints every target under its floor; exits 0 otherwise.
#
# Floors reflect the measured baseline after issue #63's coverage sweep
# (2026-07-03): compiler 39.0%, encoder 86.1%, shared 79.4% line coverage.
# Set a few points below the measured value to absorb local/CI variance;
# RAISE as more tests land (mirrors the Dart ratchet's philosophy in
# tools/coverage_dart.dart, without needing a Dart toolchain here).
set -uo pipefail
cd "$(dirname "$0")"

declare -A FLOORS=(
  [compiler]=35
  [encoder]=80
  [shared]=70
)

fail=0
for target in "${!FLOORS[@]}"; do
  lcov_file="build-cov/cpp.$target.lcov"
  if [ ! -f "$lcov_file" ]; then
    echo "SKIP $target: $lcov_file not found (run build-cov-report.sh first)"
    continue
  fi
  # lcov --summary prints a "lines......: NN.N% (a of b lines)" line.
  pct=$(lcov --summary "$lcov_file" --ignore-errors empty 2>/dev/null \
    | grep -oP 'lines\.*:\s*\K[0-9]+(\.[0-9]+)?' | head -1)
  if [ -z "$pct" ]; then
    echo "SKIP $target: could not parse coverage percentage from $lcov_file"
    continue
  fi
  floor="${FLOORS[$target]}"
  # Integer compare via awk (bash has no floating point).
  if awk -v p="$pct" -v f="$floor" 'BEGIN { exit !(p < f) }'; then
    echo "FAIL $target: ${pct}% < floor ${floor}%"
    fail=1
  else
    echo "OK   $target: ${pct}% >= floor ${floor}%"
  fi
done

exit $fail
