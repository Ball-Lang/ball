#!/usr/bin/env bash
# Move the Ball Go module line to a new version, in ONE run (issue #586).
#
# Go's registry IS the git tag: `go/<module>/vX.Y.Z` tags are what
# proxy.golang.org serves, and every intra-repo `require` in go/*/go.mod names
# that exact version, with the local pins in go/go.work's versioned `replace`
# block (no `replace` may appear in a published go.mod — `go install` rejects
# those, issue #361). So a version bump is a cross-file edit that MUST land
# whole: eight files today (six go/*/go.mod, go/go.work, and the internal
# tools/coverage-study/go/go.mod consumer), and a half-landed one either fails
# the `go` job with "unknown revision go/<m>/vX.Y.Z" or — worse — resolves off
# the PUBLIC proxy and silently measures released code. This script is how that
# edit is made, so it is one reviewable, idempotent, self-verifying action
# instead of eight hand edits.
#
# Contract:
#   $1 = the new version (vX.Y.Z). `--root <dir>` overrides the repo root (used
#        by tools/test/test_bump_go_modules.sh to drive a scratch tree).
#   Refuses a non-semver version, refuses a major >= 2 (the module paths carry
#   no `/vN` suffix, which Go requires from v2 on —
#   https://go.dev/ref/mod#major-version-suffixes), rewrites every intra-repo
#   `github.com/ball-lang/ball/go/<m> vX.Y.Z` reference it finds in tracked
#   go.mod / go.work files, asserts a positive floor of rewritten references,
#   asserts nothing anywhere still names the OLD version, and finally re-derives
#   the version through build_local_proxy.py --print-version (the same call
#   tag-go-modules.yml makes) so the four cross-file invariants are re-asserted
#   on the result. Idempotent: re-running at the version already in the tree
#   rewrites nothing and still verifies.
#
# `--check-next <vX.Y.Z> --type <patch|minor|major>` is the same contract with
#   NOTHING rewritten: it asserts the version is legal (semver, major < 2) and
#   that it is exactly `semver.inc(<the line in the tree>, <type>)` — the
#   formula semantic-release itself applies
#   (semantic-release/lib/get-next-version.js: `semver.inc(lastRelease.version,
#   type)`). `.github/release/go.releaserc.json` runs it as its
#   `verifyReleaseCmd`, which semantic-release executes BEFORE prepare and ALSO
#   under `--dry-run`, so it is the gate that (a) stops a v2 line before any
#   commit or tag exists and (b) catches the lane losing version continuity —
#   semantic-release starts a tag line it cannot find at 1.0.0, and 1.0.0 is a
#   perfectly legal version that would silently jump the module line and put the
#   next breaking change over the v2 cliff.
#
# Usage: tools/go-module-proxy/bump_go_modules.sh v0.2.0
#        tools/go-module-proxy/bump_go_modules.sh --check-next v0.2.1 --type patch
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"

version=""
mode="bump"
type=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root) root="$(cd "$2" && pwd)"; shift 2 ;;
    --root=*) root="$(cd "${1#*=}" && pwd)"; shift ;;
    --check-next) mode="check"; shift ;;
    --type) type="${2:-}"; shift 2 ;;
    --type=*) type="${1#*=}"; shift ;;
    -*) echo "bump: unknown flag '$1'" >&2; exit 2 ;;
    *) version="$1"; shift ;;
  esac
done

if [ -z "$version" ]; then
  echo "usage: bump_go_modules.sh <vX.Y.Z> [--root <dir>]" >&2
  echo "       bump_go_modules.sh --check-next <vX.Y.Z> --type <patch|minor|major> [--root <dir>]" >&2
  exit 2
fi

# Semver with the mandatory `v` prefix (https://go.dev/ref/mod#versions).
if ! printf '%s' "$version" | grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'; then
  echo "bump: '$version' is not a Go module version (want vX.Y.Z, no leading zeros, no suffix)" >&2
  exit 1
fi

major="${version#v}"
major="${major%%.*}"
if [ "$major" -ge 2 ]; then
  echo "bump: v$major.x.x needs a /v$major suffix on every module path (https://go.dev/ref/mod#major-version-suffixes)." >&2
  echo "      The Ball Go module paths are github.com/ball-lang/ball/go/<m> with no suffix, so the" >&2
  echo "      line must stay 0.x/1.x until the paths themselves are renamed. Refusing." >&2
  exit 1
fi

# ── --check-next: validate, never rewrite. ───────────────────────────────────
# Everything above already ran, so a malformed version and the v2 cliff are
# refused here too — before semantic-release has created a commit or a tag.
if [ "$mode" = "check" ]; then
  case "$type" in
    patch|minor|major) ;;
    "") echo "bump: --check-next needs --type <patch|minor|major> (semantic-release's \${nextRelease.type})" >&2; exit 2 ;;
    *) echo "bump: --type '$type' is not one of patch/minor/major" >&2; exit 2 ;;
  esac
  current="$(python3 "$here/build_local_proxy.py" --root "$root" --print-version)"
  IFS='.' read -r cur_major cur_minor cur_patch <<EOF
