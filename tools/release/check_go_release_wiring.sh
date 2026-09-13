#!/usr/bin/env bash
# Static consistency guard for the Go module release lane (#361).
#
# WHY THIS EXISTS: Go's registry IS the git tag. `tag-go-modules.yml` has cut
# the six `go/<module>/vX.Y.Z` tags automatically since #361 — but only ever at
# the version already written into the `go/*/go.mod` files, and moving THAT
# number was a human action: someone had to notice the Go tree had changed, run
# `tools/go-module-proxy/bump_go_modules.sh vX.Y.Z`, and open a `chore(go):` PR.
# Between #361 (2026-09-05) and #586 (2026-09-13) that happened exactly once, so
# every release in between re-dispatched the tagging workflow and it correctly,
# idempotently, did nothing: `go install …@latest` kept serving v0.1.0 while the
# Go tree moved under it.
#
# That is the same failure shape as the pub.dev lane (#551) one level down. The
# automation around the human step was green the whole time — the dispatch fired
# on every release, the workflow ran, the job passed — because "all six tags
# already exist, nothing to do" is indistinguishable from "this lane is
# healthy". A human step that stops happening is invisible.
#
# So this guard pins the post-fix contract: the Go module VERSION is computed by
# semantic-release from `go/`-path conventional commits, and every part of the
# lane from that decision to the six tags is machine-driven.
#
#   1. the lane has exactly one semantic-release config, and it is internally
#      consistent (tag line / path filter / bump / commit / dispatch all agree);
#   2. the config commits EVERY file the bump script rewrites — a version left
#      behind in one file is a half-landed bump, which is either an "unknown
#      revision" for consumers or a silent fall-through to the public proxy;
#   3. exactly one workflow drives that config, it is reachable automatically
#      from a release, and it can be rehearsed with dry_run on its own branch;
#   4. `tag_go_modules.sh` remains the SINGLE tagging path — nothing else may
#      create a `go/<module>/vX.Y.Z` tag, because the all-or-nothing / half-
#      tagged refusal only holds if every tag goes through it;
#   5. the module line cannot silently cross into v2 — Go requires a `/vN`
#      module-path suffix from major 2 on, which these paths do not carry;
#   6. the guards are wired into CI.
#
# Deliberately textual/grep-based against the DOCUMENTED pattern, in the same
# style as `check_release_dispatch_wiring.sh` and
# `check_pubdev_release_wiring.sh`: it asserts the handful of things that make
# the lane fire without a human, not the incidental shape of the YAML and JSON
# around them, so a legitimate refactor does not false-red.
#
# Usage: bash tools/release/check_go_release_wiring.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORKFLOWS="$ROOT/.github/workflows"
CONFIGS="$ROOT/.github/release"
RELEASE="$WORKFLOWS/release.yml"
DRIVER="$WORKFLOWS/go-release.yml"
TAGGER="$WORKFLOWS/tag-go-modules.yml"
CI="$WORKFLOWS/ci.yml"
CFG="$CONFIGS/go.releaserc.json"
BUMP="$ROOT/tools/go-module-proxy/bump_go_modules.sh"
TAGSH="$ROOT/tools/go-module-proxy/tag_go_modules.sh"

pass=0
fail=0

ok() {
  pass=$((pass + 1))
  echo "PASS  $1"
}

no() {
  fail=$((fail + 1))
  echo "FAIL  $1"
  shift
  local line
  for line in "$@"; do printf '  %s\n' "$line"; done
}

SELF_TEST=0
case "${1-}" in
--self-test)
  SELF_TEST=1
  shift
  ;;
"") ;;
*)
  echo "::error::unknown argument: $1" >&2
  exit 2
  ;;
esac

# ── The negative controls for the checker above. ──────────────────────────
# A guard whose own failure path is never exercised is decoration: the leg would
# pass identically if `freshness_paths_problems` stopped looking at the list.
# Driven from ci.yml's always-on `Proto Checks` job.
SCRATCH=""
cleanup() {
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  return 0
}

self_test() {
  local pass=0 fail=0
  SCRATCH="$(mktemp -d)"
  trap cleanup EXIT

  expect() { # name want-exit file [needle …]
    local name="$1" want="$2" file="$3"
    shift 3
    local out rc=0 good=1 needle
    out="$(freshness_paths_problems "$file" 2>&1)" || rc=$?
    [ "$rc" -eq "$want" ] || good=0
    for needle in "$@"; do
      case "$out" in
      *"$needle"*) ;;
      *) good=0 ;;
      esac
    done
    if [ "$good" -eq 1 ]; then
      pass=$((pass + 1))
      echo "PASS  $name"
    else
      fail=$((fail + 1))
      echo "FAIL  $name (exit $rc, wanted $want)"
      printf '%s\n' "$out" | sed 's/^/    | /'
    fi
  }

  write() { # file, then the yaml body on stdin
    cat >"$SCRATCH/$1"
  }

  write exact.yml <<'YML'
