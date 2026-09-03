#!/usr/bin/env bash
# Fast C++ e2e verification: compile representative programs per feature
# category directly with g++ (no cmake-per-program overhead).
#
# Usage: quick_e2e.sh [program_name ...]
#   With no args, runs a representative set across all 7 feature categories.
#
# Environment (issue #521), matching cpp/test/full_e2e.sh:
#   BALL_E2E_JOBS      how many programs to compile+run concurrently. Default:
#                      nproc / sysctl hw.ncpu. 1 restores the old serial run.
#   BALL_E2E_LAUNCHER  compiler launcher prefixed to g++ (e.g. `ccache`).
#
# Compilation is concurrent; the PASS/FAIL lines are still printed in the
# requested order, so output does not depend on scheduling.
set -u

# Auto-detect repo root from script location (works in CI + local dev).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# Worker mode — compile + run ONE program, recording the outcome in
# $W_RESULTS/<name>. Re-invoked by the parent through `xargs -P` (portable
# process-level parallelism; macOS's bash 3.2 has no `wait -n`). Always exits
# 0 so one failing program never aborts the pool.
if [[ "${1:-}" == "--worker" ]]; then
  name="$2"
  out="$W_RESULTS/$name"
  work="$W_WORK/$name"
  prog=""
  for d in "$W_CONF" "$W_GEN"; do
    if [[ -f "$d/$name.ball.json" ]]; then prog="$d/$name.ball.json"; break; fi
  done
  if [[ -z "$prog" ]]; then printf 'skip\tno .ball.json\n' > "$out"; exit 0; fi
  exp="$W_CONF/$name.expected_output.txt"
  if [[ ! -f "$exp" ]]; then printf 'skip\tno expected output\n' > "$out"; exit 0; fi
  if ! "$W_COMPILER" "$prog" > "$work.cpp" 2>"$work.compile_err"; then
    printf 'compile_err\t%s\n' "$(head -1 "$work.compile_err")" > "$out"; exit 0
  fi
  # ${W_LAUNCHER} is intentionally unquoted: empty expands to nothing.
  if ! ${W_LAUNCHER} g++ -std=c++20 -O0 "$work.cpp" -o "$work.bin" 2>"$work.gpp_err"; then
    printf 'gpp_err\t%s\n' "$(grep -m1 'error:' "$work.gpp_err" | head -c 200)" > "$out"; exit 0
  fi
  # Run in a private, empty directory — same reason as full_e2e.sh: the workers
  # execute fixture binaries CONCURRENTLY, so a shared CWD would become a
  # cross-fixture race the first time a fixture writes a relative path.
  rundir="$W_WORK/$name.rundir"
  mkdir -p "$rundir"
  actual="$(cd "$rundir" && "$work.bin" 2>/dev/null)"
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
[[ -n "$COMPILER" ]] || { echo "ERROR: ball_cpp_compile not found. Build first."; exit 1; }

CONF="$ROOT/tests/conformance"
GEN="$ROOT/tests/fixtures/dart/_generated"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/results" "$TMP/work"

JOBS="${BALL_E2E_JOBS:-}"
[[ -n "$JOBS" ]] || JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)"
case "$JOBS" in
  ''|*[!0-9]*|0) echo "ERROR: BALL_E2E_JOBS must be a positive integer (got '$JOBS')"; exit 1 ;;
esac
LAUNCHER="${BALL_E2E_LAUNCHER:-}"

# Representative programs per category (default set).
DEFAULT_PROGS=(
  # Collections
  76_list_map_filter 78_map_operations 92_list_comprehension 97_stack_operations
  # OOP
  101_simple_class 102_inheritance 104_getter_setter 105_static_methods 107_method_override_super
  # Patterns
  169_pattern_destructure 170_pattern_switch_expr 257_relational_pattern 258_logical_and_pattern
  # Async
  160_async_basic 161_async_chained
  # Generics
  167_generics_reified 180_generic_list_ops 181_generic_map_ops
  # Generators
  162_generator_sync 174_generator_yield_star 175_generator_empty_return
  # Misc / baseline
  01_hello 34_fibonacci 194_null_handling 203_closure_in_loop
)

if [[ $# -gt 0 ]]; then
  PROGS=("$@")
else
  PROGS=("${DEFAULT_PROGS[@]}")
fi

pass=0; fail=0; skip=0
FAILS=()

echo "C++ quick e2e: ${#PROGS[@]} program(s), $JOBS parallel job(s), launcher=${LAUNCHER:-(none)}"

printf '%s\n' "${PROGS[@]}" | \
  W_CONF="$CONF" W_GEN="$GEN" W_COMPILER="$COMPILER" W_RESULTS="$TMP/results" \
  W_WORK="$TMP/work" W_LAUNCHER="$LAUNCHER" \
  xargs -P "$JOBS" -I{} bash "$SCRIPT_DIR/quick_e2e.sh" --worker {}

# Aggregate in the requested order, so output does not depend on scheduling.
for name in "${PROGS[@]}"; do
  res="$TMP/results/$name"
  if [[ ! -f "$res" ]]; then
    echo "ERROR: no result recorded for '$name' — the parallel worker did not run it."
    exit 1
  fi
  IFS=$'\t' read -r status detail < "$res"
  case "$status" in
    pass)        echo "PASS  $name"; ((pass++)) ;;
    skip)        echo "SKIP  $name ($detail)"; ((skip++)) ;;
    compile_err) echo "FAIL  $name (ball->cpp compile error)"; FAILS+=("$name: ball->cpp: $detail"); ((fail++)) ;;
    gpp_err)     echo "FAIL  $name (g++ error)"; FAILS+=("$name: g++: $detail"); ((fail++)) ;;
    mismatch)    echo "FAIL  $name (output mismatch)"; FAILS+=("$name: output mismatch"); ((fail++)) ;;
    *)           echo "ERROR: '$name' recorded an unrecognised status '$status'."; exit 1 ;;
  esac
done

# Coverage-preserving assertion (issue #521): every requested program produced
# exactly one outcome — parallelism must not silently drop one.
if [[ $((pass + fail + skip)) -ne ${#PROGS[@]} ]]; then
  echo "ERROR: requested ${#PROGS[@]} program(s) but recorded $((pass + fail + skip)) outcome(s)."
  exit 1
fi

echo ""
echo "=============================="
echo "Results: $pass passed, $fail failed, $skip skipped"
if [[ $fail -gt 0 ]]; then
  echo ""
  echo "Failures:"
  for f in "${FAILS[@]}"; do echo "  - $f"; done
fi
