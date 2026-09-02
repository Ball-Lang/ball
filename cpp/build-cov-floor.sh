#!/usr/bin/env bash
# Line-coverage floor check for cpp/{compiler,encoder,shared} hand-written
# code (issue #63). Run after build-cov-report.sh has produced the
# per-target build-cov/cpp.<target>.lcov files.
#
# GATED IN CI. .github/workflows/coverage.yml's cpp job splits the merged
# tracefile into build-cov/cpp.<target>.lcov and runs THIS SCRIPT; its exit
# code is that step's exit code (issues #63 / #59). The step also asserts each
# extracted tracefile is non-empty and that exactly three `OK ` lines come
# back, because the missing-tracefile branch below is a deliberate non-fatal
# SKIP — a gate that silently checked nothing would otherwise pass.
# cpp/test/test_cov_floor_ci_wiring.sh pins that wiring; the parser and exit
# codes are pinned by cpp/test/test_build_cov_floor_parsing.sh. Both run in
# ci.yml's always-on `proto` job.
#
# Usage: ./build-cov-floor.sh
#   Exits 1 and prints every target under its floor, or whose coverage summary
#   could not be parsed; exits 0 otherwise.
#   Parser/comparison behaviour is pinned by cpp/test/test_build_cov_floor_parsing.sh.
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
# Re-measured 2026-07-10 (issue #63, the protobuf-free-flip round — #18 Stage
# 5 landed and configure is now ~1 min, so the full pipeline is finally cheap):
#             lines            functions
#   compiler   43.1% -> 43.4%   85.0% w/ e2e   (default mode unchanged; the
#                                CI-comparable number is now measured — below)
#   encoder    89.1% -> 89.1%   97.2%           (untouched this round)
#   shared     80.9% -> 81.7%   97.4%           (composition changed, see below)
# Two corrections behind the shared number:
#   * The flip put two GENERATED files into the instrumented set —
#     ball_protobuf_rt.h ("Generated by ball compiler", ~3.7k lines at ~16%)
#     and ball_program_descriptor.h (gen_program_descriptor_cpp.dart output) —
#     briefly crashing the bucket to 42.4% and taking main's coverage.yml
#     C++ floor RED on the flip commit itself. Both are now excluded from the
#     lcov filter (build-cov-report.sh + coverage.yml + codecov.yml), same
#     class as engine_rt.cpp / gen/.
#   * The flip's HAND-WRITTEN seam, ball_rt_decode.cpp (the sole binary
#     .ball.pb decoder), measured 15.7% — its WKT/descriptor machinery was
#     reachable only from metadata-carrying binary files (never exercised).
#     Six golden-wire-vector tests in test_ball_file.cpp + removing the dead
#     DecodeAnyPayload (Stage-4 bridge, zero callers post-flip) lifted it to
#     98.4% lines / 100% functions.
# BALL_COV_FULL=1 (test_e2e, the CI-comparable mode) finally COMPLETED locally
# this round — the prior OOM was test_e2e's inner `cmake --build` having no -j
# (all-cores default); build-cov-run.sh now caps it via
# CMAKE_BUILD_PARALLEL_LEVEL (269/269 fixtures passed, no OOM at cap 2):
#   compiler w/ e2e: 70.4% lines (5084/7222) — the honest successor to the
#     67.58% Codecov figure the 2026-07-06 note above could only cite; overall
#     (compiler+encoder+shared) 75.1%. coverage.yml's CI floor is ratcheted
#     70 -> 72 against it. compiler's floor HERE stays calibrated to the
#     default (fast, no-e2e) mode.
#
# Set a few points below the measured value to absorb local/CI variance;
# RAISE as more tests land (mirrors the Dart ratchet's philosophy in
# tools/coverage_dart.dart, without needing a Dart toolchain here).
set -uo pipefail
cd "$(dirname "$0")"