name: Go module freshness
on:
  pull_request:
    paths:
      - .github/workflows/go-freshness.yml
      - tools/release/check_go_freshness.sh
  schedule:
    - cron: "30 7 * * 1"
  workflow_dispatch:
jobs:
  freshness:
    runs-on: ubuntu-latest
    steps:
      - run: bash tools/release/check_go_freshness.sh
YML

  write reordered.yml <<'YML'
name: Go module freshness
on:
  pull_request:
    paths:
      - tools/release/check_go_freshness.sh
      - .github/workflows/go-freshness.yml
  schedule:
    - cron: "30 7 * * 1"
YML

  write widened.yml <<'YML'
name: Go module freshness
on:
  pull_request:
    paths:
      - .github/workflows/go-freshness.yml
      - tools/release/check_go_freshness.sh
      - go/**
  schedule:
    - cron: "30 7 * * 1"
YML

  write narrowed.yml <<'YML'
name: Go module freshness
on:
  pull_request:
    paths:
      - .github/workflows/go-freshness.yml
  schedule:
    - cron: "30 7 * * 1"
YML

  write unfiltered.yml <<'YML'
name: Go module freshness
on:
  pull_request:
    branches: [main]
  schedule:
    - cron: "30 7 * * 1"
YML

  write ignore.yml <<'YML'
name: Go module freshness
on:
  pull_request:
    paths-ignore:
      - docs/**
  schedule:
    - cron: "30 7 * * 1"
YML

  write no_pr.yml <<'YML'
name: Go module freshness
on:
  schedule:
    - cron: "30 7 * * 1"
  workflow_dispatch:
YML

  write broken.yml <<'YML'
name: Go module freshness
on:
  pull_request:
    paths:
      - .github/workflows/go-freshness.yml
     bad indentation here
YML

  expect "the exact two-file list is accepted" 0 "$SCRATCH/exact.yml"
  expect "the same two files in the other order are accepted (it is a set)" 0 "$SCRATCH/reordered.yml"
  expect "a WIDENED list is refused" 1 "$SCRATCH/widened.yml" "go/**"
  expect "a NARROWED list is refused" 1 "$SCRATCH/narrowed.yml" "tools/release/check_go_freshness.sh"
  expect "a pull_request trigger with no paths filter is refused" 1 "$SCRATCH/unfiltered.yml" "EVERY pull request"
  expect "paths-ignore smuggled in place of paths is refused" 1 "$SCRATCH/ignore.yml" "paths-ignore"
  expect "a workflow with no pull_request trigger at all is refused" 1 "$SCRATCH/no_pr.yml" "no pull_request trigger"
  expect "unparseable YAML is refused, never read as agreement" 1 "$SCRATCH/broken.yml" "not parseable YAML"
  expect "the shipped .github/workflows/go-freshness.yml satisfies it" 0 "$WORKFLOWS/go-freshness.yml"

  local total=$((pass + fail))
  local MIN=9
  case "$pass$fail$total" in
  *[!0-9]*)
    echo "::error::go-freshness paths self-test produced a non-numeric tally"
    return 1
    ;;
  esac
  if [ "$total" -lt "$MIN" ]; then
    echo "::error::go-freshness paths self-test ran $total cases, expected at least $MIN — the sweep itself is broken"
    return 1
  fi
  echo "Results: $pass passed, $fail failed, $total total"
  [ "$fail" -eq 0 ]
}

if [ "$SELF_TEST" -eq 1 ]; then
  self_test
  exit $?
fi

[ -f "$RELEASE" ] || {
  echo "::error::missing $RELEASE"
  exit 1
}

# ── 1. The lane has a semantic-release config. ────────────────────────────
if [ -f "$CFG" ]; then
  ok ".github/release/go.releaserc.json exists (the Go module version line)"
else
  no ".github/release/go.releaserc.json exists (the Go module version line)" \
    "without it the Go module version only moves when a human runs bump_go_modules.sh," \
    "and the tagging workflow keeps reporting 'already tagged, nothing to do' forever (#361)"
fi

# ── 2. Per-config internal consistency. ───────────────────────────────────
# Every field that names the lane must name the SAME lane: a config whose
# tagFormat says go-modules while its prepareCmd bumps something else publishes
# one tree under another tree's tag, and both halves look plausible in review.
if [ -f "$CFG" ]; then
  probs=()
  grep -qF '"branches": ["main"]' "$CFG" ||
    probs+=("expected \"branches\": [\"main\"] — the Go line is cut from main like every other lane")
  grep -qF '"tagFormat": "go-modules/v${version}"' "$CFG" ||
    probs+=(
      "expected \"tagFormat\": \"go-modules/v\${version}\""
      "the channel tag must NOT be one of the six go/<module>/vX.Y.Z tags: semantic-release"
      "creates its own tag, and a collision would leave tag_go_modules.sh staring at a"
      "half-tagged set it is required to refuse"
    )
  grep -qF '"paths": ["go"]' "$CFG" ||
    probs+=("expected the only-package-commits path filter to be \"paths\": [\"go\"]")
  grep -qF 'bump_go_modules.sh --check-next v${nextRelease.version} --type ${nextRelease.type}' "$CFG" ||
    probs+=(
      "expected a verifyReleaseCmd running:"
      "  bash tools/go-module-proxy/bump_go_modules.sh --check-next v\${nextRelease.version} --type \${nextRelease.type}"
      "verifyRelease is one of the four steps semantic-release also runs under --dry-run, so this"
      "is what makes a rehearsal prove the computed version instead of guessing at it"
    )
  grep -qF 'bump_go_modules.sh v${nextRelease.version}' "$CFG" ||
    probs+=("expected a prepareCmd running: bash tools/go-module-proxy/bump_go_modules.sh v\${nextRelease.version}")
  grep -qF 'await_workflow_run.py --dispatch --workflow tag-go-modules.yml --ref go-modules/v${nextRelease.version}' "$CFG" ||
    probs+=(
      "expected publishCmd: python3 tools/release/await_workflow_run.py --dispatch \\"
      "  --workflow tag-go-modules.yml --ref go-modules/v\${nextRelease.version}"
      "a bare \`gh workflow run\` returns the moment GitHub ACCEPTS the dispatch, so the release run"
      "reports success whether the tagger then cut six tags, refused a half-tagged set, or never"
      "started at all — the lane's only signal would once again be 'the automation ran' (#627)."
      "The poller waits for the dispatched run and fails the publish step on any non-success."
      "semantic-release creates its tag AFTER prepare and BEFORE publish, on the commit"
      "@semantic-release/git just pushed, so that tag is the ref carrying the bumped go.mod files"
    )
  grep -qF 'chore(release): go v${nextRelease.version} [skip ci]' "$CFG" ||
    probs+=("expected the @semantic-release/git message: chore(release): go v\${nextRelease.version} [skip ci]")
  if [ "${#probs[@]}" -eq 0 ]; then
    ok "go.releaserc.json is internally consistent (branches, tag line, paths, check, bump, dispatch, message)"
  else
    no "go.releaserc.json is internally consistent (branches, tag line, paths, check, bump, dispatch, message)" \
      "${probs[@]}"
  fi
fi

# ── 3. The commit carries EVERY file the bump rewrites. ───────────────────
# The bump is a cross-file number — six go/*/go.mod requires, go/go.work's
# versioned replace pins, go/cli/version.go's fallback constant and the internal
# tools/coverage-study/go consumer. @semantic-release/git commits only what its
# `assets` globs match, so a file the bump rewrote and the assets do not cover
# is rewritten on the runner, tagged, and then thrown away — leaving main and
# the tag disagreeing about the module line. Computed from the tree, never a
# hardcoded list, so a seventh module or a new internal consumer is covered the
# day it lands.
if [ -f "$CFG" ]; then
  assets="$(sed -n '/"assets"/,/]/p' "$CFG")"
  rewritten=()
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -Eq 'github\.com/ball-lang/ball/go/[a-z][a-z0-9_]*[[:space:]]+v[0-9]' "$ROOT/$f" 2>/dev/null &&
      rewritten+=("$f")
  done < <(
    {
      printf '%s\n' "go/go.work"
      git -C "$ROOT" ls-files -- '*go.mod' 2>/dev/null
    } | sort -u
  )
  rewritten+=("go/cli/version.go") # the ninth site: `ball version`'s fallback
  uncovered=()
  for f in "${rewritten[@]}"; do
    covered=0
    # Match each asset glob against the path the same way a shell glob would.
    while IFS= read -r glob; do
      [ -n "$glob" ] || continue
      # shellcheck disable=SC2254  # the glob is the pattern, deliberately
      case "$f" in
      $glob) covered=1 ;;
      esac
    done < <(printf '%s\n' "$assets" | grep -oE '"[^"]*"' | tr -d '"' | grep -v '^assets$')
    [ "$covered" -eq 1 ] || uncovered+=("$f")
  done
  if [ "${#rewritten[@]}" -lt 7 ]; then
    no "the bump's rewrite set was discovered (>= 7 files carry the module version)" \
      "found only ${#rewritten[@]} — the discovery sweep is broken, so the coverage check below is vacuous"
  elif [ "${#uncovered[@]}" -eq 0 ]; then
    ok "go.releaserc.json commits every one of the ${#rewritten[@]} files the bump rewrites"
  else
    no "go.releaserc.json commits every one of the ${#rewritten[@]} files the bump rewrites" \
      "not matched by any @semantic-release/git asset glob: ${uncovered[*]}" \
      "a rewritten-but-uncommitted file leaves main and the go/<module> tags disagreeing about the version"
  fi
