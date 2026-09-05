#!/usr/bin/env bash
# Comprehensive C++ e2e: compile + build + run EVERY conformance program with
# an expected_output.txt, via direct g++ (fast, per-program timeout). Prints a
# category-tagged failure summary.
#
# Usage: full_e2e.sh [--compiler PATH] [--root PATH] [--fixtures "STEMS"]
#   --compiler  path to ball_cpp_compile binary (default: auto-detect)
#   --root      repo root (default: auto-detect from script location)
#   --jobs      parallel fixture compiles (default: $BALL_E2E_JOBS, else nproc)
#   --fixtures  restrict the run to just these conformance fixture stems (bare
#               names, no dir, no .ball.json extension), space- or
#               comma-separated, e.g. --fixtures "400_switch_continue_label
#               401_foo". Mirrors ts/compiler/test/full_e2e.ts's --fixtures=
#               filter: used by ci.yml's per-PR gate to compile+run ONLY the
#               fixtures a PR added/changed (a few seconds) instead of the whole
#               ~350-fixture corpus — closing the escape class where the
#               main-only cpp-compiled matrix leg is the only thing that would
#               catch a PR-introduced regression (see #347). A requested stem
#               that doesn't exist under tests/conformance/ is a HARD ERROR
#               (fail loud, never a silent no-op). Omit to run the full corpus.
#
# Environment (issue #521):
#   BALL_E2E_JOBS      how many fixtures to compile+run concurrently. Default:
#                      nproc / sysctl hw.ncpu. 1 restores the old serial run.
#   BALL_E2E_LAUNCHER  compiler launcher prefixed to g++ (e.g. `ccache`), so an
#                      unchanged fixture is a cache hit instead of a fresh
#                      compile. Unset/empty = plain g++.
#
# Fixtures are compiled AND run concurrently, but results are collected into
# per-fixture files and aggregated in corpus order afterwards, so the counts,
# the category lists and the `Results:` line are byte-identical to the old
# serial run regardless of scheduling.
set -u

# Auto-detect repo root from script location (works in CI + local dev).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# ── Worker mode (issue #521) ────────────────────────────────────────────────
# `full_e2e.sh --worker <stem>` compiles + runs ONE fixture and records its
# outcome in $W_RESULTS/<stem>. The parent re-invokes this via xargs -P to get
# portable process-level parallelism (xargs -P works on GNU and BSD/macOS;
# `wait -n` does not exist in the bash 3.2 that ships with macOS). The worker
# always exits 0 — the outcome lives in the result file, so one failing fixture
# never aborts the pool.
if [[ "${1:-}" == "--worker" ]]; then
  name="$2"
  prog="$W_CONF/$name.ball.json"
  exp="$W_CONF/$name.expected_output.txt"
  out="$W_RESULTS/$name"
  work="$W_WORK/$name"
  if ! "$W_COMPILER" "$prog" > "$work.cpp" 2>"$work.cerr"; then
    printf 'compile_err\t\n' > "$out"; exit 0
  fi
  # -O0: faster builds, avoids false timeouts on large generator programs.
  # ${W_LAUNCHER} is intentionally unquoted: empty expands to nothing.
  if ! timeout 120 ${W_LAUNCHER} g++ -std=c++20 -O0 "$work.cpp" -o "$work.bin" 2>"$work.gerr"; then
    detail="$(grep -m1 'error:' "$work.gerr" | sed -E 's/.*error: //' | head -c 80)"
    printf 'gpp_err\t%s\n' "$detail" > "$out"; exit 0
  fi
  # 30s (was 15s): fixtures now run concurrently, so a compute-heavy one can
  # be descheduled behind its peers. Still far below any real hang.
  #
  # Each fixture RUNS in a private, empty directory. Unlike test_e2e — which
  # parallelises only the build and still runs the binaries one at a time — this
  # harness runs them concurrently, so a shared working directory would be a
  # cross-fixture race the moment any fixture writes a relative path. No fixture
  # in tests/conformance/ does today (none reference std_fs or std_concurrency),
  # but "no fixture does that yet" is a load-bearing invariant nothing enforced,
  # and the first std_fs fixture would have broken it silently. Isolating the
  # CWD removes the precondition instead of documenting it.
  rundir="$W_WORK/$name.rundir"
  mkdir -p "$rundir"
  actual="$(cd "$rundir" && timeout 30 "$work.bin" 2>/dev/null)"
  rc=$?
  if [[ $rc -eq 124 ]]; then printf 'timeout\t\n' > "$out"; exit 0; fi
  a="$(printf '%s' "$actual" | sed -e 's/[[:space:]]*$//')"
  e="$(printf '%s' "$(cat "$exp")" | sed -e 's/[[:space:]]*$//')"
  if [[ "$a" == "$e" ]]; then printf 'pass\t\n' > "$out"; else printf 'mismatch\t\n' > "$out"; fi
  exit 0
