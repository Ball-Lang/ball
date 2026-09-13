#!/usr/bin/env bash
# Unit test for tools/go-module-proxy/bump_go_modules.sh and for the cross-file
# invariants tools/go-module-proxy/build_local_proxy.py asserts (issues #361, #586).
#
# Why this exists: the Go module line is a cross-file number — six go/*/go.mod
# `require` lines, go/go.work's five versioned `replace` pins, and the internal
# tools/coverage-study/go consumer — and Go's registry IS the git tag, so a
# half-landed bump is either a hard "unknown revision go/<m>/vX.Y.Z" or, worse,
# a silent fall-through to the PUBLIC proxy that measures released code while
# reading green. Both the rewriter and the assertions that catch a drifted tree
# are therefore instruments, and this proves them on a scratch tree before
# either is trusted. It runs in ci.yml's always-on `proto` job, alongside
# test_tag_go_modules.sh.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
bump="$repo/tools/go-module-proxy/bump_go_modules.sh"
proxy="$repo/tools/go-module-proxy/build_local_proxy.py"
[ -f "$bump" ] || { echo "::error::missing $bump"; exit 1; }
[ -f "$proxy" ] || { echo "::error::missing $proxy"; exit 1; }

passed=0; failed=0
ok()   { passed=$((passed + 1)); echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; }

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# A scratch tree shaped exactly like the real one: six modules under go/, a
# go.work whose `use` block matches the modules on disk and whose versioned
# replace block pins the five depended-on modules, plus the out-of-go/ internal
# consumer that also names the version.
make_tree() {
  local dir="$1" v="$2"
  rm -rf "$dir"; mkdir -p "$dir/go" "$dir/tools/coverage-study/go"
  for m in cli compiler encoder engine runtime shared; do mkdir -p "$dir/go/$m"; done
  cat > "$dir/go/go.work" <<EOF
go 1.23

use (
	./cli
	./compiler
	./encoder
	./engine
	./runtime
	./shared
)

replace (
	github.com/ball-lang/ball/go/compiler $v => ./compiler
	github.com/ball-lang/ball/go/encoder $v => ./encoder
	github.com/ball-lang/ball/go/engine $v => ./engine
	github.com/ball-lang/ball/go/runtime $v => ./runtime
	github.com/ball-lang/ball/go/shared $v => ./shared
)
EOF
  cat > "$dir/go/cli/go.mod" <<EOF
module github.com/ball-lang/ball/go/cli

go 1.23

require (
	github.com/ball-lang/ball/go/compiler $v
	github.com/ball-lang/ball/go/encoder $v
	github.com/ball-lang/ball/go/engine $v
	github.com/ball-lang/ball/go/runtime $v
	github.com/ball-lang/ball/go/shared $v
	google.golang.org/protobuf v1.36.11
)
EOF
  cat > "$dir/go/compiler/go.mod" <<EOF
module github.com/ball-lang/ball/go/compiler

go 1.23

require (
	github.com/ball-lang/ball/go/shared $v
	google.golang.org/protobuf v1.36.11
)
EOF
  cat > "$dir/go/encoder/go.mod" <<EOF
module github.com/ball-lang/ball/go/encoder

go 1.23

require (
	github.com/ball-lang/ball/go/compiler $v
	github.com/ball-lang/ball/go/shared $v
	google.golang.org/protobuf v1.36.11
)
EOF
  cat > "$dir/go/engine/go.mod" <<EOF
module github.com/ball-lang/ball/go/engine

go 1.23

require (
	github.com/ball-lang/ball/go/compiler $v
	github.com/ball-lang/ball/go/encoder $v
	github.com/ball-lang/ball/go/runtime $v
	github.com/ball-lang/ball/go/shared $v
	google.golang.org/protobuf v1.36.11
)
EOF
  printf 'package cli\n\nconst moduleVersion = "%s"\n' "${v#v}" > "$dir/go/cli/version.go"
  printf 'module github.com/ball-lang/ball/go/runtime\n\ngo 1.23\n' > "$dir/go/runtime/go.mod"
  cat > "$dir/go/shared/go.mod" <<EOF
module github.com/ball-lang/ball/go/shared

go 1.23

require google.golang.org/protobuf v1.36.11
EOF
  cat > "$dir/tools/coverage-study/go/go.mod" <<EOF
module github.com/ball-lang/ball/tools/coverage-study

go 1.23

require (
	github.com/ball-lang/ball/go/compiler $v
	github.com/ball-lang/ball/go/shared $v
)

replace (
	github.com/ball-lang/ball/go/compiler => ../../../go/compiler
	github.com/ball-lang/ball/go/shared => ../../../go/shared
)
EOF
}