fi

# ── 4. A driver workflow exists, and it is reachable without a human. ─────
if [ -f "$DRIVER" ]; then
  ok "go-release.yml exists"

  probs=()
  grep -qE '^[[:space:]]*workflow_dispatch:' "$DRIVER" ||
    probs+=("release.yml invokes it with 'gh workflow run', which 422s without workflow_dispatch")
  grep -qE '^[[:space:]]*dry_run:' "$DRIVER" ||
    probs+=(
      "expected a dry_run input: a lane that can only be exercised by merging it ships unrehearsed,"
      "which is how #566 reached main"
    )
  grep -qF "inputs.dry_run && github.ref || 'main'" "$DRIVER" ||
    probs+=(
      "expected the checkout ref: \${{ inputs.dry_run && github.ref || 'main' }}"
      "a real run must check out main (that is what makes @semantic-release/git's push a"
      "fast-forward); a dry run must check out the ref it was dispatched for"
    )
  grep -qF -- '--branches ${GITHUB_REF_NAME}' "$DRIVER" ||
    probs+=(
      "expected the dry-run flag to carry --branches \${GITHUB_REF_NAME}"
      "the config declares branches: [\"main\"] and semantic-release reads the current branch from"
      "GITHUB_REF, so a rehearsal on any other branch computes nothing at all"
    )
  grep -qF 'go.releaserc.json' "$DRIVER" ||
    probs+=("expected the driver to stage .github/release/go.releaserc.json as the discovered config")
  grep -qF 'cd tools/release && npm ci' "$DRIVER" ||
    probs+=(
      "expected 'cd tools/release && npm ci': only-package-commits.mjs resolves its"
      "@semantic-release/commit-analyzer import from that node_modules, so -g does not work"
    )
  grep -qF 'build_local_proxy.py --print-version' "$DRIVER" ||
    probs+=(
      "expected the channel-tag bootstrap to derive the current line from"
      "build_local_proxy.py --print-version — semantic-release starts a tag line it cannot find at"
      "1.0.0 (lib/get-next-version.js), which would jump the Go modules from 0.2.x and put the"
      "very next breaking change over the v2 module-path cliff"
    )
  if [ "${#probs[@]}" -eq 0 ]; then
    ok "go-release.yml is dispatchable, rehearsable, and runs the config the way the lane requires"
  else
    no "go-release.yml is dispatchable, rehearsable, and runs the config the way the lane requires" \
      "${probs[@]}"
  fi

  # Both lanes that run semantic-release push commits to main. Concurrent
  # pushes race into non-fast-forward rejections, so they must serialise.
  go_group="$(grep -A2 -E '^concurrency:' "$DRIVER" | grep -E '^[[:space:]]*group:' | head -1 | awk '{print $2}')"
  pd_group="$(grep -A2 -E '^concurrency:' "$WORKFLOWS/pubdev-release.yml" 2>/dev/null | grep -E '^[[:space:]]*group:' | head -1 | awk '{print $2}')"
  if [ -n "$go_group" ] && [ "$go_group" = "$pd_group" ]; then
    ok "go-release.yml shares pubdev-release.yml's concurrency group ($go_group) so the two never push to main at once"
  else
    no "go-release.yml shares pubdev-release.yml's concurrency group so the two never push to main at once" \
      "go-release.yml: '${go_group:-<none>}', pubdev-release.yml: '${pd_group:-<none>}'" \
      "release.yml dispatches both within a second of each other and each runs semantic-release," \
      "whose @semantic-release/git step pushes a commit to main"
  fi