fi

# Auto-detect compiler: prefer build/ (CI), then build-wsl/ (local WSL dev).
COMPILER=""
for d in "$ROOT/cpp/build/compiler" "$ROOT/cpp/build-wsl/compiler"; do
  for bin in "$d/ball_cpp_compile" "$d/Release/ball_cpp_compile" "$d/Debug/ball_cpp_compile"; do
    [[ -x "$bin" ]] && COMPILER="$bin" && break 2
  done
done

# CLI overrides
FIXTURES_FILTER=""
FILTER_ACTIVE=0
JOBS="${BALL_E2E_JOBS:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --compiler) COMPILER="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --jobs=*) JOBS="${1#--jobs=}"; shift ;;
    --root) ROOT="$2"; shift 2 ;;
    --fixtures) FIXTURES_FILTER="$2"; FILTER_ACTIVE=1; shift 2 ;;
    --fixtures=*) FIXTURES_FILTER="${1#--fixtures=}"; FILTER_ACTIVE=1; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

CONF="$ROOT/tests/conformance"
[[ -n "$COMPILER" ]] || { echo "ERROR: ball_cpp_compile not found. Build first."; exit 1; }
[[ -x "$COMPILER" ]] || { echo "ERROR: $COMPILER is not executable."; exit 1; }

# Parallelism (issue #521). Fail loud on a non-numeric override rather than
# silently dropping back to a serial sweep — serial is the regression.
[[ -n "$JOBS" ]] || JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)"
case "$JOBS" in
  ''|*[!0-9]*|0) echo "::error::--jobs/BALL_E2E_JOBS must be a positive integer (got '$JOBS')"; exit 1 ;;
esac
LAUNCHER="${BALL_E2E_LAUNCHER:-}"
echo "C++ e2e: $JOBS parallel job(s), launcher=${LAUNCHER:-(none)}"

