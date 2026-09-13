#!/usr/bin/env bash
#
# External-consumer resolution smoke for the six Ball Go modules (issue #361).
#
# Every other Go gate in this repo (`go build` / `go vet` / `go test` / `gofmt`)
# runs inside go/go.work, where the workspace pins each intra-repo dependency
# back to the local tree. That vantage point is structurally blind to how an
# outside consumer resolves these modules: through a module proxy, one nested
# module at a time, with no workspace, no sibling directories, and no `replace`
# directives (`go install` rejects a module whose go.mod carries any).
#
# This script builds the exact proxy tree the `go/<module>/vX.Y.Z` tags will
# produce (tools/go-module-proxy/build_local_proxy.py, from the tracked files of
# the current checkout) and then runs the two things a real consumer does:
#
#   leg 1  every module builds standalone, copied out of the monorepo with no
#          go.work and no siblings, resolving its dependencies off the proxy;
#   leg 2  `go install github.com/ball-lang/ball/go/cli/cmd/ball@vX.Y.Z` into a
#          clean GOPATH/GOMODCACHE, and the installed binary actually runs.
#
# Both legs are gating: leg 1 asserts fail == 0 over a non-empty module set, and
# leg 2 asserts the installed `ball` actually EXECUTES — `run` on a conformance
# fixture byte-matching its committed golden, and the cli-core verbs `info` and
# `version` likewise. Before the go.mod rewrite of #361, leg 1 failed 4/6 with
# "replacement directory ../<dep> does not exist" and leg 2 failed with "The
# go.mod file for the module providing named packages contains one or more
# replace directives."
#
# The version is never spelled here: it comes from build_local_proxy.py
# --print-version, the same call .github/workflows/tag-go-modules.yml makes, and
# that script now refuses any `--version` that disagrees with what the go.mod
# files name. So the proxy this smoke proves is, by construction, the proxy the
# tags will publish — a half-bumped tree fails here rather than synthesizing a
# resolvable proxy at a version no tag will ever carry.
#
# Leg 2's behavioural assertions are the #586 gate. Until #586 the leg only ran
# `--help` and `check`, which need neither the self-hosted engine nor the
# compiled CLI core — so a `go install`-acquired `ball` that could not run a
# single program, and answered `info`/`validate`/`tree`/`version` with an
# exit-1 "rebuild with -tags …" hint, read as a full pass. The two generated
# artifacts those verbs need (go/engine/compiled/compiled_engine.go,
# go/cli/compiled/compiled_cli.go) were gitignored and build-tag-gated, and the
# module a proxy serves is the repository AT THE TAG — so they simply were not
# in it, and `go install` gives a consumer no way to pass `-tags` anyway.
#
# Usage: tools/go-module-proxy/smoke.sh   (from anywhere; needs go + python3)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
version="$(python3 "$here/build_local_proxy.py" --print-version)"
fixture="tests/conformance/100_complex_control_flow.ball.json"
# Fixtures leg 2 EXECUTES through the installed binary, byte-compared against the
# same goldens go/engine's conformance sweep and go/cli's tests use.
run_fixtures="100_complex_control_flow 101_simple_class"
info_fixture="100_complex_control_flow"

work="$(mktemp -d)"
proxy_url="$(python3 "$here/build_local_proxy.py" "$work/proxy" --version "$version")"
echo "local module proxy: $proxy_url ($version)"

# The local proxy answers for github.com/ball-lang/ball/go/*; everything else
# (google.golang.org/protobuf) falls through to the public proxy on 404.
# GOSUMDB=off because these versions are not on sum.golang.org until the tags
# are pushed (GOSUMDB is the only knob that does that job in a modules-era
# toolchain — the pre-modules GONOSUMDB/GONOSUMCHECK are no-ops and are
# deliberately not set here); GOPRIVATE is cleared so an ambient value can't
# redirect resolution away from the proxy under test, and GOFLAGS likewise.
export GOPROXY="$proxy_url,https://proxy.golang.org,direct"
export GOSUMDB=off
export GOPRIVATE=
export GOWORK=off
export GOFLAGS=