else
  no "go-release.yml exists" \
    "the Go module line has a version but nothing computes the next one, so the tags are only" \
    "ever cut at whatever a human last wrote into the go.mod files (#361)"
fi

# release.yml must dispatch it, guarded on a release actually having been cut.
# `--ref main`, NOT the vX.Y.Z tag the npm/C++ channels use: those build a
# released tree, this one RUNS semantic-release, whose @semantic-release/git
# step pushes commits and tags to a BRANCH.
if grep -qF 'gh workflow run go-release.yml --ref main' "$RELEASE"; then
  ok "release.yml dispatches go-release.yml (--ref main, the branch semantic-release releases from)"
else
  no "release.yml dispatches go-release.yml (--ref main, the branch semantic-release releases from)" \
    "expected a step running: gh workflow run go-release.yml --ref main" \
    "a push-triggered driver cannot substitute: release.yml's own semantic-release commit carries" \
    "[skip ci], which suppresses the whole workflow run (#361)"
fi

line="$(grep -nF 'gh workflow run go-release.yml --ref' "$RELEASE" | head -1 | cut -d: -f1)"
if [ -n "$line" ]; then
  start=$((line - 8))
  [ "$start" -lt 1 ] && start=1
  if sed -n "${start},${line}p" "$RELEASE" |
    grep -qF "if: steps.semrel.outputs.released_version != ''"; then
    ok "the go-release.yml dispatch is guarded on released_version != ''"
  else
    no "the go-release.yml dispatch is guarded on released_version != ''" \
      "an unguarded dispatch fires on every push to main, releasing or not"
  fi
