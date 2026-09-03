#!/usr/bin/env bash
# Unit test for the vcpkg self-host sidecar wiring (issues #368 / #361).
#
# A vcpkg-built `ball` has no Dart toolchain in its sandbox, so
# dart/self_host/lib/{cli_rt.h,engine_rt.cpp} are absent and cpp/cli's EXISTS
# gates fall back to cli_verbs_stub.cpp / cli_run_stub.cpp — `ball run` and
# `ball info`/`validate`/`tree` exit 2. The fix ships those two generated
# sources as a versioned GitHub Release asset the portfile downloads and
# unpacks into ${SOURCE_PATH}/dart/self_host/lib/ before configuring.
#
# That mechanism has three seams a plain "does it build" smoke cannot see, and
# each one is a silent, permanent verb loss rather than a loud failure:
#
#   1. NAMING. The release asset's filename and the portfile's expected
#      FILENAME are written in two different files. A rename on either side
#      404s every future release's sidecar — not just the next one.
#   2. OVERLAY HERMETICITY. make_ci_overlay.py's contract was "swap exactly one
#      thing" (the vcpkg_from_github download). With a second network fetch in
#      the portfile, a generator that swaps only the first one leaves the CI
#      smoke reaching for a release asset that does not exist yet — or, worse,
#      silently proves nothing while still exiting 0.
#   3. SMOKE HONESTY. ci.yml's vcpkg job pre-generates the sidecar in the very
#      checkout vcpkg builds from, so the EXISTS gates would fire even if the
#      portfile's download/extract were completely broken. The job must delete
#      the pre-generated copies before `vcpkg install`, or the new run/info
#      assertions test the checkout instead of the port.
#
# Every case here is a static/synthetic check against the repo's own files —
# no vcpkg, no Dart, no C++ toolchain, sub-second — in the same always-run
# `Proto Checks` slot as the other CI-plumbing unit tests.
#
# Usage: bash tools/vcpkg-port/test/test_selfhost_asset_wiring.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
GEN="$ROOT/tools/vcpkg-port/make_ci_overlay.py"
PORTFILE="$ROOT/tools/vcpkg-port/ports/ball-lang/portfile.cmake"
MANIFEST="$ROOT/tools/vcpkg-port/ports/ball-lang/vcpkg.json"
CI_WORKFLOW="$ROOT/.github/workflows/ci.yml"
RELEASE_WORKFLOW="$ROOT/.github/workflows/release-cpp.yml"

for f in "$GEN" "$PORTFILE" "$MANIFEST" "$CI_WORKFLOW" "$RELEASE_WORKFLOW"; do
  [ -f "$f" ] || {
    echo "::error::missing $f"
    exit 1
  }
done

PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || PY=python
command -v "$PY" >/dev/null 2>&1 || {
  echo "::error::no python interpreter on PATH"
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

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# NOTE on the `|| true`s below: they are value-capture only — `grep -c` exits 1
# on zero matches, and an empty capture would make the numeric comparison that
# follows a syntax error rather than a FAIL. Every one of them feeds a value
# that IS then asserted; none of them swallows a gate.

# The ci.yml `vcpkg` job body, sliced out once so the wiring cases below cannot
# accidentally match an identically-named step in a different job.
JOB="$(awk '
  /^  vcpkg:$/ { inside = 1; next }
  inside && /^  [a-zA-Z0-9_-]+:$/ { inside = 0 }
  inside { print }
' "$CI_WORKFLOW")"
if [ -z "$JOB" ]; then
  echo "::error::could not slice the \`vcpkg\` job out of $CI_WORKFLOW"
  exit 1
fi

# ── 1. The generator swaps BOTH network fetches, and says so structurally. ──
# The overlay must be hermetic: no vcpkg_from_*/vcpkg_download_distfile call may
# survive into it, or the CI smoke reaches the network for an asset that only
# exists after a tag is cut.
OVERLAY="$SCRATCH/overlay"
ARCHIVE="$SCRATCH/selfhost.tar.gz"
: >"$ARCHIVE"
gen_rc=0
gen_out="$("$PY" "$GEN" "$OVERLAY" "/tmp/checkout" "$ARCHIVE" 2>&1)" || gen_rc=$?
GENERATED="$OVERLAY/ball-lang/portfile.cmake"
if [ "$gen_rc" -eq 0 ] && [ -f "$GENERATED" ]; then
  ok "make_ci_overlay.py accepts a sidecar-archive argument"
else
  no "make_ci_overlay.py accepts a sidecar-archive argument" \
    "exit $gen_rc; output:" "$gen_out"
  GENERATED="/dev/null"
fi

n="$(grep -c '^set(SOURCE_PATH "' "$GENERATED" 2>/dev/null || true)"
if [ "${n:-0}" -eq 1 ]; then
  ok "overlay swaps the source download for exactly one set(SOURCE_PATH ...)"
else
  no "overlay swaps the source download for exactly one set(SOURCE_PATH ...)" \
    "found ${n:-0} occurrences"
fi

n="$(grep -c 'set(BALL_SELFHOST_ARCHIVE "' "$GENERATED" 2>/dev/null || true)"
if [ "${n:-0}" -eq 1 ]; then
  ok "overlay swaps the sidecar download for exactly one set(BALL_SELFHOST_ARCHIVE ...)"
else
  no "overlay swaps the sidecar download for exactly one set(BALL_SELFHOST_ARCHIVE ...)" \
    "found ${n:-0} occurrences — the generator still only swaps one thing"
fi

# Matched on the basename, not the full path: an MSYS/Git-for-Windows bash
# rewrites a POSIX-looking argument into a Windows path before a native
# python3 ever sees it, and that translation is not what this case is about.
if grep -q "set(BALL_SELFHOST_ARCHIVE \".*/selfhost\.tar\.gz\")" "$GENERATED" 2>/dev/null; then
  ok "overlay points BALL_SELFHOST_ARCHIVE at the archive it was given"
else
  no "overlay points BALL_SELFHOST_ARCHIVE at the archive it was given" \
    "expected a set(BALL_SELFHOST_ARCHIVE \"...\") naming $(basename "$ARCHIVE")"
fi

# Anchored exactly like make_ci_overlay.py's own hermeticity check, so a call
# NAMED in a comment (the swap banners mention vcpkg_from_github by name) is not
# mistaken for a call MADE.
residual="$(grep -nE '^[[:space:]]*(vcpkg_from_[a-z_]+|vcpkg_download_distfile)[[:space:]]*\($' "$GENERATED" 2>/dev/null || true)"
if [ -z "$residual" ]; then
  ok "generated overlay contains no residual network fetch (hermetic)"
else
  no "generated overlay contains no residual network fetch (hermetic)" "$residual"
fi

# ── 2. The anti-rot diff stays meaningful: exactly TWO changed hunks. ───────
hunks="$(diff -u "$PORTFILE" "$GENERATED" 2>/dev/null | grep -c '^@@' || true)"
if [ "${hunks:-0}" -eq 2 ]; then
  ok "overlay differs from the submission portfile in exactly 2 hunks"
else
  no "overlay differs from the submission portfile in exactly 2 hunks" \
    "counted ${hunks:-0} hunks — ci.yml's anti-rot diff can no longer tell one swap from two"
fi

# ── 3. An unswapped fetch in the port is a LOUD generator failure. ─────────
# This is the drift class the "swap exactly one thing" contract was written to
# prevent: a third download added to the real port must not slip through into a
# CI overlay that then silently exercises a different recipe.
DRIFT="$SCRATCH/drift"
mkdir -p "$DRIFT/ports/ball-lang"
cp "$MANIFEST" "$DRIFT/ports/ball-lang/"
{
  cat "$PORTFILE"
  printf '\nvcpkg_from_git(\n    OUT_SOURCE_PATH EXTRA\n    URL https://example.invalid/x.git\n)\n'
} >"$DRIFT/ports/ball-lang/portfile.cmake"
cp "$GEN" "$DRIFT/make_ci_overlay.py"
drift_rc=0
drift_out="$("$PY" "$DRIFT/make_ci_overlay.py" "$SCRATCH/overlay-drift" "/tmp/checkout" "$ARCHIVE" 2>&1)" || drift_rc=$?
if [ "$drift_rc" -ne 0 ] && printf '%s' "$drift_out" | grep -qi 'vcpkg_from_git'; then
  ok "an unswapped network fetch in the port fails the generator loudly"
else
  no "an unswapped network fetch in the port fails the generator loudly" \
    "exit $drift_rc; output:" "$drift_out"
fi

# ── 4. The release asset name and the portfile's FILENAME cannot drift. ────
# Normalized to <VER>: release-cpp.yml interpolates the tag (`vX.Y.Z`), the
# portfile interpolates vcpkg's `${VERSION}` (`X.Y.Z`, no leading `v`).
norm_asset() {
  sed -e 's/\${tag}/<VER>/g' -e 's/v\${VERSION}/<VER>/g'
}
port_asset="$(grep -oE 'ball-selfhost-cpp-src-[^"[:space:]]*\.tar\.gz' "$PORTFILE" | norm_asset | sort -u)"
rel_asset="$(grep -oE 'ball-selfhost-cpp-src-[^"[:space:]]*\.tar\.gz' "$RELEASE_WORKFLOW" | norm_asset | sort -u)"
if [ -n "$port_asset" ] && [ "$port_asset" = "$rel_asset" ]; then
  ok "release asset name == portfile FILENAME (normalized: $port_asset)"