derived() { python3 "$proxy" --root "$1" --print-version; }
# `|| true`: no match is a legitimate answer (0), not a pipeline failure — without
# it `set -o pipefail` turns a clean "zero references left at the old version"
# into a silent exit, which is exactly a gate that cannot report its own success.
count_at() { { grep -REho "ball/go/[a-z]+ $2" "$1/go" "$1/tools" 2>/dev/null || true; } | wc -l | tr -d ' '; }

# ── 1. A consistent tree bumps every file in one run ─────────────────────────
make_tree "$scratch/a" v0.1.0
[ "$(derived "$scratch/a")" = "v0.1.0" ] || fail "scratch tree did not start at v0.1.0"
if bash "$bump" v0.2.0 --root "$scratch/a" >"$scratch/a.log" 2>&1; then
  after_new="$(count_at "$scratch/a" v0.2.0)"
  after_old="$(count_at "$scratch/a" v0.1.0)"
  if [ "$(derived "$scratch/a")" = "v0.2.0" ] && [ "$after_old" -eq 0 ] && [ "$after_new" -ge 18 ]; then
    ok "bump rewrote all $after_new references (six go.mod + go.work + the internal consumer)"
  else
    fail "bump left the tree at derived=$(derived "$scratch/a") old=$after_old new=$after_new"
  fi
  grep -q "coverage-study/go/go.mod" "$scratch/a.log" \
    && ok "the out-of-go/ internal consumer is swept too" \
    || fail "tools/coverage-study/go/go.mod was not swept"
  # The ninth site: `ball version`'s fallback constant, UNPREFIXED. go/cli's
  # TestModuleVersionMatchesGoMod is the drift guard that caught this being
  # missed the first time the real bump ran — the script owns it now, so the
  # bump stays ONE action.
  grep -q 'const moduleVersion = "0.2.0"' "$scratch/a/go/cli/version.go" \
    && ok "go/cli/version.go's moduleVersion fallback is bumped too (unprefixed)" \
    || fail "go/cli/version.go was not bumped"
else
  fail "bump on a consistent tree failed"; cat "$scratch/a.log"
fi

# ── 2. Idempotent: re-running at the same version changes nothing ────────────
sig_before="$(cat "$scratch/a"/go/go.work "$scratch/a"/go/*/go.mod "$scratch/a"/go/cli/version.go "$scratch/a"/tools/coverage-study/go/go.mod)"
if bash "$bump" v0.2.0 --root "$scratch/a" >"$scratch/a2.log" 2>&1; then
  sig_after="$(cat "$scratch/a"/go/go.work "$scratch/a"/go/*/go.mod "$scratch/a"/go/cli/version.go "$scratch/a"/tools/coverage-study/go/go.mod)"
  [ "$sig_before" = "$sig_after" ] && ok "idempotent (second run is a byte-identical no-op)" \
    || fail "second run changed the tree"
else
  fail "second run failed"; cat "$scratch/a2.log"
fi

# ── 3. Bad versions are refused ──────────────────────────────────────────────
make_tree "$scratch/b" v0.1.0
for bad in 0.2.0 v0.2 v0.2.0-rc.1 vX.Y.Z v01.2.0 ""; do
  if bash "$bump" ${bad:+"$bad"} --root "$scratch/b" >/dev/null 2>&1; then
    fail "non-semver version '${bad:-<empty>}' was ACCEPTED"
  else
    ok "non-semver version '${bad:-<empty>}' refused"
  fi
done
[ "$(derived "$scratch/b")" = "v0.1.0" ] && ok "a refused bump leaves the tree untouched" \
  || fail "a refused bump still edited the tree"

