#!/usr/bin/env bash
# Freshness guard for the Go module release lane (#627).
#
# WHY THIS EXISTS: every Go release guard before it is STATIC. `check_release_
# dispatch_wiring.sh` asks whether the channel's trigger chain *can* fire;
# `check_go_release_wiring.sh` asks whether the lane is *shaped* so it fires
# without a human. Neither can see a perfectly-wired, perfectly-green lane that
# has simply stopped shipping — which is exactly what #551 reported for pub.dev
# and #361 reported for Go one level down: every automated part green, the
# channel shipping nothing, `go install …@latest` serving a version from months
# ago. `docs/RELEASE.md` calls `pubdev-freshness.yml` "the alarm #551 lacked".
# The Go lane had no equivalent: nothing anywhere compared the version the six
# `go/*/go.mod` files name against the versions `proxy.golang.org` actually
# serves.
#
# This does. One question, asked of the live proxy for every module in the
# workspace, with no hardcoded module list and no hardcoded version:
#
#     does proxy.golang.org list the version `main`'s go.mod files name?
#
# THE COMMAND, AND WHY EACH PART OF IT IS THERE (https://go.dev/ref/mod):
#
#   go list -m -versions <module path>
#     `-m` "causes go list to list modules instead of packages".
#     `-versions` "causes list to set the module's Versions field to a list of
#     all known versions of that module, ordered according to semantic
#     versioning, lowest to highest. The flag also changes the default output
#     format to display the module path followed by the space-separated version
#     list." Under "Module commands outside a module", `go list -m` is called
#     out by name: "Explicit version queries are required for most arguments,
#     EXCEPT when the -versions flag is used" — which is what makes this
#     answerable with no main module at all, from a scratch directory.
#
#   GOWORK=off      Load-bearing, and measured rather than assumed. "If GOWORK
#                   is set to off, the command will be in a single-module
#                   context. If it is empty or not provided, the command will
#                   search the current working directory, and then successive
#                   parent directories, for a file go.work." Run anywhere under
#                   go/, the workspace's `replace … => ./<m>` pins resolve the
#                   module locally and this command prints the module path with
#                   an EMPTY version list and exits 0 — a silent nothing that
#                   would read as a clean sweep. (That is also why an empty
#                   list is a hard UNKNOWN below, not an absence.)
#   GOFLAGS=-mod=mod  Hermetic, not decorative: "By default, if the go version
#                   in go.mod is 1.14 or higher and a vendor directory is
#                   present, the go command acts as if -mod=vendor were used",
#                   and -mod=vendor "will not use the network or the module
#                   cache". A stray vendored tree would otherwise stop this from
#                   asking the proxy anything.
#   GOPROXY=…       The proxy under test, named explicitly rather than inherited.
#   GONOPROXY= GONOSUMDB= GOPRIVATE=
#                   A developer-local GOPRIVATE sets the other two, and a
#                   matching pattern routes a path around GOPROXY entirely. The
#                   check must ask the PUBLIC proxy or say nothing at all.
#
# THE LAG WINDOW. `proxy.golang.org` does not serve a tag the instant it is
# pushed; its index lag was measured at ~25 minutes on 2026-09-05 and again on
# 2026-09-14. So a version the proxy does not yet list is only a failure if the
# tag carrying it is OLDER than MAX_LAG_MINUTES (default 60, an hour — more than
# twice the worst observation). A version whose tag does not exist at all is
# never lag: it is a tagger that did not run, and it fails immediately.
#
# WHICH TREE'S VERSION. The released line lives on `main`, and this guard is
# dispatchable on a branch (that is how it gets rehearsed before anyone trusts
# it). Reading the WORKING TREE's go.mod files on a branch would compare the
# proxy against an unreleased number and report a false alarm — or, worse, a
# false all-clear. So BALL_GO_VERSION_REF (the workflow passes origin/main)
# materialises that ref's `go/` + `tools/go-module-proxy/` into a scratch tree
# and derives the version there, through the SAME
# `build_local_proxy.py --print-version` entry point the tagger uses, so the
# four cross-file invariants are re-asserted on the tree being compared. Unset
# means "use the working tree", which is what the scheduled run on main wants;
# either way the source is printed, never silently chosen.
#
# WHERE IT RUNS: the live leg runs on a schedule
# (.github/workflows/go-freshness.yml, weekly + workflow_dispatch), NOT on every
# PR — a per-PR hard dependency on proxy.golang.org would redden unrelated work
# on a CDN hiccup, and the proxy does not change between two pushes of the same
# PR anyway. The comparison logic IS PR-gated, through `--self-test`, which
# drives every classification offline from ci.yml's `Proto Checks` job — so a
# guard that quietly stopped comparing anything cannot reach main.
#
# Usage:
#   bash tools/release/check_go_freshness.sh              # live check
#   bash tools/release/check_go_freshness.sh --self-test  # offline, no network
#
# Env: MAX_LAG_MINUTES     (default 60)
#      BALL_GO_VERSION_REF (default: the working tree)
#      GO_PROXY_URL        (default https://proxy.golang.org)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
MAX_LAG_MINUTES="${MAX_LAG_MINUTES:-60}"
GO_PROXY_URL="${GO_PROXY_URL:-https://proxy.golang.org}"