# Optional --fixtures filter: resolve the requested stems to a set, failing loud
# on any stem that has no tests/conformance/<stem>.ball.json (same hard-error
# semantics as ts/compiler/test/full_e2e.ts — never a silent no-op). Accepts
# space- and/or comma-separated stems.
declare -A WANT
if [[ $FILTER_ACTIVE -eq 1 ]]; then
  missing=()
  for stem in ${FIXTURES_FILTER//,/ }; do
    [[ -z "$stem" ]] && continue
    if [[ -f "$CONF/$stem.ball.json" ]]; then
      WANT["$stem"]=1
    else
      missing+=("$stem")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "::error::--fixtures requested fixture(s) not found in $CONF: ${missing[*]}"
    exit 1
  fi
  if [[ ${#WANT[@]} -eq 0 ]]; then
    echo "::error::--fixtures was given but resolved to zero fixtures (empty argument?)"
    exit 1
  fi
  echo "C++ e2e FILTERED — ${#WANT[@]} requested fixture(s): ${!WANT[*]}"
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/results" "$TMP/work"

pass=0; fail=0; skip=0; carved=0
COMPILE_ERR=(); GPP_ERR=(); MISMATCH=(); TIMEOUT=()

# Per-target carve-outs: fixtures the Ball->C++ COMPILER cannot yet handle.
# C++ is a roadmap target; each entry is a KNOWN, TRACKED gap. The reference
# Dart engine, the TS engine, AND the C++ self-host ENGINE all run these — only
# this compiled path skips them, and the skip is logged loudly below (never
# silent). Keep the list tiny + justified; delete an entry the moment the
# compiler supports it.
# (312_collection_for_capture was fixed by boxing the C-style collection_for's
# loop var, mirroring the statement-`for`'s existing shared_ptr cell +
# per-iteration shadow — issue #69. 400_switch_continue_label was fixed by
# lowering a labelled-case `switch` to a goto-based state machine — issue #352.)
#
# (416_user_method_name_arity_collision was fixed by giving each of
# compile_method_call's STL/Dart-SDK shortcuts the arity window of the real
# Dart method it stands for, so a same-named user method with a different
# argument count falls through to user-defined class method dispatch instead
# of being spliced into the shortcut's template — issue #511.)
#
# 438_ctor_initializer_list_with_body was carved out here for #514 (a class
# whose ONLY constructor takes no arguments got both that constructor and the
# synthesised default one, so g++ reported "'Flags::Flags()' cannot be
# overloaded with 'Flags::Flags()'"). That issue is fixed, so the fixture
# compiles, builds and runs on this leg and is listed in
# cpp/test/e2e_fixture_list.h. It still does NOT pass on the Rust/Go/Python/C#
# COMPILER legs - none of those compilers resolves a NAMED constructor
# (`Class.name(args)`), which the Dart encoder emits as a method call on the
# class reference rather than as a messageCreation. That pre-existing gap is
# #527, and those four legs are RATCHETED (they fail only on a drop below a
# recorded floor), not parity gates, so a green ratchet says nothing about any
# one fixture - measure it. See docs/TESTING_STRATEGY.md's "Name the leg that
# actually covers it".
#
# 435_recursive_ctor_construction / 436_recursive_ctor_named /
# 437_recursive_ctor_tree were carved out here for #513 and are NOT any more:
# that issue is fixed, so all three compile, build and run on this leg and are
# listed in cpp/test/e2e_fixture_list.h.
#
# 453_ctor_param_shadows_field / 454_inline_instance_argument_name_collision
# were carved out here for #561 and are NOT any more: that issue is fixed (the
# Ball->C++ compiler no longer auto-assigns a plain constructor parameter into a
# field positionally, and no longer drops a class's inline field initializers
# for a body-carrying or named constructor), so both compile, build and run on
# this leg and are listed in cpp/test/e2e_fixture_list.h — alongside
# 455_ctor_field_writes_that_survive, the positive half of the same test design,
# which passed this leg all along.
CPP_COMPILE_CARVEOUTS=()
_is_carved() { local n="$1" c; (( ${#CPP_COMPILE_CARVEOUTS[@]} == 0 )) && return 1;
  for c in "${CPP_COMPILE_CARVEOUTS[@]}"; do [[ "$c" == "$n" ]] && return 0; done; return 1; }

# Pass 1 — select. Skip/carve-out bookkeeping stays here (sequential, cheap)
# so the counts do not depend on scheduling; RUN holds the corpus-ordered list
# of fixtures the workers will actually compile.
RUN=()
for prog in "$CONF"/*.ball.json; do
  name="$(basename "$prog" .ball.json)"
  # When a --fixtures filter is active, run only the requested stems.
  if [[ $FILTER_ACTIVE -eq 1 && -z "${WANT[$name]:-}" ]]; then continue; fi
  exp="$CONF/$name.expected_output.txt"
  [[ -f "$exp" ]] || { ((skip++)); continue; }
  if _is_carved "$name"; then ((carved++)); continue; fi
  RUN+=("$name")
done

# Pass 2 — compile + run, $JOBS at a time. Workers only write result files;
# xargs' own exit status is deliberately ignored (workers always exit 0, and a
# missing result file is caught as a hard error in pass 3).
if [[ ${#RUN[@]} -gt 0 ]]; then
  printf '%s\n' "${RUN[@]}" | \
    W_CONF="$CONF" W_COMPILER="$COMPILER" W_RESULTS="$TMP/results" \
    W_WORK="$TMP/work" W_LAUNCHER="$LAUNCHER" \
    xargs -P "$JOBS" -I{} bash "$SCRIPT_DIR/full_e2e.sh" --worker {}
fi

# Pass 3 — aggregate in corpus order, so output is identical to a serial run.
for name in "${RUN[@]:-}"; do
  [[ -n "$name" ]] || continue
  res="$TMP/results/$name"
  if [[ ! -f "$res" ]]; then
    echo "::error::no result recorded for fixture '$name' — the parallel worker did not run it."
    exit 1
  fi
  IFS=$'\t' read -r status detail < "$res"
  case "$status" in
    pass)        ((pass++)) ;;
    compile_err) COMPILE_ERR+=("$name"); ((fail++)) ;;
    gpp_err)     GPP_ERR+=("$name: $detail"); ((fail++)) ;;
    timeout)     TIMEOUT+=("$name"); ((fail++)) ;;
    mismatch)    MISMATCH+=("$name"); ((fail++)) ;;
    *)
      echo "::error::fixture '$name' recorded an unrecognised status '$status'."
      exit 1 ;;
  esac
done

# Coverage-preserving assertion (issue #521): parallelism must not drop a
# fixture. Every selected fixture must have produced exactly one outcome.
if [[ $((pass + fail)) -ne ${#RUN[@]} ]]; then
  echo "::error::selected ${#RUN[@]} fixture(s) but recorded $((pass + fail)) outcome(s) — fixtures were dropped."
  exit 1
fi

total=$((pass+fail))
echo "=================================================="
echo "C++ e2e: $pass/$total passed ($fail failed, $skip skipped no-output, $carved compiler carve-outs)"
echo "=================================================="
echo ""
echo "C++ compiler carve-outs (${#CPP_COMPILE_CARVEOUTS[@]}, tracked gaps — run on Dart/TS/C++ engines): ${CPP_COMPILE_CARVEOUTS[*]:-none}"
echo ""
echo "Ball->C++ compile errors (${#COMPILE_ERR[@]}): ${COMPILE_ERR[*]:-none}"
echo ""
echo "g++ build errors (${#GPP_ERR[@]}):"
for x in "${GPP_ERR[@]:-}"; do [[ -n "$x" ]] && echo "  - $x"; done
echo ""
echo "Runtime timeouts (${#TIMEOUT[@]}): ${TIMEOUT[*]:-none}"
echo ""
echo "Output mismatches (${#MISMATCH[@]}): ${MISMATCH[*]:-none}"
echo ""
# Standard format line for CI conformance-matrix parsing.
echo "Results: $pass passed, $fail failed, $total total"

# Positive floor. "0 failed" and "0 ran" are indistinguishable to the caller,
# and ci.yml invokes this script directly (its own `passed < 1` guard lives in
# conformance-matrix.yml, not here). A `--fixtures` filter whose every entry is
# carved out or golden-less would otherwise exit 0 having compiled nothing —
# a required check that proves nothing. Widen the filter, or remove the
# carve-out, rather than accepting the fake green.
if [[ $pass -lt 1 && $fail -eq 0 ]]; then
  echo "::error::C++ compiled e2e ran NO fixture (passed=0, failed=0, carve-outs=$carved, no-output skips=$skip) — this leg proved nothing."
  exit 1
fi

# Exit with failure if any program failed.
[[ $fail -eq 0 ]]