else
  no "release asset name == portfile FILENAME" \
    "portfile:        ${port_asset:-<none>}" \
    "release-cpp.yml: ${rel_asset:-<none>}"
fi

if grep -q 'releases/download/v\${VERSION}/ball-selfhost-cpp-src-v\${VERSION}\.tar\.gz' "$PORTFILE"; then
  ok "portfile resolves the sidecar URL from the same v\${VERSION} as its REF"
else
  no "portfile resolves the sidecar URL from the same v\${VERSION} as its REF" \
    "the download URL must be derived from v\${VERSION}, not hard-coded to one tag"
fi

# ── 5. The sidecar is an opt-out-able default feature, not a hard failure. ──
# vcpkg_download_distfile has no non-fatal mode (verified against
# learn.microsoft.com/vcpkg/maintainers/functions/vcpkg_download_distfile), so
# "a source build without the sidecar still yields compile/encode/version" is
# expressed the only way vcpkg supports it: a default feature a consumer can
# drop with `vcpkg install ball-lang[core]`.
if "$PY" - "$MANIFEST" <<'PYEOF'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
feats = m.get("features", {})
defaults = m.get("default-features", [])
names = [d if isinstance(d, str) else d.get("name") for d in defaults]
sys.exit(0 if "selfhost" in feats and "selfhost" in names else 1)
PYEOF
then
  ok "vcpkg.json declares a default-on \`selfhost\` feature"
else
  no "vcpkg.json declares a default-on \`selfhost\` feature" "see $MANIFEST"
fi

if grep -q 'vcpkg_check_features' "$PORTFILE"; then
  ok "portfile gates the sidecar on the feature via vcpkg_check_features"
else
  no "portfile gates the sidecar on the feature via vcpkg_check_features" \
    "an ungated vcpkg_download_distfile hard-fails the whole port when the asset is missing"
fi

# ── 6. ci.yml's vcpkg job actually produces and passes the sidecar. ────────
if printf '%s\n' "$JOB" | grep -qE 'make_ci_overlay\.py .*".*" *".*" *".*"'; then
  ok "ci.yml passes a locally-built sidecar archive to make_ci_overlay.py"
else
  no "ci.yml passes a locally-built sidecar archive to make_ci_overlay.py" \
    "the vcpkg job must generate the sidecar on-runner and hand it to the overlay generator"
