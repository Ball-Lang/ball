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
# compiler.cpp's number here depends heavily on whether build-cov-run.sh was
# invoked with BALL_COV_FULL=1 (running test_e2e's ~300-fixture conformance
# corpus through the real compile() pipeline): WITHOUT it, compiler.cpp reads
# ~39-40% (only test_compiler's ~100 hand-written unit cases exercise it);
# WITH it, ~67-68% (matching CI's real ctest run, which has no such filter).
# encoder.cpp and the shared bucket are NOT affected by BALL_COV_FULL — e2e
# only exercises the compiler's output, never the encoder, and ball_dyn.h/
# ball_emit_runtime.h get their coverage from test_ball_dyn/scope_probe
# (already in the default target set) regardless. See build-cov-floor.sh.
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

# `lcov --list` prints a per-file table whose "Rate" column is UNRELIABLE on
# this merged (baseline + post-test, multi-TU) tracefile: its "Num" column is
# actually reporting HIT lines (it sums exactly to the trustworthy overall
# hit total below), not the FOUND/total lines the column header implies, and
# "Rate" divides by a mismatched denominator — most likely corrupted by the
# many `geninfo: WARNING ('mismatch') mismatched end line` messages gcov
# emits for gtest-macro-generated functions (e.g. TEST()'s Register_* ctors
# in test_compiler.cpp) once multiple TUs' data for the same header get
# merged. Confirmed by cross-checking against Codecov's own (correct)
# per-file computation. TRUST the `lines......: NN.N% (a of b)` summary line
# `--summary` prints instead (below `--list`, kept only for the per-file
# breakdown of WHICH files have data — not for its Rate% column).
echo ""
echo "=== overall summary (compiler + encoder + shared, hand-written code) ==="
lcov --list "$MERGED" --ignore-errors empty
lcov --summary "$MERGED" --ignore-errors empty

for target in compiler encoder shared; do
  echo ""
  echo "=== $target ==="
  extracted="build-cov/cpp.$target.lcov"
  lcov --extract "$MERGED" "*/cpp/$target/*" \
    --output-file "$extracted" --ignore-errors unused,empty --quiet
  lcov --list "$extracted" --ignore-errors empty 2>/dev/null || \
    echo "(no instrumented lines found under cpp/$target)"
  lcov --summary "$extracted" --ignore-errors empty 2>/dev/null || true
done

if [ "${1:-}" = "--html" ]; then
  echo ""
  echo "=== generating HTML report ==="
  genhtml "$MERGED" --output-directory build-cov/coverage-html --quiet \
    --ignore-errors unused,empty,inconsistent,category
  echo "HTML report: build-cov/coverage-html/index.html"
fi

echo "REPORT_DONE"
