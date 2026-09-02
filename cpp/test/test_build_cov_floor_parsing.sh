#!/usr/bin/env bash
# Unit test for cpp/build-cov-floor.sh's lcov-summary percentage parser and its
# awk floor comparison (issues #63 / #59).
#
# WHY THIS EXISTS: build-cov-floor.sh owns the finer per-target C++ coverage
# floors (compiler/encoder/shared) that the single blended aggregate in
# coverage.yml cannot see — a large regression confined to one target is
# arithmetically absorbable by the other two. Before this test, its
# unparseable-summary branch was FAIL-OPEN: it printed `SKIP` and `continue`d
# without setting `fail=1`, so a broken per-target extraction passed silently —
# the exact opposite of coverage.yml's own inline floor step, which correctly
# `exit 1`s on an unparseable percentage. Nothing fed the script a bad summary,
# so nothing noticed.
#
# No C++ toolchain, no real lcov, no coverage build: a stub `lcov` on PATH
# replays synthetic `lcov --summary` output against a scratch copy of the
# script. Sub-second; wired into ci.yml's always-run `proto` job.
#
# Usage: bash cpp/test/test_build_cov_floor_parsing.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../build-cov-floor.sh"
[ -f "$SCRIPT" ] || {
  echo "::error::missing $SCRIPT"
  exit 1
}

pass=0
fail=0

# Real floors, mirrored from build-cov-floor.sh's FLOORS map, so the cases below
# read as "above"/"below" without duplicating the numbers' meaning.
#   compiler 88, encoder 88, shared 81

# summary_line <pct> — one line in the exact shape `lcov --summary` prints.
summary_line() { printf '  lines......: %s%% (1000 of 1100 lines)\n' "$1"; }

# run_case <name> <expected exit> <compiler summary> <encoder summary> <shared summary>
# Each summary argument is the literal stdout the stub `lcov` returns for that
# target ('' means lcov printed nothing at all).
run_case() {
  local name="$1" want="$2" c="$3" e="$4" s="$5"
  local tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/build-cov" "$tmp/bin"
  cp "$SCRIPT" "$tmp/build-cov-floor.sh"

  # The tracefiles only have to EXIST — the stub lcov reads the sibling
  # .summary file, never the tracefile itself.
  local t
  for t in compiler encoder shared; do : >"$tmp/build-cov/cpp.$t.lcov"; done
  printf '%s' "$c" >"$tmp/build-cov/cpp.compiler.lcov.summary"
  printf '%s' "$e" >"$tmp/build-cov/cpp.encoder.lcov.summary"
  printf '%s' "$s" >"$tmp/build-cov/cpp.shared.lcov.summary"

  # Stub lcov: `lcov --summary <tracefile> --ignore-errors empty` -> replay the
  # synthetic summary for that tracefile. Exits 0, exactly like real lcov does.
  cat >"$tmp/bin/lcov" <<'STUB'
#!/usr/bin/env bash
f=""
prev=""
for a in "$@"; do
  [ "$prev" = "--summary" ] && f="$a"
  prev="$a"
done
[ -n "$f" ] && [ -f "$f.summary" ] && cat "$f.summary"
exit 0
STUB
  chmod +x "$tmp/bin/lcov"

  local out rc
  out="$(cd "$tmp" && PATH="$tmp/bin:$PATH" bash ./build-cov-floor.sh 2>&1)"
  rc=$?
  if [ "$rc" -eq "$want" ]; then
    pass=$((pass + 1))
    echo "PASS  $name (exit $rc)"
  else
    fail=$((fail + 1))
    echo "FAIL  $name: expected exit $want, got $rc"
    printf '  %s\n' "$out"
  fi
  rm -rf "$tmp"
}

# 1. Every target at/above its floor -> exit 0.
run_case "all targets at or above floor" 0 \
  "$(summary_line 92.5)" "$(summary_line 89.1)" "$(summary_line 81.7)"

# 2. One target below its floor -> exit 1 (the gate's whole purpose).
run_case "compiler below floor" 1 \
  "$(summary_line 80.0)" "$(summary_line 89.1)" "$(summary_line 81.7)"

# 3. Empty summary (lcov printed nothing — e.g. an empty/broken extraction)
#    -> MUST exit 1. This is the fail-open branch: before the fix the script
#    printed `SKIP` and exited 0 with the floor never checked.
run_case "empty summary fails loud" 1 \
  "" "$(summary_line 89.1)" "$(summary_line 81.7)"

# 4. Malformed summary (output present, but no parseable `lines...:` line)
#    -> MUST exit 1, same reason.
run_case "malformed summary fails loud" 1 \
  "lcov: ERROR: no valid records found in tracefile" \
  "$(summary_line 89.1)" "$(summary_line 81.7)"

total=$((pass + fail))
# Positive floor: an exit code plus a failure count cannot tell "everything
# passed" from "nothing ran".
if [ "$total" -lt 1 ]; then
  echo "::error::floor-parsing test ran zero cases"
  exit 1
fi
echo "Results: $pass passed, $fail failed, $total total"
[ "$fail" -eq 0 ] || exit 1