fi

if printf '%s\n' "$JOB" | grep -q 'compile_engine_cpp.dart --monolithic' &&
  printf '%s\n' "$JOB" | grep -q 'gen_cli_cpp.dart'; then
  ok "ci.yml pre-generates engine_rt.cpp + cli_rt.h in the vcpkg job"
else
  no "ci.yml pre-generates engine_rt.cpp + cli_rt.h in the vcpkg job" \
    "mirroring release-cpp.yml's own pregeneration steps"
fi

if printf '%s\n' "$JOB" | grep -q 'dart-pub-get'; then
  ok "ci.yml's vcpkg job uses the dart-pub-get composite, not a bare pub get"
else
  no "ci.yml's vcpkg job uses the dart-pub-get composite, not a bare pub get"
fi

# The honesty guard: the pre-generated copies must be REMOVED from the checkout
# before `vcpkg install`, so the only way the verbs become real is the
# portfile's own download+extract.
if printf '%s\n' "$JOB" | grep -q 'dart/self_host/lib/cli_rt\.h' &&
  printf '%s\n' "$JOB" | grep -q 'dart/self_host/lib/engine_rt\.cpp' &&
  printf '%s\n' "$JOB" | grep -qE '^\s*rm -f '; then
  ok "ci.yml deletes the pre-generated sources before \`vcpkg install\`"
else
  no "ci.yml deletes the pre-generated sources before \`vcpkg install\`" \
    "otherwise the EXISTS gates fire from the checkout and the smoke proves nothing about the port"
fi

# ── 7. The smoke asserts real verbs, not just a stub-safe `ball version`. ──
if printf '%s\n' "$JOB" | grep -q 'fixture=tests/conformance/' &&
  printf '%s\n' "$JOB" | grep -q '\$bin" run "\$fixture"'; then
  ok "vcpkg smoke runs \`ball run <conformance fixture>\`"
else
  no "vcpkg smoke runs \`ball run <conformance fixture>\`" \
    "\`ball version\` is compiled in unconditionally and passes in a fully stubbed build"
fi

if printf '%s\n' "$JOB" | grep -q '\$bin" info "\$fixture"'; then
  ok "vcpkg smoke runs \`ball info <conformance fixture>\`"
else
  no "vcpkg smoke runs \`ball info <conformance fixture>\`"
fi

if printf '%s\n' "$JOB" | grep -q 'expected_output\.txt'; then
  ok "vcpkg smoke diffs \`ball run\` against the conformance golden"
else
  no "vcpkg smoke diffs \`ball run\` against the conformance golden"
fi

if printf '%s\n' "$JOB" | grep -q '\.info\.txt'; then
  ok "vcpkg smoke diffs \`ball info\` against the cli-parity golden"
else
  no "vcpkg smoke diffs \`ball info\` against the cli-parity golden"
fi

# ── 8. release-cpp.yml uploads the asset. ─────────────────────────────────
if grep -q 'gh release upload' "$RELEASE_WORKFLOW" &&
  grep -q 'ball-selfhost-cpp-src' "$RELEASE_WORKFLOW"; then
  ok "release-cpp.yml uploads the self-host sidecar to the GitHub Release"
else
  no "release-cpp.yml uploads the self-host sidecar to the GitHub Release"
fi

# ── 9. This test is itself wired into an always-run CI job. ───────────────
if grep -q 'tools/vcpkg-port/test/test_selfhost_asset_wiring.sh' "$CI_WORKFLOW"; then
  ok "ci.yml runs this test"
else
  no "ci.yml runs this test" "a guard nothing invokes is not a guard"
fi

total=$((pass + fail))
if [ "$total" -lt 1 ]; then
  echo "::error::vcpkg self-host asset wiring test ran zero cases"
  exit 1
fi
echo "Results: $pass passed, $fail failed, $total total"
[ "$fail" -eq 0 ] || exit 1
