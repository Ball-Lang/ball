#!/usr/bin/env bash
# Comprehensive C++ e2e: compile + build + run EVERY conformance program with
# an expected_output.txt, via direct g++ (fast, per-program timeout). Prints a
# category-tagged failure summary so we can see what's left.
set -u
ROOT="/mnt/d/packages/ball"
COMPILER="$ROOT/cpp/build-wsl/compiler/ball_cpp_compile"
CONF="$ROOT/tests/conformance"
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
  if ! timeout 60 g++ -std=c++20 -O1 "$TMP/p.cpp" -o "$TMP/p.bin" 2>"$TMP/gerr"; then
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
