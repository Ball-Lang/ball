#!/usr/bin/env bash
# Unit test for the `ball` release-binary target matrix (issue #368).
#
# `.github/workflows/release-cpp.yml` builds the unified `ball` CLI once per
# platform and attaches `ball-<tag>-<target>.tar.gz` (+ its `.sha256`) to the
# GitHub Release, plus ONE platform-independent self-host sidecar
# (`ball-selfhost-cpp-src-<tag>.tar.gz`) uploaded from a single leg.
#
# Nothing gated that matrix. The workflow is tag-dispatched, so it never runs
# on a PR, and every way it can go wrong is silent rather than loud:
#
#   1. TARGET SET. The set of platforms a release ships is a product decision
#      (#368), spelled only inside a `strategy.matrix.include` block. Dropping
#      or forgetting a leg produces a perfectly green release that is simply
#      missing a platform — nobody notices until a user 404s on a download URL.
#   2. ARCH/LABEL MISMATCH. GitHub's `macos-latest` is Apple Silicon, and the
#      Intel macOS runners are separately labelled (`macos-15-intel`, the
#      `-large` variants). A leg named `macos-x64` pointed at an arm64 runner
#      ships an arm64 binary under an x64 filename — the worst outcome here,
#      because the artifact exists, the checksum matches, and it simply will
#      not execute on the machine it claims to target.
#   3. ASSET-NAME DRIFT. The archive name must stay derived from
#      `matrix.target`. A hard-coded per-target name means a new leg silently
#      overwrites another leg's asset (both legs `gh release upload --clobber`
#      the same filename) instead of adding its own.
#   4. SINGLE-UPLOADER INVARIANT. The self-host sidecar is byte-identical from
#      every leg, so exactly one leg may upload it; two legs racing
#      `--clobber` on one filename is a genuine race. That "one leg" is named
#      in the workflow AND in tools/vcpkg-port/README.md, which never meet.
#   5. DOC DRIFT. docs/RELEASE.md documents which platforms a release ships.
#      A matrix change that leaves the table behind makes the documented
#      download matrix a lie.
#
# Every case here is a static check against the repo's own files — no network,
# no toolchain, sub-second — in the same always-run `Proto Checks` slot as the
# other CI-plumbing unit tests.
#
# Usage: bash tools/test/test_release_cpp_targets.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RELEASE_WORKFLOW="$ROOT/.github/workflows/release-cpp.yml"
CI_WORKFLOW="$ROOT/.github/workflows/ci.yml"
RELEASE_DOC="$ROOT/docs/RELEASE.md"
VCPKG_README="$ROOT/tools/vcpkg-port/README.md"

for f in "$RELEASE_WORKFLOW" "$CI_WORKFLOW" "$RELEASE_DOC" "$VCPKG_README"; do
  [ -f "$f" ] || {
    echo "::error::missing $f"
    exit 1
  }
done

# ── The decision this file pins ────────────────────────────────────────────
# Issue #368 asks for "linux and macos (arm64/x64)". These three targets are
# that decision, written down once. Changing what a release ships means
# changing this list AND the workflow AND docs/RELEASE.md — which is the
# entire point: none of the three can move alone.
EXPECTED_TARGETS="linux-x64 macos-arm64 macos-x64"

# macOS runner labels that are Intel/x86_64, per GitHub's own runner reference
# (https://docs.github.com/en/actions/reference/runners/github-hosted-runners
# — `macos-15-intel`: 4 CPU / 14 GB / Architecture "Intel") and the
# actions/runner-images README (`macos-*-large` are the x64 images; the plain
# and `-xlarge` labels are arm64). `macos-13`, the old default Intel image, was
# retired 2025-12-04 (github.blog changelog "macOS 13 runner image is closing
# down") and is deliberately NOT listed — a leg pointed at it would not run.
INTEL_MACOS_LABELS="macos-15-intel macos-26-intel macos-latest-large macos-15-large macos-14-large"

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