PY="python3"
command -v "$PY" >/dev/null 2>&1 || PY="python"
command -v "$PY" >/dev/null 2>&1 || {
  echo "::error::neither python3 nor python is on PATH — this guard needs one to classify"
  exit 1
}

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

# ── The classification, in one place, so --self-test exercises exactly the code
#    the live run uses. Prints `<verdict>\t<detail>`; verdict is one of
#    OK / LAG / MISSING / UNTAGGED / UNKNOWN.
#    Args: module want_version served_versions tag_age_minutes
#      served_versions  space-separated, exactly as `go list -m -versions` prints
#                       it after the module path; empty means the proxy answered
#                       with no versions at all.
#      tag_age_minutes  age of the go/<module>/<want_version> tag in minutes, or
#                       the literal "none" when that tag does not exist.
classify() {
  MAX_LAG_MINUTES="$MAX_LAG_MINUTES" "$PY" - "$@" <<'PY'
import os
import sys

module, want, served_raw, tag_age = sys.argv[1:5]
max_lag = int(os.environ["MAX_LAG_MINUTES"])

# Split on whitespace, never a substring test: `v0.2.0` must not be satisfied by
# `v0.2.01`, `v0.20.0` or `v0.2.0-rc1`. The proxy's answer is a token list and
# is compared as one.
served = served_raw.split()

if not want:
    print(f"UNKNOWN\t{module}: no module version was derived from the tree")
    sys.exit(0)

if want in served:
    print(f"OK\t{module}: proxy.golang.org serves {want} ({len(served)} versions listed)")
    sys.exit(0)

listed = " ".join(served) if served else "<none>"

if not served:
    # An empty version list is never "the module is new". `go list -m -versions`
    # prints the module path and nothing else in exactly two situations: the
    # command ran in workspace/single-module context where the path resolves
    # locally (GOWORK), or the proxy answered with an empty @v/list. Both mean
    # "this sweep learned nothing", and neither may read as an absence we can
    # reason about.
    print(
        f"UNKNOWN\t{module}: the proxy listed NO versions at all, so this says nothing about "
        f"{want}. A local resolution (go.work in scope) prints exactly this."
    )
    sys.exit(0)

if tag_age == "none":
    print(
        f"UNTAGGED\t{module}: the tree names {want} but no go/…/{want} tag exists; "
        f"proxy.golang.org serves {listed}"
    )
    sys.exit(0)

try:
    age = int(tag_age)
except ValueError:
    print(f"UNKNOWN\t{module}: unreadable tag age {tag_age!r} for {want}")
    sys.exit(0)

if age < 0:
    print(f"UNKNOWN\t{module}: the go/…/{want} tag is dated {-age} minutes in the FUTURE")
    sys.exit(0)

if age <= max_lag:
    print(
        f"LAG\t{module}: proxy.golang.org does not list {want} yet, but its tag is only "
        f"{age} min old (limit {max_lag}); the proxy index lags a push by ~25 min"
    )
else:
    print(
        f"MISSING\t{module}: proxy.golang.org serves {listed} and NOT {want}, whose tag is "
        f"{age} min old (limit {max_lag})"
    )
PY
}