else
  no "the go-release.yml dispatch is guarded on released_version != ''" \
    "no dispatch line for go-release.yml to guard"
fi

# release.yml must NOT also dispatch the tagging workflow directly. It did until
# this lane existed, and that dispatch was an unconditional no-op: it re-ran the
# tagger at whatever version the go.mod files already carried, which is exactly
# the state that reads green while shipping nothing.
if sed 's/#.*$//' "$RELEASE" | grep -qE 'workflow run tag-go-modules\.yml|--workflow tag-go-modules\.yml'; then
  no "release.yml no longer dispatches tag-go-modules.yml directly" \
    "the tagger is now dispatched by go.releaserc.json's publishCmd, pinned to the channel tag" \
    "whose commit carries the bumped go.mod files; a second, version-less dispatch from release.yml" \
    "re-runs it at the OLD version on every release and reports success for doing nothing"
else
  ok "release.yml no longer dispatches tag-go-modules.yml directly"
fi

# ── 5. Exactly one dispatcher for the tagging workflow. ───────────────────
dispatchers=()
for f in "$WORKFLOWS"/*.yml "$CONFIGS"/*.json; do
  [ -f "$f" ] || continue
  [ "$(basename "$f")" = "tag-go-modules.yml" ] && continue
  sed 's/#.*$//' "$f" | grep -qE 'workflow run tag-go-modules\.yml|--workflow tag-go-modules\.yml' &&
    dispatchers+=("$(basename "$f")")
done
if [ "${#dispatchers[@]}" -eq 1 ] && [ "${dispatchers[0]}" = "go.releaserc.json" ]; then
  ok "exactly one place dispatches tag-go-modules.yml, and it is go.releaserc.json's publishCmd"
else
  no "exactly one place dispatches tag-go-modules.yml, and it is go.releaserc.json's publishCmd" \
    "found: ${dispatchers[*]:-<none>}" \
    "two dispatchers cut the same tags twice (the second is a no-op that reports success); none" \
    "means the tags are never cut at all"
fi

# ── 6. tag_go_modules.sh is the single tagging path. ──────────────────────
# Its all-or-nothing invariant — six tags on ONE commit, a half-tagged set
# refused, idempotent when they all exist — only holds if every
# `go/<module>/vX.Y.Z` tag in existence went through it. A second tagger with
# its own logic (an inline `git tag` in a workflow, a helper script) can publish
# a module set the proxy will serve forever: tags are immutable once fetched
# (https://go.dev/ref/mod#version-queries).
if [ -f "$TAGSH" ]; then
  ok "tools/go-module-proxy/tag_go_modules.sh exists (the single tagging path)"
else
  no "tools/go-module-proxy/tag_go_modules.sh exists (the single tagging path)" \
    "the all-or-nothing tag invariant lives in that script"
fi
strays=()
for f in "$WORKFLOWS"/*.yml "$ROOT"/tools/go-module-proxy/*.sh "$ROOT"/tools/release/*.sh; do
  [ -f "$f" ] || continue
  [ "$(basename "$f")" = "tag_go_modules.sh" ] && continue
  [ "$(basename "$f")" = "check_go_release_wiring.sh" ] && continue
  sed 's/#.*$//' "$f" | grep -qE 'git tag +"?go/' && strays+=("$(basename "$f")")
done
if [ "${#strays[@]}" -eq 0 ]; then
  ok "nothing but tag_go_modules.sh creates a go/<module>/vX.Y.Z tag"
else
  no "nothing but tag_go_modules.sh creates a go/<module>/vX.Y.Z tag" \
    "also tags go/ refs: ${strays[*]}" \
    "a second tagger can publish a half-resolvable module set, and Go module tags are immutable"
fi

# ── 7. The v2 cliff. ──────────────────────────────────────────────────────
# From major 2 on Go requires a /vN suffix on the module PATH
# (https://go.dev/ref/mod#major-version-suffixes). These paths carry none, so a
# computed 2.0.0 must stop the release loudly rather than tag a module set no
# consumer can import. semantic-release computes semver.inc(last, type), so the
# day a `feat!` lands on a 1.x line this is the only thing standing between the
# repo and six unusable tags.
if [ -f "$BUMP" ]; then
  v2probs=()
  grep -qF 'major-version-suffixes' "$BUMP" ||
    v2probs+=("expected the refusal to cite https://go.dev/ref/mod#major-version-suffixes")
  grep -qF -- '--check-next' "$BUMP" ||
    v2probs+=(
      "expected a --check-next mode: the refusal must be reachable from verifyRelease (which runs"
      "under --dry-run) and not only from the prepare-time rewrite, or a rehearsal cannot see it"
    )
  if [ "${#v2probs[@]}" -eq 0 ]; then
    ok "bump_go_modules.sh refuses a major >= 2 and exposes that refusal to verifyRelease"
  else
    no "bump_go_modules.sh refuses a major >= 2 and exposes that refusal to verifyRelease" "${v2probs[@]}"
  fi
else
  no "tools/go-module-proxy/bump_go_modules.sh exists" "the lane has nothing to move the version with"
fi

# ── 8. tag-go-modules.yml keeps the reachable trigger shape. ──────────────
if [ -f "$TAGGER" ]; then
  if grep -qE '^[[:space:]]*workflow_dispatch:' "$TAGGER"; then
    ok "tag-go-modules.yml declares a workflow_dispatch trigger"
  else
    no "tag-go-modules.yml declares a workflow_dispatch trigger" \
      "gh workflow run cannot invoke a workflow that does not opt into workflow_dispatch"
  fi
  if grep -qE '^[[:space:]]*push:' "$TAGGER"; then
    no "tag-go-modules.yml is not push-triggered" \
      "semantic-release's commit carries [skip ci], which suppresses the ENTIRE workflow run for a" \
      "push trigger — no run row is even created, so the dead channel reads as 'nothing red' (#361)"
  else
    ok "tag-go-modules.yml is not push-triggered"
  fi
else
  no "tag-go-modules.yml exists" "the Go lane has no tagger"
fi

# ── 9. Single owner: no other release driver may run this config. ─────────
owners=()
for wf in "$WORKFLOWS"/*.yml; do
  [ -f "$wf" ] || continue
  [ "$(basename "$wf")" = "go-release.yml" ] && continue
  grep -qE '^[[:space:]]*go[[:space:]]*$' "$wf" && owners+=("$(basename "$wf")")
done
if [ "${#owners[@]}" -eq 0 ]; then
  ok "no other workflow lists 'go' in a release-config loop"
else
  no "no other workflow lists 'go' in a release-config loop" \
    "also drives it: ${owners[*]}" \
    "two drivers for one lane cut duplicate tags and double-bump the module line"
fi

# ── 10. The guards are wired into CI. ─────────────────────────────────────
if grep -qF 'tools/release/check_go_release_wiring.sh' "$CI"; then
  ok "ci.yml runs this guard"
else
  no "ci.yml runs this guard" "a guard nothing invokes is not a guard"
fi

if grep -qF 'tools/test/test_bump_go_modules.sh' "$CI"; then
  ok "ci.yml runs the bump script's self-test (idempotency, refusals, --check-next)"
else
  no "ci.yml runs the bump script's self-test (idempotency, refusals, --check-next)" \
    "the bump only otherwise runs inside a release, so without a PR-time self-test its first" \
    "exercise would be the day it had to get a cross-file version edit right"
fi

if grep -qF 'tools/test/test_tag_go_modules.sh' "$CI"; then
  ok "ci.yml runs the tagger's self-test"
else
  no "ci.yml runs the tagger's self-test" \
    "the tagging logic used to live inline in a dispatch-only workflow and failed on its first" \
    "live run with 'fatal: too many arguments' (run 33939440446)"
fi

# ── 11. The tagger's header tells the post-#623 truth. ────────────────────
# tag-go-modules.yml is the file an operator lands on when a tag cut goes wrong,
# and its header is the only explanation of the lane it carries. It described a
# world that stopped existing when #623 landed: "Bumping the Go modules is
# therefore a normal PR that runs bump_go_modules.sh; this workflow then cuts
# the tags on the next release" (the bump is a prepareCmd now), "release.yml
# dispatches this explicitly" (leg 4 above asserts it does NOT), and an offer to
# hand-dispatch for "the one-time backfill" (done in #618). Stale prose in a
# release file is not cosmetic — it is the instruction a human follows at 2am,
# and nothing else in this guard reads comments. So this one does (#627).
if [ -f "$TAGGER" ]; then
  header="$(sed -n '1,/^on:/p' "$TAGGER" | grep -E '^[[:space:]]*#')"
  header_lines="$(printf '%s\n' "$header" | grep -c .)"
  case "$header_lines" in
  *[!0-9]*) header_lines=0 ;;
  esac
  if [ "$header_lines" -lt 10 ]; then
    # A vanished header would make every forbidden-phrase check below vacuously
    # true, which is the shape this guard refuses everywhere else.
    no "tag-go-modules.yml carries an explanatory header (>= 10 comment lines before 'on:')" \
      "found $header_lines — with no header there is nothing to keep honest, and the prose" \
      "assertions below would pass by being empty"
  else
    hprobs=()
    printf '%s\n' "$header" | grep -qE 'release\.yml dispatches' &&
      hprobs+=(
        "says \"release.yml dispatches\" — it does not, and leg 4 of this guard fails if it ever"
        "does again. Since #623 the only dispatcher is .github/release/go.releaserc.json's"
        "publishCmd, pinned to the go-modules/vX.Y.Z channel tag."
      )
    printf '%s\n' "$header" | grep -qE 'cuts the tags on the next release' &&
      hprobs+=(
        "still describes the bump as a human PR that this workflow tags \"on the next release\";"
        "since #623 the bump is go.releaserc.json's prepareCmd and the tags are cut by the"
        "publishCmd of the same release that made it"
      )
    printf '%s\n' "$header" | grep -qE 'one-time backfill' &&
      hprobs+=("still offers the one-time backfill hand-dispatch; that backfill happened in #618")
    printf '%s\n' "$header" | grep -qF 'go.releaserc.json' ||
      hprobs+=("never names .github/release/go.releaserc.json, which is what actually dispatches it")
    printf '%s\n' "$header" | grep -qF 'publishCmd' ||
      hprobs+=("never names the publishCmd that dispatches it")
    if [ "${#hprobs[@]}" -eq 0 ]; then
      ok "tag-go-modules.yml's header describes the post-#623 lane ($header_lines comment lines)"
    else
      no "tag-go-modules.yml's header describes the post-#623 lane" "${hprobs[@]}"
    fi
  fi
fi

# ── 12. The dispatch is AWAITED, by a poller with a bounded budget. ───────
# Leg 2 pins that publishCmd calls the poller. This pins that the poller is a
# poller: a script that shells out to `gh workflow run` and returns would
# satisfy that grep and change nothing.
AWAIT="$ROOT/tools/release/await_workflow_run.py"
if [ -f "$AWAIT" ]; then
  aprobs=()
  grep -qF -- '--self-test' "$AWAIT" ||
    aprobs+=(
      "expected a --self-test mode: this code runs only inside a real release, so without one its"
      "first exercise would be the day it had to be right (the resolve_published.py precedent, #568)"
    )
  grep -qF 'BUDGET_SECONDS' "$AWAIT" ||
    aprobs+=("expected a bounded polling budget — an unbounded wait hangs the release job until its timeout")
  grep -qF 'INTERVAL_SECONDS' "$AWAIT" ||
    aprobs+=("expected an explicit poll interval")
  grep -qF 'def baseline_run_id(' "$AWAIT" ||
    aprobs+=(
      "expected the poller to require a run STRICTLY NEWER than a pre-dispatch baseline"
      "(newest_matching/await_run take after_run_id, captured before the dispatch, #656):"
      "GitHub creates the dispatched run's row seconds AFTER accepting the dispatch, so the first"
      "poll sees only rows that already existed — and docs/RELEASE.md documents a manual"
      "re-dispatch on that same channel tag, whose stale success would read as this release's"
      "tag cut"
    )
  grep -qF 'conclusion' "$AWAIT" ||
    aprobs+=(
      "expected the poller to read the dispatched run's CONCLUSION: waiting for a run to reach"
      "\"completed\" and then exiting 0 regardless of HOW it completed is the fire-and-forget bug"
      "with extra steps"
    )
  if [ "${#aprobs[@]}" -eq 0 ]; then
    ok "await_workflow_run.py polls a bounded budget and gates on the run's conclusion"
  else
    no "await_workflow_run.py polls a bounded budget and gates on the run's conclusion" "${aprobs[@]}"
  fi
else
  no "tools/release/await_workflow_run.py exists (the awaited dispatch, #627)" \
    "publishCmd's dispatch is fire-and-forget without it: 'gh workflow run' returns as soon as" \
    "GitHub accepts the request, so a tagger run that fails, is cancelled, or never starts leaves" \
    "the go-release run green"
fi

# ── 13. The Go lane has an OUTCOME alarm, not just wiring guards. ─────────
# Everything above is static: it asks whether the lane is SHAPED to ship. The
# pub.dev lane learned the hard way (#551) that a perfectly-shaped, perfectly-
# green lane can still stop shipping, and the only thing that sees it is a
# periodic comparison of the live registry against main. Go's registry is
# proxy.golang.org; this is its equivalent (#627).
FRESH="$ROOT/tools/release/check_go_freshness.sh"
FRESHWF="$WORKFLOWS/go-freshness.yml"
if [ -f "$FRESH" ]; then
  fprobs=()
  grep -qF -- '--self-test' "$FRESH" ||
    fprobs+=("expected a --self-test mode so the classifier is exercised on every PR, offline")
  grep -qF 'go list -m -versions' "$FRESH" ||
    fprobs+=(
      "expected the live leg to ask the proxy with 'go list -m -versions' — the one documented way"
      "to list a module's versions with no main module (https://go.dev/ref/mod#commands-outside)"
    )
  grep -qF 'GOWORK=off' "$FRESH" ||
    fprobs+=(
      "expected GOWORK=off: inside go/ the workspace's replace pins resolve the module locally and"
      "'go list -m -versions' prints the module path with an EMPTY version list and exits 0 — a"
      "silent nothing that would read as a clean sweep"
    )
  if [ "${#fprobs[@]}" -eq 0 ]; then
    ok "check_go_freshness.sh asks proxy.golang.org the right question, hermetically"
  else
    no "check_go_freshness.sh asks proxy.golang.org the right question, hermetically" "${fprobs[@]}"
  fi
else
  no "tools/release/check_go_freshness.sh exists (the proxy.golang.org alarm, #627)" \
    "the Go lane has wiring guards and no outcome guard: nothing anywhere compares the version the" \
    "six go.mod files name against the versions proxy.golang.org actually serves, so a tagger that" \
    "stops cutting tags is invisible until a consumer reports an unknown revision"
fi

if [ -f "$FRESHWF" ]; then
  wprobs=()
  grep -qE '^[[:space:]]*schedule:' "$FRESHWF" ||
    wprobs+=("expected a schedule: trigger — an alarm nothing fires is not an alarm")
  grep -qE '^[[:space:]]*workflow_dispatch:' "$FRESHWF" ||
    wprobs+=("expected workflow_dispatch so the alarm can be rehearsed on a branch before it is trusted")
  grep -qF 'check_go_freshness.sh --self-test' "$FRESHWF" ||
    wprobs+=(
      "expected the workflow to run the classifier's self-test BEFORE the live comparison"
      "(pubdev-freshness.yml's shape): a clean network run and a broken comparison look identical"
    )
  grep -qE 'fetch-depth:[[:space:]]*0' "$FRESHWF" ||
    wprobs+=(
      "expected fetch-depth: 0 — the lag window is measured from the go/<module>/vX.Y.Z tag's own"
      "date, and a shallow clone carries no tags"
    )
  if [ "${#wprobs[@]}" -eq 0 ]; then
    ok "go-freshness.yml is scheduled, rehearsable, and self-tests before it trusts the network"
  else
    no "go-freshness.yml is scheduled, rehearsable, and self-tests before it trusts the network" "${wprobs[@]}"
  fi
else
  no ".github/workflows/go-freshness.yml exists (weekly + dispatch)" \
    "pubdev-freshness.yml is 'the alarm #551 lacked'; the Go lane has no equivalent, so the only" \
    "signal after a release is that the automation RAN"
fi

if grep -qF 'tools/release/check_go_freshness.sh --self-test' "$CI"; then
  ok "ci.yml runs the Go freshness classifier's self-test"
else
  no "ci.yml runs the Go freshness classifier's self-test" \
    "the live legs only run on a schedule, so without a PR-gated self-test a classifier that" \
    "silently stopped classifying would report a dead lane as healthy — the #551 failure exactly"
fi

if grep -qF 'tools/release/await_workflow_run.py --self-test' "$CI"; then
  ok "ci.yml runs the awaited-dispatch poller's self-test"
else
  no "ci.yml runs the awaited-dispatch poller's self-test" \
    "the poller only runs inside a real release; a PR-time self-test is the only thing that can" \
    "exercise its budget loop and its conclusion classification before it matters"
fi

total=$((pass + fail))
# Positive floor (#439/#444): an exit code plus a zero failure count cannot tell
# "all passed" from "nothing ran".
MIN=20
case "$pass$fail$total" in
*[!0-9]*)
  echo "::error::Go release wiring guard produced a non-numeric tally"
  exit 1
  ;;
esac
if [ "$total" -lt "$MIN" ]; then
  echo "::error::Go release wiring guard ran $total cases, expected at least $MIN — the sweep itself is broken"
  exit 1
fi
echo "Results: $pass passed, $fail failed, $total total"
[ "$fail" -eq 0 ] || exit 1