# Extract `<target> <os>` pairs from a release-cpp.yml-shaped file's
# `strategy.matrix.include:` block. Deliberately shape-specific: an include
# entry is `- os: <label>` immediately followed by `target: <name>`, which is
# how the workflow is written and how a reviewer reads it.
extract_matrix() {
  awk '
    /^ *include: *$/ { inside = 1; next }
    inside && /^ *- os: *[^ ]+ *$/ {
      os = $NF
      getline
      if ($0 ~ /^ *target: *[^ ]+ *$/) { print $NF, os; next }
      inside = 0
      next
    }
    inside && /^ *runs-on:/ { inside = 0 }
  ' "$1"
}

MATRIX="$(extract_matrix "$RELEASE_WORKFLOW")"
matrix_targets="$(printf '%s\n' "$MATRIX" | awk 'NF {print $1}' | sort | tr '\n' ' ' | sed -e 's/ *$//')"
expected_sorted="$(printf '%s\n' $EXPECTED_TARGETS | sort | tr '\n' ' ' | sed -e 's/ *$//')"

# ── 0. The extractor can actually see a difference. ───────────────────────
# A parser that silently yields nothing would make every set comparison below
# vacuously "equal to itself". Prove it separates a matrix WITH a leg from the
# same matrix WITHOUT it before trusting any of its output.
DRIFT="$SCRATCH/release-cpp-drift.yml"
awk '
  !dropped && /^ *- os: *[^ ]+ *$/ {
    getline t
    if (t ~ /^ *target: *[^ ]+ *$/) { dropped = 1; next }
    print; print t; next
  }
  { print }
' "$RELEASE_WORKFLOW" >"$DRIFT"
drift_targets="$(extract_matrix "$DRIFT" | awk 'NF {print $1}' | sort | tr '\n' ' ' | sed -e 's/ *$//')"
if [ -n "$matrix_targets" ] && [ "$drift_targets" != "$matrix_targets" ]; then
  ok "matrix extractor detects a removed leg (self-test)"
else
  no "matrix extractor detects a removed leg (self-test)" \
    "parsed:            ${matrix_targets:-<none>}" \
    "parsed after drop: ${drift_targets:-<none>}" \
    "the extractor cannot tell the two apart — every case below would be vacuous"
fi

# ── 1. The matrix ships exactly the decided target set. ───────────────────
if [ "$matrix_targets" = "$expected_sorted" ]; then
  ok "release-cpp.yml matrix targets == $expected_sorted"
else
  no "release-cpp.yml matrix targets == $expected_sorted" \
    "workflow: ${matrix_targets:-<none>}" \
    "expected: $expected_sorted"
fi

n_entries="$(printf '%s\n' "$MATRIX" | awk 'NF' | wc -l | tr -d ' ')"
n_unique="$(printf '%s\n' "$MATRIX" | awk 'NF {print $1}' | sort -u | wc -l | tr -d ' ')"
if [ "$n_entries" = "$n_unique" ] && [ "${n_entries:-0}" -gt 0 ]; then
  ok "every matrix leg has a distinct target name"
else
  no "every matrix leg has a distinct target name" \
    "$n_entries entries, $n_unique distinct targets — two legs sharing a target overwrite each other's asset"
fi

# ── 2. Each leg's runner label matches the architecture its target claims. ─
runner_for() { printf '%s\n' "$MATRIX" | awk -v t="$1" '$1 == t {print $2}'; }
is_intel_macos() {
  local label="$1" known
  for known in $INTEL_MACOS_LABELS; do
    [ "$label" = "$known" ] && return 0
  done
  return 1
}

starts_with() { case "$2" in "$1"*) return 0 ;; *) return 1 ;; esac; }

linux_os="$(runner_for linux-x64)"
if [ -n "$linux_os" ] && starts_with ubuntu "$linux_os"; then
  ok "linux-x64 runs on an Ubuntu runner ($linux_os)"
else
  no "linux-x64 runs on an Ubuntu runner" "got: ${linux_os:-<no such leg>}"
fi

arm_os="$(runner_for macos-arm64)"
if [ -n "$arm_os" ] && starts_with macos "$arm_os" && ! is_intel_macos "$arm_os"; then
  ok "macos-arm64 runs on an Apple-Silicon macOS runner ($arm_os)"
