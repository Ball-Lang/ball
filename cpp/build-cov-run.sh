#!/usr/bin/env bash
# Runs the coverage-instrumented test binaries so gcov/lcov has .gcda data
# to capture. Follow with build-cov-report.sh to generate the coverage
# summary (issue #63).
#
# BALL_COV_FULL=1 also runs test_e2e (build with the same flag set — see
# build-cov-build.sh). Without it, this script measures a strict SUBSET of
# what CI's `ctest --test-dir cpp/build-cov` runs (CI has no such filter, so
# e2e_tests always contributes there) — a real, previously-undocumented gap:
# the wave3 baseline (compiler.cpp 39.0%) was measured this way and looked
# nothing like the true CI/Codecov number (67.58%) purely because e2e_tests
# was excluded, NOT because coverage regressed. Set BALL_COV_FULL=1 for a
# number that's actually comparable to CI.
# Usage: ./build-cov-run.sh
set -uo pipefail
cd "$(dirname "$0")"

echo "=== running test_compiler ==="
./build-cov/test/test_compiler
echo "test_compiler exit=$?"

echo "=== running test_shared ==="
./build-cov/test/test_shared
echo "test_shared exit=$?"

echo "=== running test_encoder ==="
./build-cov/test/test_encoder
echo "test_encoder exit=$?"

echo "=== running test_ball_ir ==="
./build-cov/test/test_ball_ir
echo "test_ball_ir exit=$?"

echo "=== running test_snapshot ==="
./build-cov/test/test_snapshot
echo "test_snapshot exit=$?"

echo "=== running test_ball_dyn ==="
./build-cov/test/test_ball_dyn
echo "test_ball_dyn exit=$?"

echo "=== running scope_probe ==="
./build-cov/test/scope_probe
echo "scope_probe exit=$?"

if [ "${BALL_COV_FULL:-0}" = "1" ]; then
  echo "=== running test_e2e (BALL_COV_FULL=1) ==="
  ./build-cov/test/test_e2e
  echo "test_e2e exit=$?"
fi

echo "RUN_DONE"
