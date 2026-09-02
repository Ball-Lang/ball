#!/usr/bin/env bash
# Truth-table test for the detect-changed-stacks composite action (issue #458).
#
# Sources ../detect.sh and drives its pure classifier with a synthetic changed-
# file list per row, asserting EVERY one of the ten outputs
# (dart/ts/cpp/rust/csharp/go/python/infra/self_host/changed_fixtures) — not
# just "the script exited 0". Before #458 this test could not exist: the logic
# lived only as inline `run:` blocks glued to two workflow files'
# checkout+GITHUB_OUTPUT plumbing, with no callable entry point, which is
# exactly why two mutually-diverged copies of it could both stay green for
# months (#451/#457).
#
# No toolchain, no git, no network — sub-second on the Linux runner, wired into
# ci.yml's always-run `proto` job. (On a Windows dev box it can take a couple of
# MINUTES of wall time for ~5s of CPU: each row spawns a handful of
# grep/awk/sed/sort processes and Git-Bash process creation is very slow there.
# That is the environment, not a hang.)
#
# Usage: bash .github/actions/detect-changed-stacks/test/truth_table.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../detect.sh
source "$HERE/../detect.sh"

pass=0
fail=0

# expect_rows <row name> <expected block> <actual block>
expect_rows() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass=$((pass + 1))
    echo "PASS  $name"
  else
    fail=$((fail + 1))
    echo "FAIL  $name"
    echo "  expected:"
    printf '    %s\n' $expected
    echo "  actual:"
    printf '    %s\n' $actual
  fi
}

# row <name> <files> <fixture_status> <expected key=value block>
row() {
  local name="$1" files="$2" fixture_status="$3" expected="$4"
  local actual
  actual="$(ball_classify_stacks "$files" "$fixture_status")"
  expect_rows "$name" "$expected" "$actual"
}

# Shorthand builder: every stack false unless overridden. Arguments are the
# keys that should be true, e.g. `expect go` or `expect dart self_host cpp`.
# changed_fixtures is always empty unless passed as fixtures=<value>.
expect() {
  local -A t=()
  local fixtures=""
  local a
  for a in "$@"; do
    case "$a" in
    fixtures=*) fixtures="${a#fixtures=}" ;;
    *) t[$a]=1 ;;
    esac
  done
  local k
  for k in dart ts cpp rust csharp go python infra self_host; do
    if [ -n "${t[$k]:-}" ]; then echo "$k=true"; else echo "$k=false"; fi
  done
  echo "changed_fixtures=$fixtures"
}

# ── Single-stack rows: exactly one language flag, infra stays false ──────────
row "go-only" 'go/cli/cmd/ball/main.go' '' "$(expect go)"
row "python-only" 'python/compiler/ball_compiler/base_call.py' '' "$(expect python)"
row "dart-only" 'dart/compiler/lib/compiler.dart' '' "$(expect dart)"
row "ts-only" 'ts/engine/src/index.ts' '' "$(expect ts)"
row "cpp-only" 'cpp/compiler/src/compiler.cpp' '' "$(expect cpp)"
row "rust-only" 'rust/compiler/src/base_call.rs' '' "$(expect rust)"
row "csharp-only" 'csharp/compiler/src/BaseCall.cs' '' "$(expect csharp)"

# ── infra (fail-safe): anything outside the single-stack dirs runs everything ─
row "proto-only" 'proto/ball/v1/ball.proto' '' "$(expect infra)"
row "workflow-only" '.github/workflows/ci.yml' '' "$(expect infra)"
row "root-config-only" 'pubspec.yaml' '' "$(expect infra)"

# ── Conformance fixtures: infra=true AND the fixture stem is reported ────────
row "fixture-added" 'tests/conformance/426_example.ball.json' \
  "$(printf 'A\ttests/conformance/426_example.ball.json')" \
  "$(expect infra fixtures=426_example)"
row "fixture-deleted-excluded" 'tests/conformance/426_example.ball.json' \
  "$(printf 'D\ttests/conformance/426_example.ball.json')" \
  "$(expect infra)"
row "fixture-renamed-uses-new-path" 'tests/conformance/427_new.ball.json' \
  "$(printf 'R100\ttests/conformance/426_old.ball.json\ttests/conformance/427_new.ball.json')" \
  "$(expect infra fixtures=427_new)"

# ── Mixed ───────────────────────────────────────────────────────────────────
row "go-plus-proto" "$(printf 'go/compiler/compile.go\nproto/ball/v1/ball.proto')" '' \
  "$(expect go infra)"

# ── self_host: a dart/ edit that cross-compiles into every self-hosted engine ─
row "self-host-engine-source" 'dart/engine/lib/engine.dart' '' \
  "$(expect dart cpp rust csharp go python self_host)"
row "self-host-cli-core" 'dart/shared/lib/cli_core.dart' '' \
  "$(expect dart cpp rust csharp go python self_host)"
# A dart/shared file that is NOT part of the self-host CLI core stays dart-only.
row "dart-shared-non-selfhost" 'dart/shared/lib/std.dart' '' "$(expect dart)"

# ── Fail-open: no usable diff base => every stack true, fixtures=ALL ─────────
expect_rows "fail-open-no-base" \
  "$(expect dart ts cpp rust csharp go python infra self_host fixtures=ALL)" \
  "$(ball_fail_open)"

total=$((pass + fail))
# Positive floor: an exit code plus a failure count cannot tell "everything
# passed" from "nothing ran".
if [ "$total" -lt 1 ]; then
  echo "::error::truth table ran zero rows"
  exit 1
fi
echo "Results: $pass passed, $fail failed, $total total"
[ "$fail" -eq 0 ] || exit 1