else
  no "macos-arm64 runs on an Apple-Silicon macOS runner" \
    "got: ${arm_os:-<no such leg>}" \
    "the Intel labels are: $INTEL_MACOS_LABELS"
fi

x64_os="$(runner_for macos-x64)"
if [ -n "$x64_os" ] && is_intel_macos "$x64_os"; then
  ok "macos-x64 runs on an Intel macOS runner ($x64_os)"
else
  no "macos-x64 runs on an Intel macOS runner" \
    "got: ${x64_os:-<no such leg>}" \
    "an arm64 label here ships an arm64 binary under an x64 filename — it would not run at all" \
    "the Intel labels are: $INTEL_MACOS_LABELS"
fi

# ── 3. Asset names stay derived from matrix.target, not hard-coded. ───────
if grep -q 'target="\${{ matrix\.target }}"' "$RELEASE_WORKFLOW" &&
  grep -q 'archive="ball-\${tag}-\${target}\.tar\.gz"' "$RELEASE_WORKFLOW"; then
  ok "the archive name is derived from matrix.target (every leg names its own asset)"
else
  no "the archive name is derived from matrix.target" \
    "a hard-coded per-target name means a new leg clobbers an existing leg's asset instead of adding one"
fi

if grep -q 'sha256sum "\$archive" > "\${archive}\.sha256"' "$RELEASE_WORKFLOW"; then
  ok "each leg emits a .sha256 sidecar beside its archive"
else
  no "each leg emits a .sha256 sidecar beside its archive"
fi

if grep -q 'gh release upload "\$tag" "\$archive" "\${archive}\.sha256"' "$RELEASE_WORKFLOW"; then
  ok "each leg uploads BOTH the archive and its .sha256"
else
  no "each leg uploads BOTH the archive and its .sha256"
fi

# ── 4. The self-host sidecar has exactly one uploader, and it is a real leg. ─
sidecar_guards="$(grep -oE "if: matrix\.target == '[^']+'" "$RELEASE_WORKFLOW" | sed -e "s/.*'\(.*\)'/\1/" | sort -u)"
n_guards="$(printf '%s\n' "$sidecar_guards" | awk 'NF' | wc -l | tr -d ' ')"
if [ "${n_guards:-0}" -eq 1 ]; then
  ok "exactly one matrix leg is singled out to upload the self-host sidecar ($sidecar_guards)"
else
  no "exactly one matrix leg is singled out to upload the self-host sidecar" \
    "found ${n_guards:-0}: ${sidecar_guards:-<none>}" \
    "two legs racing 'gh release upload --clobber' on one filename is a real race"
fi

if [ -n "$sidecar_guards" ] && printf '%s\n' "$MATRIX" | awk 'NF {print $1}' | grep -qx "$sidecar_guards"; then
  ok "the sidecar uploader names a target the matrix actually builds ($sidecar_guards)"
else
  no "the sidecar uploader names a target the matrix actually builds" \
    "guard: ${sidecar_guards:-<none>}" \
    "matrix: ${matrix_targets:-<none>}" \
    "a guard naming a renamed/removed leg means NO leg uploads the sidecar — every vcpkg install silently loses run/info/validate/tree"
fi

# tools/vcpkg-port/README.md describes that single uploader by name.
readme_leg="$(grep -oE 'from the `[a-z0-9-]+` leg only' "$VCPKG_README" | sed -e 's/.*`\(.*\)`.*/\1/' | sort -u)"
if [ -n "$readme_leg" ] && [ "$readme_leg" = "$sidecar_guards" ]; then
  ok "tools/vcpkg-port/README.md names the same sidecar leg as the workflow ($readme_leg)"
else
  no "tools/vcpkg-port/README.md names the same sidecar leg as the workflow" \
    "README:   ${readme_leg:-<none>}" \
    "workflow: ${sidecar_guards:-<none>}"
fi

# ── 5. docs/RELEASE.md's target table agrees with the matrix. ─────────────
# The table is sliced out by its own heading so a `| \`linux-x64\` |` row in
# some other document section cannot stand in for it.
DOC_TABLE="$(awk '
  /^## C\+\+ `ball` binaries lane/ { inside = 1; next }
  inside && /^#{1,2} / { inside = 0 }
  inside { print }
