#!/usr/bin/env bash
# Fast C++ e2e verification: compile representative programs per feature
# category directly with g++ (no cmake-per-program overhead).
#
# Usage: quick_e2e.sh [program_name ...]
#   With no args, runs a representative set across all 7 feature categories.
set -u

ROOT="/mnt/d/packages/ball"
COMPILER="$ROOT/cpp/build-wsl/compiler/ball_cpp_compile"
CONF="$ROOT/tests/conformance"
GEN="$ROOT/tests/fixtures/dart/_generated"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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

for name in "${PROGS[@]}"; do
  # Resolve program + expected output.
  prog=""
  for d in "$CONF" "$GEN"; do
    if [[ -f "$d/$name.ball.json" ]]; then prog="$d/$name.ball.json"; break; fi
  done
  if [[ -z "$prog" ]]; then echo "SKIP  $name (no .ball.json)"; ((skip++)); continue; fi
  exp="$CONF/$name.expected_output.txt"
  if [[ ! -f "$exp" ]]; then echo "SKIP  $name (no expected output)"; ((skip++)); continue; fi

  # Compile Ball -> C++.
  if ! "$COMPILER" "$prog" > "$TMP/$name.cpp" 2>"$TMP/$name.compile_err"; then
    echo "FAIL  $name (ball->cpp compile error)"
    FAILS+=("$name: ball->cpp: $(head -1 "$TMP/$name.compile_err")")
    ((fail++)); continue
  fi

  # Compile C++ -> binary.
  if ! g++ -std=c++20 -O0 "$TMP/$name.cpp" -o "$TMP/$name.bin" 2>"$TMP/$name.gpp_err"; then
    echo "FAIL  $name (g++ error)"
    FAILS+=("$name: g++: $(grep -m1 'error:' "$TMP/$name.gpp_err" | head -c 200)")
    ((fail++)); continue
  fi

  # Run + compare.
  actual="$("$TMP/$name.bin" 2>/dev/null)"
  expected="$(cat "$exp")"
  # Normalize trailing whitespace/newlines.
  actual="$(printf '%s' "$actual" | sed -e 's/[[:space:]]*$//')"
  expected="$(printf '%s' "$expected" | sed -e 's/[[:space:]]*$//')"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS  $name"
    ((pass++))
  else
    echo "FAIL  $name (output mismatch)"
    FAILS+=("$name: output mismatch")
    ((fail++))
  fi
done

echo ""
echo "=============================="
echo "Results: $pass passed, $fail failed, $skip skipped"
if [[ $fail -gt 0 ]]; then
  echo ""
  echo "Failures:"
  for f in "${FAILS[@]}"; do echo "  - $f"; done
fi