# ─────────────────────────────────────────────────────────────────────────────
# Self-test: the comparison logic, offline, on synthetic inputs. Runs on every
# PR. A guard whose classifier silently stopped classifying would otherwise be
# indistinguishable from a healthy proxy.
# ─────────────────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--self-test" ]; then
  echo "== self-test (offline; MAX_LAG_MINUTES=$MAX_LAG_MINUTES) =="
  expect() {
    local want="$1" label="$2"
    shift 2
    local got
    got="$(classify "$@" | cut -f1)"
    if [ "$got" = "$want" ]; then
      ok "$label -> $want"
    else
      no "$label -> $want" "classifier returned '$got'"
    fi
  }

  # The healthy steady state: the proxy lists the version the tree names.
  expect OK "proxy serves the tree's version" \
    runtime v0.2.0 "v0.1.0 v0.2.0" 4320
  expect OK "the version is the only one listed" \
    runtime v0.1.0 "v0.1.0" 60000
  # Fresh tag the proxy has not indexed yet — the ~25 min lag measured on
  # 2026-09-05 and 2026-09-14. Tolerated.
  expect LAG "fresh tag, proxy still indexing (25 min)" \
    cli v0.3.0 "v0.1.0 v0.2.0" 25
  expect LAG "boundary: exactly MAX_LAG_MINUTES old" \
    cli v0.3.0 "v0.1.0 v0.2.0" "$MAX_LAG_MINUTES"
  expect MISSING "boundary: one minute past MAX_LAG_MINUTES" \
    cli v0.3.0 "v0.1.0 v0.2.0" "$((MAX_LAG_MINUTES + 1))"
  # The failure this guard exists for: a tag cut days ago the proxy never
  # served, or a tagger that stopped running while the line moved.
  expect MISSING "tag cut three days ago, proxy never served it" \
    engine v0.3.0 "v0.1.0 v0.2.0" 4320
  # Worse: the version moved on main and no tag was ever cut for it. Not lag —
  # the tagger did not run.
  expect UNTAGGED "tree moved, no tag at all" \
    engine v0.4.0 "v0.1.0 v0.2.0" none
  # The GOWORK trap, verified by hand: inside go/ the command prints the module
  # path and NO versions, exit 0. That must never read as a clean sweep.
  expect UNKNOWN "proxy listed no versions at all (the go.work shape)" \
    shared v0.2.0 "" 4320
  expect UNKNOWN "unreadable tag age" \
    shared v0.2.0 "v0.2.0x" "not-a-number"
  expect UNKNOWN "tag dated in the future" \
    shared v0.3.0 "v0.1.0" -5
  expect UNKNOWN "no version derived from the tree" \
    shared "" "v0.1.0 v0.2.0" 4320
  # Version matching is token-wise, never substring: every one of these SHARES a
  # prefix with the wanted version and satisfies none of it.
  expect MISSING "v0.2.0 is not satisfied by v0.2.01 / v0.20.0" \
    compiler v0.2.0 "v0.2.01 v0.20.0" 4320
  expect MISSING "v0.2.0 is not satisfied by a prerelease of it" \
    compiler v0.2.0 "v0.1.0 v0.2.0-rc1" 4320
  expect OK "a trailing-token match is a real match" \
    compiler v0.2.0 "v0.1.0 v0.1.9 v0.2.0" 4320

  total=$((pass + fail))
  MIN=12
  case "$pass$fail$total" in
  *[!0-9]*)
    echo "::error::Go freshness self-test produced a non-numeric tally"
    exit 1
    ;;
  esac
  if [ "$total" -lt "$MIN" ]; then
    echo "::error::Go freshness self-test ran $total cases, expected at least $MIN — the sweep itself is broken"
    exit 1
  fi
  echo "Results: $pass passed, $fail failed, $total total"
  [ "$fail" -eq 0 ] || exit 1
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Live check.
# ─────────────────────────────────────────────────────────────────────────────
command -v go >/dev/null 2>&1 || {
  echo "::error::go is not on PATH — the live leg asks the proxy with 'go list -m -versions'"
  exit 1
}

VERSION_REF="${BALL_GO_VERSION_REF:-}"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# ── The version under test, and the tree it came from. ────────────────────
if [ -n "$VERSION_REF" ]; then
  if ! git -C "$ROOT" rev-parse -q --verify "${VERSION_REF}^{commit}" >/dev/null; then
    echo "::error::BALL_GO_VERSION_REF=$VERSION_REF does not resolve to a commit in this clone; fetch it first (the workflow clones with fetch-depth: 0)"
    exit 1
  fi
  mkdir -p "$SCRATCH/tree"
  # Only the two paths --print-version reads. build_local_proxy.py derives its
  # repo root from its own location (parents[2]), so this layout makes it read
  # the materialised go/ and nothing from the working tree.
  git -C "$ROOT" archive "$VERSION_REF" go tools/go-module-proxy | tar -x -C "$SCRATCH/tree"
  VERSION_SOURCE="$VERSION_REF ($(git -C "$ROOT" rev-parse --short "${VERSION_REF}^{commit}"))"
  VERSION_TREE="$SCRATCH/tree"