# Re-measured 2026-07-10 (issue #63 close-out grind). corpus_driver
# (cpp/test/corpus_driver.cpp — a build-cov target that calls compile() on
# EXACTLY test_e2e's 266-fixture list, with NO nested g++ builds) is now part of
# the DEFAULT build-cov-build.sh/build-cov-run.sh target set, so the standalone
# per-target numbers below are ALREADY CI-equivalent (identical instrumented
# compiler.cpp coverage to test_e2e's compile phase, ~11s instead of ~40min).
# This close-out round added ~22 per-arm class/comprehension/library/dispatch
# unit tests driving hand-built ball::ir: emit_struct interfaces/mixins/virtual-
# bases + auto-assign/named-ctor-body/factory ctors + conversion operators +
# split-mode out-of-line class defs; list-literal field defaults + typed param
# defaults (cpp_list_literal_default / cpp_param_default); compile_message_creation
# runtime-type arms (transparent/only-meta wrappers, _FlowSignal/BallObject/
# JsonDecoder stubs, mixed arg+named, reified-non-dynamic); compile_method_call
# collection/string/super/static dispatch routes; compile_std_call map/list
# comprehensions + for-in-as-expression; compile_library class/enum/top-level-var
# facades; ClassName.new; lambda input/output types.
#             lines (default == CI-equivalent, corpus_driver in the run)
#   compiler   90.4% (6713/7424)   (up from 86.7%)
#   encoder    89.1% (944/1059)    (untouched this round)
#   shared     81.7% (2332/2853)   (untouched this round)
#   overall    88.1% (9989/11336)  (up from 85.7%)
# coverage.yml's CI floor is ratcheted 83 -> 86 against the 88.1% overall.
# Floors below are set a couple points under the measured per-target numbers to
# absorb CI variance.
#
# Re-derived 2026-09-02 (issues #63 / #59) when this script became the actual CI
# gate. Every earlier number in this header came from a LOCAL build-cov run; the
# floors below are the first ones derived from CI's own measurement, taken from
# two consecutive successful coverage.yml runs on main that printed an identical
# triple (so the reading is stable, not a single sample):
#   run 33614144984  main @ edf9f6c6  2026-09-02T09:39Z
#   run 33617428731  main @ 5b8c7b18  2026-09-02T10:16Z
#     cpp/compiler: 92.3%   cpp/encoder: 89.1%   cpp/shared: 81.8%
# minus this project's ~2pt CI-variance buffer, rounded down to whole points:
#   compiler  88 -> 90   (+2 ratchet: 92.3 - 2 = 90.3)
#   encoder   88 -> 87   (89.1 - 2 = 87.1; the old 88 left only +1.1pt, thinner
#                         than the convention, and was flagged on #63 as needing
#                         re-derivation BEFORE gating — an unenforced 88 that
#                         false-reds the moment it is switched on protects less
#                         than an enforced 87)
#   shared    81 -> 79   (81.8 - 2 = 79.8; same reasoning, old margin +0.8pt)
# RAISE these as tests land — that is the ratchet's whole point. They are a
# regression floor, never a completion target; #63's target is 100%.
declare -A FLOORS=(
  [compiler]=90
  [encoder]=87
  [shared]=79
)

fail=0
for target in "${!FLOORS[@]}"; do
  lcov_file="build-cov/cpp.$target.lcov"
  if [ ! -f "$lcov_file" ]; then
    # Deliberately a non-fatal SKIP, unlike the unparseable-summary branch
    # below: this is the operator-error case (the script was run before
    # build-cov-report.sh in a local checkout), not a corrupt measurement.
    # ANY CI wiring of this script MUST additionally assert all three
    # tracefiles exist, or a report step that silently produced none would
    # still pass this gate.
    echo "SKIP $target: $lcov_file not found (run build-cov-report.sh first)"
    continue
  fi
  # lcov --summary prints a "lines......: NN.N% (a of b lines)" line. This
  # (NOT `--list`'s per-file table) is the reliable aggregate — see the
  # comment above and in build-cov-report.sh.
  pct=$(lcov --summary "$lcov_file" --ignore-errors empty 2>/dev/null \
    | grep -oP 'lines\.*:\s*\K[0-9]+(\.[0-9]+)?' | head -1)
  if [ -z "$pct" ]; then
    # FAIL LOUD, never SKIP (issue #63). This branch used to print SKIP and
    # `continue` without setting fail=1, so an empty/corrupt per-target
    # extraction passed the gate silently with the floor never checked — the
    # opposite of coverage.yml's own inline floor step, which exits 1 on an
    # unparseable percentage. The tracefile EXISTS here (checked above); a
    # summary we cannot parse means the extraction is broken, not absent.
    # Pinned by cpp/test/test_build_cov_floor_parsing.sh.
    echo "FAIL $target: could not parse coverage percentage from $lcov_file"
    fail=1
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
