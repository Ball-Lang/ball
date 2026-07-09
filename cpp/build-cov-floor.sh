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
#   shared     79.4% -> 73.7%   95.4%     (now correctly includes ball_dyn.h +
#                                          ball_emit_runtime.h, which grew the
#                                          bucket's denominator far more than
#                                          its own new coverage raised the
#                                          numerator — see per-file numbers)
#   ball_dyn.h            0% -> 72.5% (691/953 lines), 99.4% (155/156 fns)
#   ball_emit_runtime.h   0% -> 59.8% (189/316 lines), 87.2% (34/39 fns)
# (ball_dyn.h's numbers are AFTER also fixing issue #233 — BallMap/BallUMap's
# operator[](const std::string&) auto-vivifying a missing key via
# std::map::operator[] instead of find(), caught by test_ball_dyn.cpp and
# fixed in the same PR; verified with a full C++ e2e conformance re-run,
# 264/264 passed, no regression, since ball_dyn.h is embedded into every
# emitted program via ball_dyn_embed.h.)
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
# Re-measured 2026-07-09 (issue #63, cov-cpp lane) via `lcov --summary` on
# freshly-extracted per-target tracefiles, again WITHOUT test_e2e — this
# round's WSL box OOM'd and briefly took the whole VM's `wsl.exe` bridge down
# when BALL_COV_FULL=1 was attempted (test_e2e's nested per-fixture cmake+g++
# builds are memory-hungry; see build-cov-build.sh's own BALL_COV_JOBS
# comment), so no fresh CI-comparable compiler.cpp number was obtained this
# round either — don't read anything into compiler's delta below beyond "more
# of the default (non-e2e) surface is now exercised."
#             lines            functions
#   compiler   39.9% -> 43.1%   — (65.0%, 104/160)  (the jump is almost
#                                  entirely from wiring test_ball_ir_descriptor
#                                  into build-cov-build.sh/run.sh's target
#                                  lists — it existed as a real ctest target
#                                  since #18 P4 but neither script had ever
#                                  built or run it, so its coverage of
#                                  ball_ir.h's descriptor-JSON builder sat
#                                  invisible to every local measurement)
#   encoder    86.1% -> 89.1%   97.2% (70/72)        (drift from unrelated work;
#                                                      not this lane's target)
#   shared     80.3% -> 80.9%   97.2% (311/320)
#   ball_emit_runtime.h  59.8% -> 64.8% (400 lines), 89.3% (56 fns)  — direct
#     unit coverage added for the File/Directory std_fs filesystem-runtime
#     backing (writeAsStringSync x3 overloads/writeAsBytesSync/
#     readAsBytesSync/existsSync/deleteSync/listSync/createSync/
#     _ball_file_mode_is_append): real (non-stub) implementations landed by
#     #310/#318 with ZERO coverage in any instrumented build (local or CI) —
#     their only prior exercise was test_selfhost_conformance.cpp, which
#     needs the gitignored, CI-only-generated engine_rt.cpp and is skipped
#     entirely whenever that isn't present (see test_ball_dyn.cpp's own
#     "File / Directory runtime" section header comment for the full
#     writeup). ball_dyn.h unchanged (72.5% -> 72.7%, noise) — its own File/
#     Directory glue (BallDyn-overload ctors/writeAsStringSync) is thin
#     enough that the new tests barely move its needle.
#
# Set a few points below the measured value to absorb local/CI variance;
# RAISE as more tests land (mirrors the Dart ratchet's philosophy in
# tools/coverage_dart.dart, without needing a Dart toolchain here).
set -uo pipefail
cd "$(dirname "$0")"

declare -A FLOORS=(
  [compiler]=40
  [encoder]=86
  [shared]=77
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