# ── leg 1: every module builds standalone off the proxy ──────────────────────
#
# Leg 1 gets its own EMPTY module cache, exactly as leg 2 does. The intra-repo
# modules are always resolved at the SAME version string (the Go module line —
# it names a tag, not this commit), so a warm GOMODCACHE that already holds
# `go/<m>@vX.Y.Z` from an earlier run serves that OLD content and the sweep
# silently measures stale code: a false RED when the tree just gained an API the
# cached copy lacks, and — the dangerous direction — a false GREEN when a change
# breaks external resolution but the cache still holds a copy that builds.
# `actions/setup-go` restores GOMODCACHE across CI runs keyed only on the
# committed go.sum files, so this bit CI as well as local runs.
gohome1="$(mktemp -d)"
export GOMODCACHE="$gohome1/pkg/mod"
pass=0
fail=0
total=0
for dir in "$root"/go/*/; do
  [ -f "$dir/go.mod" ] || continue
  m="$(basename "$dir")"
  total=$((total + 1))
  iso="$(mktemp -d)"
  cp -r "$dir" "$iso/$m"
  if out="$(cd "$iso/$m" && GOFLAGS=-mod=mod go build ./... 2>&1)"; then
    echo "OK   go/$m"
    pass=$((pass + 1))
  else
    echo "FAIL go/$m"
    echo "$out" | sed 's/^/       /' | head -10
    fail=$((fail + 1))
  fi
done
echo "isolation: pass=$pass fail=$fail total=$total"
echo "Results: $pass passed, $fail failed, $total total"

case "$total" in
  ''|*[!0-9]*) echo "smoke: module total '$total' is not a bare integer" >&2; exit 1 ;;
esac
case "$fail" in
  ''|*[!0-9]*) echo "smoke: module fail count '$fail' is not a bare integer" >&2; exit 1 ;;
esac
if [ "$total" -lt 1 ]; then
  echo "smoke: swept 0 modules — the sweep itself is broken" >&2
  exit 1
fi
if [ "$fail" -ne 0 ]; then
  echo "smoke: $fail/$total Go modules do not build outside the monorepo" >&2
  exit 1
fi

# ── leg 2: go install into a clean GOPATH, then run the binary ───────────────
gohome="$(mktemp -d)"
export GOPATH="$gohome/gopath"
export GOMODCACHE="$gohome/gopath/pkg/mod"
export GOBIN="$gohome/bin"
go install "github.com/ball-lang/ball/go/cli/cmd/ball@$version"

ball="$GOBIN/ball"
[ -x "$ball" ] || ball="$GOBIN/ball.exe"
if [ ! -x "$ball" ]; then
  echo "smoke: go install produced no ball binary in $GOBIN" >&2
  exit 1
fi

help_out="$("$ball" --help)"
if [ -z "$help_out" ]; then
  echo "smoke: installed ball printed nothing for --help" >&2
  exit 1
fi

check_out="$("$ball" check "$root/$fixture")"
if [ -z "$check_out" ]; then
  echo "smoke: installed ball printed nothing for check $fixture" >&2
  exit 1
fi
echo "go install $version -> $ball"
echo "ball check $fixture -> $check_out"

# ── leg 2b: the installed binary EXECUTES (issue #586) ──────────────────────
#
# `check`/`compile`/`encode` above prove only that the binary starts and parses.
# The verbs a consumer actually reaches for — `run` and the cli-core reports —
# need the two generated artifacts (compiled_engine.go / compiled_cli.go), and
# those only reach a registry consumer if they are TRACKED: `go install` accepts
# no `-tags`, and the module the proxy serves is the repository at the tag. So
# this block is the end-to-end proof of #586, and it compares BYTES against the
# same goldens go/engine's conformance sweep and go/cli's parity gate use — not
# "produced some output", which an honest-failure stub could never satisfy but a
# wrong-output engine could.
#
# Normalization is CR-only (`tr -d '\r'`): the goldens are LF in the index but
# CRLF in a Windows worktree, and collapsing anything more (trailing newlines,
# whitespace) would let a real divergence pass.
ran=0
for stem in $run_fixtures; do
  golden="$root/tests/conformance/$stem.expected_output.txt"
  if [ ! -s "$golden" ]; then
    echo "smoke: golden $golden is missing or empty — the assertion would prove nothing" >&2
    exit 1
  fi
  if ! "$ball" run "$root/tests/conformance/$stem.ball.json" >"$work/$stem.run.out" 2>"$work/$stem.run.err"; then
    echo "smoke: installed ball could not RUN $stem — a go install-acquired ball must execute programs (#586)" >&2
    sed 's/^/       /' "$work/$stem.run.err" >&2
    exit 1
  fi
  if ! diff -u <(tr -d '\r' <"$golden") <(tr -d '\r' <"$work/$stem.run.out"); then
    echo "smoke: ball run $stem diverged from its golden" >&2
    exit 1
  fi
  echo "ball run $stem -> matches tests/conformance/$stem.expected_output.txt"
  ran=$((ran + 1))
done

# cli-core: one program-taking verb against its Dart golden, plus `version`
# (which takes no program). Both take the honest-failure path without the
# compiled CLI core, so this is the other half of the #586 proof.
info_golden="$root/tests/cli_core_goldens/$info_fixture.info.txt"
if [ ! -s "$info_golden" ]; then
  echo "smoke: golden $info_golden is missing or empty" >&2
  exit 1
fi
if ! "$ball" info "$root/tests/conformance/$info_fixture.ball.json" >"$work/info.out" 2>"$work/info.err"; then
  echo "smoke: installed ball could not run the cli-core verb 'info' (#586)" >&2
  sed 's/^/       /' "$work/info.err" >&2
  exit 1
fi
if ! diff -u <(tr -d '\r' <"$info_golden") <(tr -d '\r' <"$work/info.out"); then
  echo "smoke: ball info $info_fixture diverged from the Dart golden" >&2
  exit 1
fi
echo "ball info $info_fixture -> matches tests/cli_core_goldens/$info_fixture.info.txt"
ran=$((ran + 1))

if ! version_out="$("$ball" version 2>"$work/version.err")"; then
  echo "smoke: installed ball could not run the cli-core verb 'version' (#586)" >&2
  sed 's/^/       /' "$work/version.err" >&2
  exit 1
fi
case "$version_out" in
  "ball "?*) ;;
  *) echo "smoke: ball version printed '$version_out', want 'ball <version>'" >&2; exit 1 ;;
esac
echo "ball version -> $version_out"
ran=$((ran + 1))

# Positive floor: an empty fixture list or a skipped loop must never read green.
if [ "$ran" -lt 4 ]; then
  echo "smoke: executed only $ran behavioural assertions, want >= 4" >&2
  exit 1
fi
echo "Behaviour: $ran executions passed, 0 failed, $ran total"
echo "go module external-consumer smoke: OK ($pass/$total modules, ball installed and ran)"
