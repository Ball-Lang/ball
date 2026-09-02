#!/usr/bin/env bash
# Detect which stacks a PR/push touched, so the heavy per-stack jobs in
# ci.yml / regression-gates.yml can skip when nothing in their stack changed.
#
# SINGLE SOURCE OF TRUTH (issue #458). This logic used to live as two
# hand-copied inline `run:` blocks — one in .github/workflows/ci.yml's `changes`
# job, one in .github/workflows/regression-gates.yml's — and they drifted:
# #438 wired Go into ci.yml only, and #457 had to repair BOTH copies of the
# infra-exclusion regex in one commit (a 1-token fix on ci.yml's side, a
# 4-token fix on regression-gates.yml's, which was still listing only
# `dart/|ts/|cpp/`). Nothing in CI compared the two — the "Detect changed
# stacks" check is two independent job runs, each of which only has to exit 0.
# There is exactly one copy now, and test/truth_table.sh pins its behaviour.
#
# Native git-diff — no third-party action.
#
# FAIL-OPEN: if a real diff base can't be determined (first push, force-push,
# zero/missing base), every output is `true` so NO check is ever silently
# skipped.
# FAIL-SAFE: `infra` (any file outside the single-stack dirs — proto/, tests/,
# tools/, examples/, root configs, workflows) forces every stack to run, since
# protos feed all bindings and a path we forgot to map can never silently skip
# a check.
#
# PRECONDITION: the caller must have checked out with `fetch-depth: 0` so the
# merge-base is reachable. (Deliberately NOT done inside the composite action:
# each caller keeps its own actions/checkout step.)
#
# Sourcing this file defines the functions without running anything, which is
# how test/truth_table.sh feeds synthetic inputs to them.

# ball_fail_open — the every-output-true block used when no diff base is usable.
# `changed_fixtures=ALL` is the fail-open sentinel for the fixture filter too:
# ci.yml's typescript job then runs the FULL full_e2e.ts sweep rather than skip
# it, since we cannot compute what changed.
ball_fail_open() {
  echo "dart=true"
  echo "ts=true"
  echo "cpp=true"
  echo "rust=true"
  echo "csharp=true"
  echo "go=true"
  echo "python=true"
  echo "infra=true"
  echo "self_host=true"
  echo "changed_fixtures=ALL"
}

