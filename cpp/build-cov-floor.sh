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
# IMPORTANT — the wave3 baseline recorded here (2026-07-03: compiler 39.0%,
# encoder 86.1%, shared 79.4%) was measured WITHOUT test_e2e (build-cov-run.sh
# never ran it) and was ALSO read off `lcov --list`'s per-file table, whose
# Rate% column is unreliable (see build-cov-report.sh's comment — the Num
# column there is actually hit-lines, not found-lines). Neither issue was
# known when that baseline was written. Re-measured 2026-07-06 (issue #63
# phase 2, via `lcov --summary` on the correctly-extracted per-target
# tracefiles) after adding cpp/test/test_ball_dyn.cpp (direct BallDyn/
# BallOrderedMap/ball_emit_runtime.h unit coverage) and registering
# scope_probe as a ctest target:
#             lines            functions
#   compiler   39.0% -> 39.9%   —        (unaffected: not this task's target;
#                                          CI's real number is 67.58%, confirmed
#                                          via Codecov — see below)
#   encoder    86.1% -> 86.1%   98.3%     (unaffected: not this task's target)
#   shared     79.4% -> 73.4%   95.3%     (now correctly includes ball_dyn.h +
#                                          ball_emit_runtime.h, which grew the
#                                          bucket's denominator far more than
#                                          its own new coverage raised the
#                                          numerator — see per-file numbers)
#   ball_dyn.h            0% -> 71.9% (682/949 lines), 99.4% (155/156 fns)
#   ball_emit_runtime.h   0% -> 59.8% (189/316 lines), 87.2% (34/39 fns)
# (ball_dyn.h/ball_emit_runtime.h aren't broken out as their own FLOORS entry
# below — lcov's `--extract '*/cpp/shared/*'` pattern can't cheaply separate
# them from the rest of cpp/shared/include/ — but are the ones worth watching
# if the "shared" floor ever needs raising again.)
#
# compiler's floor here is deliberately calibrated to the DEFAULT (fast, no
# test_e2e) build-cov-run.sh — a real conformance-corpus-driven number needs
# BALL_COV_FULL=1 (see build-cov-build.sh/build-cov-run.sh), which is far
# slower (a nested cmake+g++ build per fixture) and not run by default. CI's
# actual `ctest` invocation has no such filter, so Codecov's flag `cpp`
# reports compiler.cpp at 67.58% — this floor is NOT comparable to that
# number and must not be raised toward it without BALL_COV_FULL=1 becoming
# the default measurement mode.
#
# Set a few points below the measured value to absorb local/CI variance;
# RAISE as more tests land (mirrors the Dart ratchet's philosophy in
# tools/coverage_dart.dart, without needing a Dart toolchain here).
set -uo pipefail
cd "$(dirname "$0")"

declare -A FLOORS=(
  [compiler]=35
  [encoder]=83
  [shared]=70
)

fail=0
for target in "${!FLOORS[@]}"; do
  lcov_file="build-cov/cpp.$target.lcov"
  if [ ! -f "$lcov_file" ]; then
    echo "SKIP $target: $lcov_file not found (run build-cov-report.sh first)"
    continue
  fi
  # lcov --summary prints a "lines......: NN.N% (a of b lines)" line. This
  # (NOT `--list`'s per-file table) is the reliable aggregate — see the
  # comment above and in build-cov-report.sh.
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
