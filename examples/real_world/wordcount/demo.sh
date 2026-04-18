#!/usr/bin/env bash
# Ball end-to-end demo: encode → audit → compile → verify on a small Dart CLI.
#
# Runs the whole pipeline and prints timings. Re-runnable; outputs go to
# this directory.
#
# Prerequisites:
#   - Dart SDK 3.9+
#   - `dart pub get` has been run in this directory (done automatically below)
#
# POSIX-compatible (tested on bash, Git Bash on Windows).
set -eu

# Move to the script directory so paths are stable wherever it's invoked.
cd "$(dirname "$0")"

BALL_ROOT="$(cd ../../.. && pwd)"
DART_DIR="$BALL_ROOT/dart"
# Helper: run the Ball CLI from the dart workspace (`ball_cli:ball` is only
# resolvable there) but operate on files in the current directory.
ball_cli() {
  (cd "$DART_DIR" && dart run ball_cli:ball "$@")
}

say() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
time_cmd() {
  local label="$1"; shift
  local start end
  start=$(date +%s)
  "$@"
  end=$(date +%s)
  # Timing to stderr so it doesn't pollute stdout redirections.
  printf '  %s: %ss\n' "$label" "$((end - start))" >&2
}

# ---------------------------------------------------------------
say "0. pub get"
time_cmd "deps" dart pub get

# ---------------------------------------------------------------
say "1. run the original Dart"
time_cmd "orig" dart run src/wordcount.dart > original.txt
cat original.txt

# ---------------------------------------------------------------
say "2. encode Dart → Ball"
mkdir -p ball
time_cmd "encode" dart run encode.dart

# ---------------------------------------------------------------
say "3. audit capabilities"
HERE="$(pwd)"
time_cmd "audit" ball_cli audit "$HERE/ball/wordcount.ball.json" --output "$HERE/audit.json"
# Also show the human-readable form.
ball_cli audit "$HERE/ball/wordcount.ball.json" | tee audit.txt >/dev/null
cat audit.txt

# ---------------------------------------------------------------
say "4. compile Ball → Dart"
mkdir -p compiled
time_cmd "compile" dart run decode.dart

# ---------------------------------------------------------------
say "5. run the compiled Dart"
time_cmd "compiled" dart run compiled/wordcount.dart > compiled.txt
cat compiled.txt

# ---------------------------------------------------------------
say "6. diff original vs compiled"
if diff -u original.txt compiled.txt; then
  printf '\n\033[1;32mIDENTICAL ✓\033[0m  — round-trip preserved program output.\n'
else
  printf '\n\033[1;31mDIVERGED ✗\033[0m  — see diff above.\n'
  exit 1
fi