# ball_classify_stacks <files> <fixture_status>
#   files          — newline-separated changed paths (`git diff --name-only`)
#   fixture_status — `git diff --name-status -- 'tests/conformance/*.ball.json'`
# Emits `key=value` lines on stdout (the GITHUB_OUTPUT shape). Pure: no git, no
# filesystem, no environment — so the truth-table test can drive every row.
ball_classify_stacks() {
  local files="$1"
  local fixture_status="${2:-}"

  # here-strings (not `echo | grep`) so `set -o pipefail` can't flake on
  # SIGPIPE when grep -q early-exits on a large file list.
  m() { grep -qE "$1" <<<"$files"; }
  out() { if m "$2"; then echo "$1=true"; else echo "$1=false"; fi; }

  # infra = ANY changed file OUTSIDE the single-stack dirs — proto/, tests/,
  # tools/, examples/, root configs, the workflows themselves, etc. Anything
  # cross-cutting forces every stack to run.
  #
  # List every language dir THAT HAS ITS OWN OUTPUT AND JOB — and only those.
  # The two directions fail very differently:
  #   * Omitting such a dir is merely wasteful: it yields a false infra=true,
  #     dragging the whole ~25-min C++ matrix into a PR that cannot possibly
  #     affect it. `go/` was missed when #438 wired Go up (#451) — fail-safe,
  #     but pure waste on every Go PR.
  #   * Adding a dir that has NO job (java/ today: bindings only, no CI job) is
  #     UNSAFE — it would stop tripping infra without anything else covering it,
  #     silently dropping that PR to proto-only checks.
  # So java/ is correctly absent. Add it here only alongside a java job.
  local infra=false
  if grep -qvE '^(dart/|ts/|cpp/|rust/|csharp/|go/|python/)' <<<"$files"; then infra=true; fi

  # self_host = the diff touches a Dart source that CROSS-COMPILES into the
  # C++, Rust, C#, Go AND Python self-hosted artifacts, even though it lives
  # under dart/ (so it would otherwise flip only dart=true):
  #   * dart/engine/lib/**  -> engine_rt.cpp / compiled_engine.rs /
  #     CompiledEngine.cs / compiled_engine.go / compiled_engine.py — the
  #     self-hosted ENGINE (engine.dart + its part files), encoded by
  #     compile_engine_cpp.dart and gen_engine_json.dart (+ ball-engine-regen /
  #     Ball.Engine.Regen / go/engine's cmd/regen / ball_engine.regen).
  #   * dart/shared/lib/cli_core.dart + its parts (capability_analyzer,
  #     capability_table, termination_analyzer) -> cli_rt.h / compiled_cli.rs /
  #     CompiledCli.cs — the self-hosted CLI core, encoded by gen_cli_cpp.dart
  #     and gen_cli_json.dart (+ ball-cli-regen / Ball.Cli.Regen).
  # These artifacts are REGENERATED from these Dart sources at CI build time,
  # so a Dart-only edit to them changes what the C++/Rust/C#/Go/Python jobs
  # compile and run — yet, mapped by top-level dir alone, sets only dart=true
  # and SKIPS those self-host jobs. That exact blind spot let a C++ self-host
  # break slip through PR CI in #398 (and forced #413's manual verification
  # lane). OR self_host into cpp/rust/csharp/go/python below. (dart/compiler,
  # dart/encoder, dart/cli are the Dart-target toolchain, not self-host program
  # inputs, so they are NOT here — the C++/Rust/C# targets use their OWN
  # compilers for the Ball->native step.) See #416, #386.
  local self_host=false
  if m '^dart/engine/lib/|^dart/shared/lib/(cli_core|capability_analyzer|capability_table|termination_analyzer)\.dart$'; then self_host=true; fi

  # New/changed conformance fixtures (never deleted) under
  # tests/conformance/*.ball.json, as bare fixture stems (no dir, no
  # extension), space-separated. Closes the escape class where a fixture
  # regression is only caught by a heavy leg that runs main-only (e.g.
  # full_e2e.ts's ~350-fixture sweep, gated behind coverage.yml — see
  # #337/#345): ci.yml's typescript job runs full_e2e.ts against JUST this list
  # on every PR, cheaply.
  # --name-status columns are "STATUS\tFILE" for add/modify, or
  # "R###\tOLD\tNEW" for renames — $NF (last field) is the current path either
  # way. Deleted files ('D') are excluded: a fixture that no longer exists has
  # nothing to run.
  local changed_fixtures
  changed_fixtures="$(printf '%s\n' "$fixture_status" |
    awk '$1 !~ /^D/ && NF { print $NF }' |
    sed -E 's#.*/##; s/\.ball\.json$//' |
    sort -u | tr '\n' ' ' | sed -E 's/^ +//; s/ +$//')"

  out dart '^dart/'
  out ts '^ts/'
  # cpp/rust/csharp/go/python run on their own dir changes OR any self-host
  # Dart source change (self_host above — #416, #386): those sources
  # cross-compile into the C++/Rust/C#/Go/Python self-host artifacts even
  # though they live under dart/ (python's engine regen reads
  # dart/self_host/engine.ball.json, generated from dart/engine).
  if m '^cpp/' || [ "$self_host" = true ]; then echo "cpp=true"; else echo "cpp=false"; fi
  if m '^rust/' || [ "$self_host" = true ]; then echo "rust=true"; else echo "rust=false"; fi
  if m '^csharp/' || [ "$self_host" = true ]; then echo "csharp=true"; else echo "csharp=false"; fi
  if m '^go/' || [ "$self_host" = true ]; then echo "go=true"; else echo "go=false"; fi
  if m '^python/' || [ "$self_host" = true ]; then echo "python=true"; else echo "python=false"; fi
  echo "infra=$infra"
  echo "self_host=$self_host"
  echo "changed_fixtures=$changed_fixtures"
}

# ball_detect_main — resolve the diff base from the event, then classify.
# Writes `key=value` lines to $GITHUB_OUTPUT.
ball_detect_main() {
  local base="" zero="0000000000000000000000000000000000000000"
  # `|| true` so `set -e` cannot abort on the non-matching branch.
  [ "${EVENT:-}" = "pull_request" ] && base="${PR_BASE:-}" || true
  [ "${EVENT:-}" = "push" ] && base="${PUSH_BASE:-}" || true
  if [ -z "$base" ] || [ "$base" = "$zero" ] || ! git cat-file -e "${base}^{commit}" 2>/dev/null; then
    echo "No usable diff base ('$base') — failing OPEN: run every stack."
    ball_fail_open >>"$GITHUB_OUTPUT"
    cat "$GITHUB_OUTPUT"
    return 0
  fi
  # Three-dot (merge-base) diff: ONLY this branch's own changes, never commits
  # the base branch gained since we forked. With two-dot, a sibling PR that
  # merges to main first leaks its files into this diff — e.g. a dart-only PR
  # would suddenly see the other PR's workflow/proto change, flip infra=true,
  # and run every stack. The merge-base is reachable thanks to fetch-depth: 0.
  local files fixture_status
  files="$(git diff --name-only "$base...HEAD")"
  echo "Changed files vs merge-base(${base}, HEAD):"
  echo "$files"
  fixture_status="$(git diff --name-status "$base...HEAD" -- 'tests/conformance/*.ball.json')"
  ball_classify_stacks "$files" "$fixture_status" >>"$GITHUB_OUTPUT"
  cat "$GITHUB_OUTPUT"
}

# Run only when executed, not when sourced by the truth-table test.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
  ball_detect_main
fi