# ── 4. A major >= 2 is refused: the module paths carry no /vN suffix ─────────
#    https://go.dev/ref/mod#major-version-suffixes
if bash "$bump" v2.0.0 --root "$scratch/b" >"$scratch/b2.log" 2>&1; then
  fail "v2.0.0 was accepted without a /v2 module-path suffix"
else
  grep -q "major-version-suffixes" "$scratch/b2.log" \
    && ok "v2.0.0 refused, citing Go's /vN module-path rule" \
    || fail "v2.0.0 refused but without the /vN explanation"
fi

# ── 4b. A renamed/moved version fallback is refused, never silently skipped ──
make_tree "$scratch/v" v0.1.0
sed -i 's|^const moduleVersion|const ballVersion|' "$scratch/v/go/cli/version.go"
if bash "$bump" v0.2.0 --root "$scratch/v" >"$scratch/v.log" 2>&1; then
  fail "a missing moduleVersion constant was silently skipped"
else
  ok "a missing moduleVersion constant is refused, not skipped"
fi

# ── 4c. --check-next: the release lane's verifyRelease gate ─────────────────
#    `.github/release/go.releaserc.json` runs this as its verifyReleaseCmd, and
#    semantic-release runs verifyRelease BEFORE prepare and ALSO under
#    --dry-run. So it is the only place a rehearsal can prove the computed
#    version, and the only place a v2 line or a lost tag baseline is stopped
#    before a commit or a tag exists. It must rewrite NOTHING.
make_tree "$scratch/n" v0.2.0
sig_n="$(cat "$scratch/n"/go/go.work "$scratch/n"/go/*/go.mod "$scratch/n"/go/cli/version.go)"
for pair in "patch v0.2.1" "minor v0.3.0" "major v1.0.0"; do
  set -- $pair
  if bash "$bump" --check-next "$2" --type "$1" --root "$scratch/n" >/dev/null 2>&1; then
    ok "--check-next accepts the $1 successor of v0.2.0 ($2)"
  else
    fail "--check-next rejected the legal $1 successor $2"
  fi
done
# semver.inc(0.2.0, <type>) has exactly one answer per type; anything else means
# semantic-release was not computing from this tree's line at all.
for pair in "minor v1.0.0" "patch v0.3.0" "minor v0.2.1" "major v0.3.0"; do
  set -- $pair
  if bash "$bump" --check-next "$2" --type "$1" --root "$scratch/n" >/dev/null 2>&1; then
    fail "--check-next ACCEPTED $2 as a $1 release of v0.2.0"
  else
    ok "--check-next refuses $2 as a $1 release of v0.2.0 (continuity lost)"
  fi
done
# The 1.0.0 fallback is the specific shape this catches: semantic-release uses
# FIRST_RELEASE=1.0.0 when it finds no tag matching tagFormat, and 1.0.0 is a
# perfectly legal version that would silently jump the module line.
# Not a pipe: `set -o pipefail` would turn this refusal's (correct) exit 1 into
# a failed assertion about its TEXT.
bash "$bump" --check-next v1.0.0 --type minor --root "$scratch/n" >"$scratch/n.log" 2>&1 || true
grep -q "no-previous-release default of 1.0.0" "$scratch/n.log" &&
  ok "--check-next names the lost-baseline cause (semantic-release's 1.0.0 fallback)" ||
  fail "--check-next refused without explaining the 1.0.0 fallback"
for bad in "" "Patch" "prerelease"; do
  if bash "$bump" --check-next v0.2.1 ${bad:+--type "$bad"} --root "$scratch/n" >/dev/null 2>&1; then
    fail "--check-next accepted --type '${bad:-<missing>}'"
  else
    ok "--check-next refuses --type '${bad:-<missing>}'"
  fi
done
[ "$(cat "$scratch/n"/go/go.work "$scratch/n"/go/*/go.mod "$scratch/n"/go/cli/version.go)" = "$sig_n" ] &&
  ok "--check-next rewrote nothing (byte-identical tree after 11 invocations)" ||
  fail "--check-next modified the tree"
