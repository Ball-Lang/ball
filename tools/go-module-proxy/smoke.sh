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
# This script builds the exact proxy tree the `go/<module>/v0.1.0` tags will
# produce (tools/go-module-proxy/build_local_proxy.py, from the tracked files of
# the current checkout) and then runs the two things a real consumer does:
#
#   leg 1  every module builds standalone, copied out of the monorepo with no
#          go.work and no siblings, resolving its dependencies off the proxy;
#   leg 2  `go install github.com/ball-lang/ball/go/cli/cmd/ball@v0.1.0` into a
#          clean GOPATH/GOMODCACHE, and the installed binary actually runs.
#
# Both legs are gating: leg 1 asserts fail == 0 over a non-empty module set, and
# leg 2 asserts the installed `ball` runs `check` on a real conformance fixture.
# Before the go.mod rewrite this PR makes, leg 1 failed 4/6 with "replacement
# directory ../<dep> does not exist" and leg 2 failed with "The go.mod file for
# the module providing named packages contains one or more replace directives."
#
# Usage: tools/go-module-proxy/smoke.sh   (from anywhere; needs go + python3)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
version="$(python3 "$here/build_local_proxy.py" --print-version)"
fixture="tests/conformance/100_complex_control_flow.ball.json"

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
echo "go module external-consumer smoke: OK ($pass/$total modules, ball installed and ran)"
