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
  grep -qF 'gh workflow run tag-go-modules.yml --ref go-modules/v${nextRelease.version}' "$CFG" ||
    probs+=(
      "expected publishCmd: gh workflow run tag-go-modules.yml --ref go-modules/v\${nextRelease.version}"
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
if sed 's/#.*$//' "$RELEASE" | grep -qF 'gh workflow run tag-go-modules.yml'; then
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
  sed 's/#.*$//' "$f" | grep -qF 'gh workflow run tag-go-modules.yml' &&
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

total=$((pass + fail))
# Positive floor (#439/#444): an exit code plus a zero failure count cannot tell
# "all passed" from "nothing ran".
MIN=15
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
