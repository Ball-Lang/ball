#!/usr/bin/env bash
# Builds the coverage-instrumented test binaries. Parallelism is capped
# (BALL_COV_JOBS, default 4) rather than using -j"$(nproc)" — each
# --coverage -O0 -g g++ job against compiler.cpp (11k+ lines) or protobuf's
# own sources easily takes 500MB-1GB+ RSS, and nproc (e.g. 20 on a shared
# WSL2 VM) multiplied by that plus concurrent sibling builds was observed to
# OOM-crash the whole WSL2 VM mid-build (issue #63).
#
# BALL_COV_FULL=1 additionally builds test_e2e — the ~300-fixture conformance
# corpus through the real compile() pipeline, which is what exercises most of
# compiler.cpp's dispatch tables. Default OFF: it shells out to a nested
# cmake+g++ build per fixture and is far slower than the other binaries.
# Omitting it is exactly why the wave3 baseline (compiler 39.0%) understated
# the REAL CI number (compiler 67.58%, confirmed via Codecov) by 28 points —
# see build-cov-floor.sh. Set BALL_COV_FULL=1 for a number comparable to CI.
set -uo pipefail
cd "$(dirname "$0")"
JOBS="${BALL_COV_JOBS:-4}"
TARGETS=(test_compiler test_shared test_ball_file test_encoder test_snapshot
         test_ball_ir test_ball_dyn scope_probe test_cli)
if [ "${BALL_COV_FULL:-0}" = "1" ]; then
  TARGETS+=(test_e2e)
fi
cmake --build build-cov --target "${TARGETS[@]}" -j"$JOBS"
echo "BUILD_EXIT=$?"
