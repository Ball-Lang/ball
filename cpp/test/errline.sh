#!/usr/bin/env bash
# Show the first g++ error + the offending source line for each named program.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
COMPILER=""
for d in "$ROOT/cpp/build/compiler" "$ROOT/cpp/build-wsl/compiler"; do
  for bin in "$d/ball_cpp_compile" "$d/Release/ball_cpp_compile" "$d/Debug/ball_cpp_compile"; do
    [[ -x "$bin" ]] && COMPILER="$bin" && break 2
  done
done
[[ -n "$COMPILER" ]] || { echo "ERROR: ball_cpp_compile not found."; exit 1; }
CONF="$ROOT/tests/conformance"
for n in "$@"; do
  echo "===== $n ====="
  "$COMPILER" "$CONF/$n.ball.json" > /tmp/x.cpp 2>/dev/null
  err=$(g++ -std=c++20 /tmp/x.cpp -o /tmp/x 2>&1 | grep -m1 'error:')
  echo "$err"
  ln=$(echo "$err" | sed -E 's/.*x\.cpp:([0-9]+):.*/\1/')
  if [[ "$ln" =~ ^[0-9]+$ ]]; then
    sed -n "${ln}p" /tmp/x.cpp | head -c 300
    echo ""
  fi
done
