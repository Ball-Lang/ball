#!/usr/bin/env bash
# Show the actual-vs-expected diff for a single failing e2e program.
set -u
ROOT="/mnt/d/packages/ball"
COMPILER="$ROOT/cpp/build-wsl/compiler/ball_cpp_compile"
CONF="$ROOT/tests/conformance"
GEN="$ROOT/tests/fixtures/dart/_generated"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
name="$1"
prog=""
for d in "$CONF" "$GEN"; do
  if [[ -f "$d/$name.ball.json" ]]; then prog="$d/$name.ball.json"; break; fi
done
[[ -z "$prog" ]] && { echo "no program: $name"; exit 1; }
exp="$CONF/$name.expected_output.txt"
"$COMPILER" "$prog" > "$TMP/p.cpp" 2>"$TMP/cerr" || { echo "BALL->CPP ERROR:"; cat "$TMP/cerr"; exit 2; }
if ! g++ -std=c++20 -O0 "$TMP/p.cpp" -o "$TMP/p.bin" 2>"$TMP/gerr"; then
  echo "G++ ERROR:"; grep -m5 'error:' "$TMP/gerr"
  echo "--- context (.cpp around first error line) ---"
  ln="$(grep -m1 'error:' "$TMP/gerr" | sed -E 's/.*\.cpp:([0-9]+):.*/\1/')"
  [[ -n "$ln" ]] && sed -n "$((ln-3)),$((ln+1))p" "$TMP/p.cpp"
  exit 3
fi
actual="$("$TMP/p.bin" 2>&1)"
echo "=== EXPECTED ==="; cat "$exp"
echo "=== ACTUAL ==="; printf '%s\n' "$actual"
echo "=== DIFF (expected vs actual) ==="
diff <(cat "$exp") <(printf '%s\n' "$actual") || true