# The v2 cliff, reached the way it will actually be reached: a `feat!` on a 1.x
# line. https://go.dev/ref/mod#major-version-suffixes
make_tree "$scratch/m" v1.4.0
if bash "$bump" --check-next v2.0.0 --type major --root "$scratch/m" >"$scratch/m.log" 2>&1; then
  fail "--check-next accepted v2.0.0 without a /v2 module-path suffix"
else
  grep -q "major-version-suffixes" "$scratch/m.log" &&
    ok "--check-next refuses the v2.0.0 a major release of a 1.x line computes, citing Go's /vN rule" ||
    fail "--check-next refused v2.0.0 but without the /vN explanation"
fi

# ── 5. The build_local_proxy assertions bite on a drifted tree ───────────────
#    Each of these is a half-landed bump; all four must fail LOUD, because the
#    proxy this script synthesizes must equal the module set the tags publish.
make_tree "$scratch/c" v0.1.0
sed -i 's|/go/shared v0.1.0|/go/shared v0.9.9|' "$scratch/c/go/encoder/go.mod"
derived "$scratch/c" >/dev/null 2>&1 && fail "disagreeing go.mod requires NOT caught" \
  || ok "disagreeing go.mod requires caught"

make_tree "$scratch/d" v0.1.0
sed -i 's|/go/engine v0.1.0 =>|/go/engine v0.9.9 =>|' "$scratch/d/go/go.work"
derived "$scratch/d" >/dev/null 2>&1 && fail "drifted go.work pin NOT caught" \
  || ok "drifted go.work pin caught"

make_tree "$scratch/e" v0.1.0
sed -i '/go\/runtime v0.1.0 =>/d' "$scratch/e/go/go.work"
derived "$scratch/e" >/dev/null 2>&1 && fail "missing go.work pin NOT caught" \
  || ok "missing go.work pin caught"

make_tree "$scratch/f" v0.1.0
printf '\nreplace github.com/ball-lang/ball/go/shared => ../shared\n' >> "$scratch/f/go/cli/go.mod"
derived "$scratch/f" >/dev/null 2>&1 && fail "a published go.mod with a replace NOT caught" \
  || ok "a published go.mod with a replace caught (go install rejects those)"

# ── 6. go.work's `use` block must match the modules on disk ─────────────────
#    tag_go_modules.sh enumerates go/*/ from DISK; this script reads go.work.
make_tree "$scratch/g" v0.1.0
mkdir -p "$scratch/g/go/seventh"
printf 'module github.com/ball-lang/ball/go/seventh\n\ngo 1.23\n' > "$scratch/g/go/seventh/go.mod"
derived "$scratch/g" >/dev/null 2>&1 && fail "a module on disk but absent from go.work NOT caught" \
  || ok "a module on disk but absent from go.work caught (it would be tagged untested)"

# ── 7. --version is a cross-check, never an override ─────────────────────────
make_tree "$scratch/h" v0.1.0
python3 "$proxy" --root "$scratch/h" --print-version --version v0.9.9 >/dev/null 2>&1 \
  && fail "--version was allowed to disagree with the go.mod files" \
  || ok "--version disagreeing with the go.mod files is refused"
[ "$(python3 "$proxy" --root "$scratch/h" --print-version --version v0.1.0)" = "v0.1.0" ] \
  && ok "--version agreeing with the go.mod files is accepted" \
  || fail "--version agreeing with the go.mod files was refused"

# ── 8. The real checkout is consistent right now ─────────────────────────────
real="$(python3 "$proxy" --print-version)"
if printf '%s' "$real" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
  ok "this checkout's Go module line derives cleanly: $real"
else
  fail "this checkout's Go module line does not derive: '$real'"
fi
# tag-go-modules.yml must keep deriving the tag from the SAME entry point, or
# the proxy CI proves and the tags that get cut can drift apart.
wf="$repo/.github/workflows/tag-go-modules.yml"
grep -q 'build_local_proxy.py --print-version' "$wf" \
  && ok "tag-go-modules.yml derives the tag version from --print-version" \
  || fail "tag-go-modules.yml no longer derives the tag from --print-version"

echo "Results: $passed passed, $failed failed, $((passed + failed)) total"
# Positive floor: an early `exit`, a skipped block, or a helper that stopped
# running must not read as a pass.
[ "$failed" -eq 0 ] && [ "$passed" -ge 35 ]
