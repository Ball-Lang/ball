#!/usr/bin/env bash
# Truth-table test for the detect-changed-stacks composite action (issue #458).
#
# Sources ../detect.sh and drives its pure classifier with a synthetic changed-
# file list per row, asserting EVERY one of the twelve outputs
# (dart/ts/cpp/rust/csharp/go/python/infra/self_host/corpus/dart_core/
# changed_fixtures) — not
# just "the script exited 0". The last four rows drive the real entry point,
# ball_detect_main, once per event that supplies no diff base, to pin the
# fail-open path itself. Before #458 this test could not exist: the logic
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
  for k in dart ts cpp rust csharp go python infra self_host corpus dart_core; do
    if [ -n "${t[$k]:-}" ]; then echo "$k=true"; else echo "$k=false"; fi
  done
  echo "changed_fixtures=$fixtures"
}

# ── Single-stack rows: exactly one language flag, infra stays false ──────────
row "go-only" 'go/cli/cmd/ball/main.go' '' "$(expect go)"
row "python-only" 'python/compiler/ball_compiler/base_call.py' '' "$(expect python)"
row "dart-only" 'dart/compiler/lib/compiler.dart' '' "$(expect dart dart_core)"
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
  "$(expect infra corpus fixtures=426_example)"
row "fixture-deleted-excluded" 'tests/conformance/426_example.ball.json' \
  "$(printf 'D\ttests/conformance/426_example.ball.json')" \
  "$(expect infra corpus)"
row "fixture-renamed-uses-new-path" 'tests/conformance/427_new.ball.json' \
  "$(printf 'R100\ttests/conformance/426_old.ball.json\ttests/conformance/427_new.ball.json')" \
  "$(expect infra corpus fixtures=427_new)"

# ── Mixed ───────────────────────────────────────────────────────────────────
row "go-plus-proto" "$(printf 'go/compiler/compile.go\nproto/ball/v1/ball.proto')" '' \
  "$(expect go infra)"

# ── self_host: a dart/ edit that cross-compiles into every self-hosted engine ─
row "self-host-engine-source" 'dart/engine/lib/engine.dart' '' \
  "$(expect dart cpp rust csharp go python self_host dart_core)"
row "self-host-cli-core" 'dart/shared/lib/cli_core.dart' '' \
  "$(expect dart cpp rust csharp go python self_host dart_core)"
# A dart/shared file that is NOT part of the self-host CLI core does not flip
# self_host — but it IS a conformance-matrix core input (std.json feeds
# every compiled program), so dart_core is true.
row "dart-shared-non-selfhost" 'dart/shared/lib/std.dart' '' "$(expect dart dart_core)"

# ── corpus / dart_core: the conformance-matrix row selectors (#666) ──────────
# conformance-matrix.yml's `pull_request:` trigger is `paths:`-filtered, and
# since #666 each ROW is additionally conditioned on the stack it covers.
# `corpus` and `dart_core` are the two signals that must switch EVERY row back
# on: a fixture change, and a change to the Dart sources every self-hosted
# engine is compiled from.
row "corpus-fixture-source" 'tests/conformance/src/466_map_contains_value.dart' '' \
  "$(expect infra corpus)"
# A tests/ file OUTSIDE the conformance corpus is infra (it forces every ci.yml
# stack) but not corpus — it is no conformance row's input.
row "tests-outside-corpus-is-not-corpus" 'tests/editions/portability_matrix.md' '' \
  "$(expect infra)"
row "dart-core-compiler-tool" 'dart/compiler/tool/gen_engine_json.dart' '' \
  "$(expect dart dart_core)"
row "dart-core-self-host-dir" 'dart/self_host/lib/engine_rt.cpp' '' \
  "$(expect dart dart_core)"
# dart/encoder, dart/cli and dart/ball_protobuf are the Dart-target toolchain,
# not inputs to any conformance row — dart, but NOT dart_core.
row "dart-encoder-is-not-core" 'dart/encoder/lib/encoder.dart' '' "$(expect dart)"
row "dart-cli-is-not-core" 'dart/cli/bin/ball.dart' '' "$(expect dart)"

# An EMPTY changed-file list is the one input shape whose outputs would
# otherwise be unpinned. It cannot arise from a real diff (a run with no changed
# files still has a base), but it is what a mis-wired caller would pass, so pin
# the fail-safe answer: the empty line fails the single-stack prefix match, so
# `grep -qvE` succeeds and infra=true — everything runs, nothing is skipped.
row "empty-file-list" '' '' "$(expect infra)"

# ── Fail-open: no usable diff base => every stack true, fixtures=ALL ─────────
expect_rows "fail-open-no-base" \
  "$(expect dart ts cpp rust csharp go python infra self_host corpus dart_core fixtures=ALL)" \
  "$(ball_fail_open)"

# The same fail-open, driven END-TO-END through ball_detect_main for each event
# that supplies NO diff base. `schedule` and `workflow_dispatch` became
# reachable when ci.yml gained its weekly toolchain-drift canary (#500): neither
# event sets PR_BASE or PUSH_BASE, so the base stays empty and every stack must
# run. `pull_request` with an empty PR_BASE is the mis-wired-caller case, and
# the all-zeroes SHA is what a first push on a branch reports. Asserting the
# real entry point (not just ball_fail_open in isolation) is what proves the
# event plumbing, and it short-circuits before any git call, so no repo state is
# involved.
event_fail_open_row() {
  local name="$1" event="$2" pr_base="${3:-}" push_base="${4:-}"
  local out_file actual
  out_file="$(mktemp)"
  (
    EVENT="$event" PR_BASE="$pr_base" PUSH_BASE="$push_base" \
      GITHUB_OUTPUT="$out_file" ball_detect_main
  ) >/dev/null
  actual="$(cat "$out_file")"
  rm -f "$out_file"
  expect_rows "$name" \
    "$(expect dart ts cpp rust csharp go python infra self_host corpus dart_core fixtures=ALL)" \
    "$actual"
}

event_fail_open_row "fail-open-event-schedule" schedule
event_fail_open_row "fail-open-event-workflow_dispatch" workflow_dispatch
event_fail_open_row "fail-open-event-pull_request-empty-base" pull_request '' ''
event_fail_open_row "fail-open-event-push-zero-sha" push '' \
  '0000000000000000000000000000000000000000'

total=$((pass + fail))
# Positive floor: an exit code plus a failure count cannot tell "everything
# passed" from "nothing ran".
if [ "$total" -lt 1 ]; then
  echo "::error::truth table ran zero rows"
  exit 1
fi
echo "Results: $pass passed, $fail failed, $total total"
[ "$fail" -eq 0 ] || exit 1
