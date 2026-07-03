#!/usr/bin/env bash
# Runs the coverage-instrumented test binaries and captures lcov data.
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

echo "RUN_DONE"
