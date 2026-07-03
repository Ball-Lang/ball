#!/usr/bin/env bash
# Captures lcov coverage data from the coverage-instrumented build-cov tree
# and prints a per-target (compiler/encoder/shared) summary (issue #63).
#
# Mirrors the methodology of .github/workflows/coverage.yml's `cpp` job
# (baseline --initial capture + merge with the post-test capture, so files
# that are compiled but never exercised show 0% instead of vanishing from
# the report) so these numbers are directly comparable to what CI/Codecov
# will report. Additionally excludes dart/self_host/lib/engine_rt.cpp
# (never built by build-cov-build.sh's target list, but excluded
# explicitly in case that changes).
#
# Usage:
#   ./build-cov-configure.sh && ./build-cov-build.sh && ./build-cov-run.sh
#   ./build-cov-report.sh [--html]
#     --html   also emit an HTML report under build-cov/coverage-html/
set -uo pipefail
cd "$(dirname "$0")"

BASE="build-cov/cpp.base.lcov"
TEST="build-cov/cpp.test.lcov"
MERGED="build-cov/cpp.lcov"
IGNORE="mismatch,gcov,source,negative,empty,unused,format,inconsistent"

echo "=== baseline coverage (lcov --initial; every instrumented file at 0%) ==="
lcov --capture --initial --directory build-cov --output-file "$BASE" \
  --ignore-errors "$IGNORE" --quiet

echo "=== post-test coverage ==="
lcov --capture --directory build-cov --output-file "$TEST" \
  --ignore-errors "$IGNORE" --quiet

echo "=== merging baseline + test, excluding vendored/generated/self-host code ==="
lcov --add-tracefile "$BASE" --add-tracefile "$TEST" \
  --output-file "$MERGED" --ignore-errors unused,empty,corrupt,inconsistent --quiet
lcov --remove "$MERGED" \
  '/usr/*' '*/_deps/*' '*/build-cov/*' '*/gen/*' '*/test/*' \
  '*/dart/self_host/lib/engine_rt.cpp' \
  --output-file "$MERGED" --ignore-errors unused,empty,inconsistent --quiet

echo ""
echo "=== overall summary (compiler + encoder + shared, hand-written code) ==="
lcov --list "$MERGED" --ignore-errors empty

for target in compiler encoder shared; do
  echo ""
  echo "=== $target ==="
  extracted="build-cov/cpp.$target.lcov"
  lcov --extract "$MERGED" "*/cpp/$target/*" \
    --output-file "$extracted" --ignore-errors unused,empty --quiet
  lcov --list "$extracted" --ignore-errors empty 2>/dev/null || \
    echo "(no instrumented lines found under cpp/$target)"
done

if [ "${1:-}" = "--html" ]; then
  echo ""
  echo "=== generating HTML report ==="
  genhtml "$MERGED" --output-directory build-cov/coverage-html --quiet \
    --ignore-errors unused,empty,inconsistent,category
  echo "HTML report: build-cov/coverage-html/index.html"
fi

echo "REPORT_DONE"