else
  VERSION_SOURCE="the working tree"
  VERSION_TREE="$ROOT"
fi

version="$("$PY" "$VERSION_TREE/tools/go-module-proxy/build_local_proxy.py" --print-version)"
if [ -z "$version" ]; then
  echo "::error::build_local_proxy.py --print-version printed nothing for $VERSION_SOURCE — there is no version to compare the proxy against"
  exit 1
fi

echo "== Go module freshness (version $version from $VERSION_SOURCE; proxy $GO_PROXY_URL; MAX_LAG_MINUTES=$MAX_LAG_MINUTES) =="

now="$(date -u +%s)"
checked=0

# `go list` runs from a scratch directory with GOWORK=off so no go.mod or
# go.work anywhere above the repo can put it in a module context. See the header.
cd "$SCRATCH" || exit 1

for gomod in "$VERSION_TREE"/go/*/go.mod; do
  [ -f "$gomod" ] || continue
  dir="$(basename "$(dirname "$gomod")")"
  path="$(grep -m1 -E '^module[[:space:]]+\S+' "$gomod" | awk '{print $2}')"
  if [ -z "$path" ]; then
    no "go/$dir has a module path" "no 'module' line in $gomod"
    continue
  fi

  raw="$(GOWORK=off GOFLAGS=-mod=mod GOPROXY="$GO_PROXY_URL" \
    GONOPROXY= GONOSUMDB= GOPRIVATE= \
    go list -m -versions "$path" 2>/dev/null)"
  # The documented output format is "the module path followed by the
  # space-separated version list", so the versions are everything after the
  # first field. A line that is not about this module is discarded rather than
  # parsed, which keeps a diagnostic on stdout from being read as a version.
  served=""
  case "$raw" in
  "$path"|"$path "*) served="${raw#"$path"}" ;;
  esac

  tag="go/$dir/$version"
  tag_at="$(git -C "$ROOT" for-each-ref --format='%(creatordate:unix)' "refs/tags/$tag")"
  if [ -n "$tag_at" ]; then
    age=$(((now - tag_at) / 60))
  else
    age="none"
  fi

  verdict="$(classify "go/$dir" "$version" "$served" "$age")"
  kind="$(printf '%s' "$verdict" | cut -f1)"
  detail="$(printf '%s' "$verdict" | cut -f2-)"
  checked=$((checked + 1))

  case "$kind" in
  OK) ok "$detail" ;;
  LAG) ok "$detail" ;;
  MISSING)
    no "proxy.golang.org serves go/$dir at $version" "$detail" \
      "the tag exists and the proxy is past its index lag, so this is not propagation —" \
      "check .github/workflows/tag-go-modules.yml's recent runs, and go-release.yml's (#627)"
    ;;
  UNTAGGED)
    no "proxy.golang.org serves go/$dir at $version" "$detail" \
      "the module line moved on main and the six go/<module>/$version tags were never cut;" \
      "the tagger is dispatched by .github/release/go.releaserc.json's publishCmd (#361, #623)"
    ;;
  *)
    no "go/$dir could be evaluated" "$detail" \
      "command: GOWORK=off GOFLAGS=-mod=mod GOPROXY=$GO_PROXY_URL go list -m -versions $path"
    ;;
  esac
done

total=$((pass + fail))
# Positive floor: there are six modules, and every one of them is published —
# a sweep that evaluated fewer did not do its job. A `go list` that failed for
# all of them would otherwise report a clean zero-failure run.
MIN=6
case "$pass$fail$total$checked" in
*[!0-9]*)
  echo "::error::Go freshness guard produced a non-numeric tally"
  exit 1
  ;;
esac
if [ "$checked" -lt "$MIN" ]; then
  echo "::error::Go freshness guard evaluated $checked modules, expected at least $MIN — the sweep itself is broken"
  exit 1
fi
echo "Results: $pass passed, $fail failed, $total total"
[ "$fail" -eq 0 ] || exit 1
