#!/usr/bin/env bash
# Show the first g++ error + the offending source line for each named program.
COMPILER=/mnt/d/packages/ball/cpp/build-wsl/compiler/ball_cpp_compile
CONF=/mnt/d/packages/ball/tests/conformance
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
