#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
cmake --build build-cov --target test_compiler test_shared test_encoder test_snapshot test_ball_ir -j"$(nproc)"
echo "BUILD_EXIT=$?"
