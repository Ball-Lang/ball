#!/usr/bin/env bash
# Builds the coverage-instrumented test binaries. Parallelism is capped
# (BALL_COV_JOBS, default 4) rather than using -j"$(nproc)" — each
# --coverage -O0 -g g++ job against compiler.cpp (11k+ lines) or protobuf's
# own sources easily takes 500MB-1GB+ RSS, and nproc (e.g. 20 on a shared
# WSL2 VM) multiplied by that plus concurrent sibling builds was observed to
# OOM-crash the whole WSL2 VM mid-build (issue #63).
set -uo pipefail
cd "$(dirname "$0")"
JOBS="${BALL_COV_JOBS:-4}"
cmake --build build-cov --target test_compiler test_shared test_encoder test_snapshot test_ball_ir -j"$JOBS"
echo "BUILD_EXIT=$?"
