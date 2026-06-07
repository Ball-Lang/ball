#!/usr/bin/env bash
# Comprehensive C++ e2e: compile + build + run EVERY conformance program with
# an expected_output.txt, via direct g++ (fast, per-program timeout). Prints a
# category-tagged failure summary.
#
# Usage: full_e2e.sh [--compiler PATH] [--root PATH]
#   --compiler  path to ball_cpp_compile binary (default: auto-detect)
#   --root      repo root (default: auto-detect from script location)
set -u

# Auto-detect repo root from script location (works in CI + local dev).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# Auto-detect compiler: prefer build/ (CI), then build-wsl/ (local WSL dev).
COMPILER=""
for d in "$ROOT/cpp/build/compiler" "$ROOT/cpp/build-wsl/compiler"; do
  for bin in "$d/ball_cpp_compile" "$d/Release/ball_cpp_compile" "$d/Debug/ball_cpp_compile"; do
    [[ -x "$bin" ]] && COMPILER="$bin" && break 2
  done
done

# CLI overrides
while [[ $# -gt 0 ]]; do
  case "$1" in
    --compiler) COMPILER="$2"; shift 2 ;;
    --root) ROOT="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

CONF="$ROOT/tests/conformance"
[[ -n "$COMPILER" ]] || { echo "ERROR: ball_cpp_compile not found. Build first."; exit 1; }
[[ -x "$COMPILER" ]] || { echo "ERROR: $COMPILER is not executable."; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0; skip=0
COMPILE_ERR=(); GPP_ERR=(); MISMATCH=(); TIMEOUT=()

for prog in "$CONF"/*.ball.json; do
  name="$(basename "$prog" .ball.json)"
  exp="$CONF/$name.expected_output.txt"
  [[ -f "$exp" ]] || { ((skip++)); continue; }

  if ! "$COMPILER" "$prog" > "$TMP/p.cpp" 2>"$TMP/cerr"; then
    COMPILE_ERR+=("$name"); ((fail++)); continue
  fi
  # -O0: faster builds, avoids false timeouts on large generator programs.
  if ! timeout 120 g++ -std=c++20 -O0 "$TMP/p.cpp" -o "$TMP/p.bin" 2>"$TMP/gerr"; then
    GPP_ERR+=("$name: $(grep -m1 'error:' "$TMP/gerr" | sed -E 's/.*error: //' | head -c 80)")
    ((fail++)); continue
  fi
  actual="$(timeout 15 "$TMP/p.bin" 2>/dev/null)"
  rc=$?
  if [[ $rc -eq 124 ]]; then TIMEOUT+=("$name"); ((fail++)); continue; fi
  a="$(printf '%s' "$actual" | sed -e 's/[[:space:]]*$//')"
  e="$(printf '%s' "$(cat "$exp")" | sed -e 's/[[:space:]]*$//')"
  if [[ "$a" == "$e" ]]; then ((pass++)); else MISMATCH+=("$name"); ((fail++)); fi
done

total=$((pass+fail))
echo "=================================================="
echo "C++ e2e: $pass/$total passed ($fail failed, $skip skipped no-output)"
echo "=================================================="
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

# Exit with failure if any program failed.
[[ $fail -eq 0 ]]