' "$RELEASE_DOC")"
if [ -z "$DOC_TABLE" ]; then
  no "docs/RELEASE.md documents the C++ binaries lane" \
    "expected a '## C++ \`ball\` binaries lane' section listing the release targets"
else
  ok "docs/RELEASE.md documents the C++ binaries lane"
fi

# The `|| true` is value-capture only: `grep` exits 1 on zero matches, and an
# unset capture under `set -u` would abort the run instead of FAILing the case
# below. The empty value IS asserted — it is exactly the "table has no rows"
# failure — so nothing is swallowed here.
doc_rows="$(printf '%s\n' "$DOC_TABLE" | grep -E '^\| `[a-z0-9-]+` +\| `[a-z0-9-]+` +\|' || true)"
doc_targets="$(printf '%s\n' "$doc_rows" | sed -nE 's/^\| `([a-z0-9-]+)` .*/\1/p' | sort | tr '\n' ' ' | sed -e 's/ *$//')"
if [ -n "$doc_targets" ] && [ "$doc_targets" = "$matrix_targets" ]; then
  ok "docs/RELEASE.md lists exactly the matrix's targets ($doc_targets)"
else
  no "docs/RELEASE.md lists exactly the matrix's targets" \
    "docs:     ${doc_targets:-<none>}" \
    "workflow: ${matrix_targets:-<none>}"
fi

label_mismatch=""
while IFS= read -r row; do
  [ -n "$row" ] || continue
  t="$(printf '%s' "$row" | sed -nE 's/^\| `([a-z0-9-]+)` .*/\1/p')"
  l="$(printf '%s' "$row" | sed -nE 's/^\| `[a-z0-9-]+` *\| `([a-z0-9-]+)` .*/\1/p')"
  want="$(runner_for "$t")"
  [ "$l" = "$want" ] || label_mismatch="${label_mismatch}${t}: doc '${l}' vs workflow '${want:-<none>}'; "
done <<EOF
$doc_rows
EOF
if [ -z "$label_mismatch" ] && [ -n "$doc_targets" ]; then
  ok "docs/RELEASE.md's runner label per target matches the workflow"
else
  no "docs/RELEASE.md's runner label per target matches the workflow" \
    "${label_mismatch:-no rows parsed}"
fi

# Each documented target must also advertise its own asset name, spelled the
# way the packaging step emits it.
missing_assets=""
for t in $EXPECTED_TARGETS; do
  printf '%s\n' "$DOC_TABLE" | grep -q "ball-vX\.Y\.Z-${t}\.tar\.gz" || missing_assets="$missing_assets $t"
done
if [ -z "$missing_assets" ]; then
  ok "docs/RELEASE.md names the release asset for every target"
else
  no "docs/RELEASE.md names the release asset for every target" \
    "missing a \`ball-vX.Y.Z-<target>.tar.gz\` cell for:$missing_assets"
fi

# ── 6. The workflow's own header prose is not left behind. ────────────────
# release-cpp.yml opens by naming the platforms it builds; a matrix change
# that leaves that comment stale is how the next reader learns a wrong fact.
HEADER="$(sed -n '1,60p' "$RELEASE_WORKFLOW")"
stale=""
for t in $EXPECTED_TARGETS; do
  printf '%s\n' "$HEADER" | grep -q "$t" || stale="$stale $t"
done
if [ -z "$stale" ]; then
  ok "release-cpp.yml's header comment names every target it builds"
else
  no "release-cpp.yml's header comment names every target it builds" \
    "not mentioned:$stale"
fi

# ── 7. This test is itself wired into an always-run CI job. ───────────────
if grep -q 'tools/test/test_release_cpp_targets\.sh' "$CI_WORKFLOW"; then
  ok "ci.yml runs this test"
else
  no "ci.yml runs this test" "a guard nothing invokes is not a guard"
fi

total=$((pass + fail))
if [ "$total" -lt 1 ]; then
  echo "::error::release target matrix test ran zero cases"
  exit 1
fi
echo "Results: $pass passed, $fail failed, $total total"
[ "$fail" -eq 0 ] || exit 1
