#!/usr/bin/env bash
# Per-fixture isolated-process conformance tally for the compiled self-host
# engine. The in-process harness dies on the first stack-overflowing fixture,
# so we run each fixture in its own process via BALL_TEST_FILTER and tally.
exe="cpp/build3/test/Release/test_selfhost_conformance.exe"
pass=0; fail=0; timeout=0; crash=0
fails=()
for f in tests/conformance/*.ball.json; do
  name=$(basename "$f" .ball.json)
  out=$(BALL_TEST_FILTER="$name" "$exe" 2>/dev/null)
  if echo "$out" | grep -q "  PASS: $name "; then pass=$((pass+1));
  elif echo "$out" | grep -q "  TIMEOUT: $name "; then timeout=$((timeout+1)); fails+=("$name:TIMEOUT");
  elif echo "$out" | grep -q "  FAIL: $name "; then fail=$((fail+1)); fails+=("$name");
  else crash=$((crash+1)); fails+=("$name:CRASH"); fi
done
echo "PASS=$pass FAIL=$fail TIMEOUT=$timeout CRASH=$crash"
echo "--- non-pass ---"
printf '%s\n' "${fails[@]}"