${current#v}
EOF
  case "$type" in
    patch) want="v$cur_major.$cur_minor.$((cur_patch + 1))" ;;
    minor) want="v$cur_major.$((cur_minor + 1)).0" ;;
    major) want="v$((cur_major + 1)).0.0" ;;
  esac
  if [ "$version" != "$want" ]; then
    echo "bump: refusing a $type release at '$version' — the Go module line in this tree is '$current'," >&2
    echo "      so the only legal next version is '$want' (semver.inc, the same formula" >&2
    echo "      semantic-release applies in lib/get-next-version.js)." >&2
    echo "      A version that is not the tree's successor means the lane lost continuity: most" >&2
    echo "      likely no 'go-modules/v*' tag was reachable, and semantic-release fell back to its" >&2
    echo "      no-previous-release default of 1.0.0. Check go-release.yml's channel-tag bootstrap" >&2
    echo "      step before releasing anything — see docs/RELEASE.md, 'Go modules lane'." >&2
    exit 1
  fi
  echo "Go module line: $current -> $version ($type) — legal, nothing rewritten (--check-next)"
  exit 0
fi

# The files that carry an intra-repo version reference: go/go.work plus every
# TRACKED go.mod in the repo. Discovered, never hardcoded, so a seventh module
# (or another internal consumer like tools/coverage-study/go) is covered the day
# it lands rather than silently left behind at the old version.
mapfile -t candidates < <(
  {
    printf '%s\n' "go/go.work"
    if command -v git >/dev/null 2>&1 && git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      git -C "$root" ls-files -- '*go.mod'
    else
      (cd "$root" && find . -name go.mod -not -path '*/node_modules/*' | sed 's|^\./||')
    fi
  } | sort -u
)

_INTRA='github\.com/ball-lang/ball/go/[a-z][a-z0-9_]*'
_VER='v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*'

touched=0
refs=0
for rel in "${candidates[@]}"; do
  f="$root/$rel"
  [ -f "$f" ] || continue
  n="$(grep -Ec "$_INTRA[[:space:]]+$_VER" "$f" || true)"
  [ "$n" -gt 0 ] || continue
  refs=$((refs + n))
  before="$(cat "$f")"
  # Rewrite only `<intra-repo module path> <version>`; a bare version elsewhere
  # (prose, google.golang.org/protobuf, a `go 1.23` line) is never touched.
  sed -E -i "s|($_INTRA)[[:space:]]+$_VER|\\1 $version|g" "$f"
  if [ "$before" != "$(cat "$f")" ]; then
    echo "bumped $rel ($n references -> $version)"
    touched=$((touched + 1))
  else
    echo "ok     $rel ($n references already at $version)"
  fi
done

# Positive floor: an empty candidate list, a regex that stopped matching, or a
# tree scanned from the wrong root must never read as a successful bump.
case "$refs" in
  ''|*[!0-9]*) echo "bump: reference count '$refs' is not a bare integer" >&2; exit 1 ;;
esac
if [ "$refs" -lt 5 ]; then
  echo "bump: found only $refs intra-repo version references, want >= 5 (go.work pins 5 modules alone) — the sweep is broken" >&2
  exit 1
fi

# go/cli/version.go carries the SAME number a ninth time: `ball version` falls
# back to it whenever the binary has no module stamp (every `go build` from a
# checkout reads "(devel)"). go/cli's TestModuleVersionMatchesGoMod is the drift
# guard, so a bump that skipped this file would go red in the `go` job — but a
# bump script that leaves a known site to a hand edit is not one action, so it
# is rewritten here. The constant is UNPREFIXED (the Rust/Dart/C# CLIs all print
# the bare form), hence the `${version#v}`.
verfile="$root/go/cli/version.go"
if [ ! -f "$verfile" ]; then
  echo "bump: $verfile is missing — go/cli's version fallback must be bumped in lockstep" >&2
  exit 1
fi
if ! grep -Eq '^const moduleVersion = "[0-9]+\.[0-9]+\.[0-9]+"$' "$verfile"; then
  echo "bump: go/cli/version.go has no 'const moduleVersion = \"X.Y.Z\"' line — it moved or was renamed." >&2
  echo "      Refusing rather than silently leaving 'ball version' at the old number." >&2
  exit 1
fi
sed -E -i "s|^const moduleVersion = \"[0-9]+\.[0-9]+\.[0-9]+\"\$|const moduleVersion = \"${version#v}\"|" "$verfile"
echo "ok     go/cli/version.go (moduleVersion -> ${version#v})"

# Nothing anywhere may still name a different version. Match only the
# `<module path> <version>` substring (-o), so a go.work pin's trailing
# `=> ./<dir>` cannot make a correctly-rewritten line look stale.
stale="$(grep -REon "$_INTRA[[:space:]]+$_VER" --include=go.mod --include=go.work "$root/go" "$root/tools" 2>/dev/null | grep -v "[[:space:]]$version\$" || true)"
if [ -n "$stale" ]; then
  echo "bump: these intra-repo references were NOT rewritten to $version:" >&2
  printf '%s\n' "$stale" | sed 's/^/       /' >&2
  exit 1
fi

# Re-derive through the SAME entry point tag-go-modules.yml uses, so the four
# cross-file invariants (all requires agree, no go.mod `replace`, go.work pins
# agree, every required module pinned) are asserted on the result.
derived="$(python3 "$here/build_local_proxy.py" --root "$root" --print-version)"
if [ "$derived" != "$version" ]; then
  echo "bump: after rewriting, build_local_proxy.py --print-version says '$derived', want '$version'" >&2
  exit 1
fi

echo "Go module line: $version ($refs references across ${#candidates[@]} candidate files, $touched file(s) rewritten)"
echo "Next: the six go/<module>/$version tags are cut by .github/workflows/tag-go-modules.yml after this lands on main."
