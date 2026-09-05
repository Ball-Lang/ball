#!/usr/bin/env bash
# Unit test for tools/go-module-proxy/tag_go_modules.sh (issue #361).
#
# The tagging logic used to live inline in .github/workflows/tag-go-modules.yml
# and could only ever run on a manual dispatch — so its one real bug shipped
# untested: `git tag $six_names $sha` is "fatal: too many arguments" (git tag
# takes ONE name), and the first live dispatch (run 33939440446, 2026-09-05)
# created zero tags. This test builds a scratch repo with a bare `origin`, a
# `go/` tree shaped like the real one, and drives the script through every
# branch it has. It runs in ci.yml's always-on `proto` job, so a regression to
# the one-call form goes red on the PR, not on the next release.
set -euo pipefail

script="$(cd "$(dirname "$0")/../.." && pwd)/tools/go-module-proxy/tag_go_modules.sh"
[ -f "$script" ] || { echo "::error::missing $script"; exit 1; }

passed=0; failed=0
ok()   { passed=$((passed + 1)); echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; }

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

fresh_repo() {
  # $1 = dir. A work repo with six go/*/go.mod modules and a bare origin.
  rm -rf "$1"; mkdir -p "$1/origin.git" "$1/work"
  git -C "$1/origin.git" init -q --bare
  git -C "$1/work" init -q
  git -C "$1/work" config user.name t; git -C "$1/work" config user.email t@t
  for m in cli compiler encoder engine runtime shared; do
    mkdir -p "$1/work/go/$m"; echo "module github.com/ball-lang/ball/go/$m" > "$1/work/go/$m/go.mod"
  done
  git -C "$1/work" add -A && git -C "$1/work" commit -q -m init
  git -C "$1/work" remote add origin "$1/origin.git"
  git -C "$1/work" push -q origin HEAD:refs/heads/main
}

# 1. Six modules, no tags: creates all six, pushes them in one go.
fresh_repo "$scratch/a"
sha="$(git -C "$scratch/a/work" rev-parse HEAD)"
if (cd "$scratch/a/work" && bash "$script" v0.1.0 "$sha" origin >/dev/null 2>&1); then
  n_local="$(git -C "$scratch/a/work" tag -l 'go/*/v0.1.0' | wc -l)"
  n_remote="$(git -C "$scratch/a/origin.git" tag -l 'go/*/v0.1.0' | wc -l)"
  if [ "$n_local" -eq 6 ] && [ "$n_remote" -eq 6 ]; then ok "creates and pushes all six tags (local=$n_local remote=$n_remote)"; else fail "expected 6/6 tags, got local=$n_local remote=$n_remote"; fi
  tagged="$(git -C "$scratch/a/origin.git" rev-parse 'go/compiler/v0.1.0^{commit}')"
  [ "$tagged" = "$sha" ] && ok "tags point at the requested sha" || fail "tag points at $tagged, expected $sha"
else
  fail "script exited non-zero on a clean six-module repo"
fi

# 2. Idempotent: all six exist -> exit 0, nothing pushed twice.
if (cd "$scratch/a/work" && bash "$script" v0.1.0 "$sha" origin 2>&1 | grep -q "already exist"); then ok "idempotent when all tags exist"; else fail "second run did not report already-tagged"; fi

# 3. Half-tagged set is refused (exit 1) and nothing is pushed.
fresh_repo "$scratch/b"
sha="$(git -C "$scratch/b/work" rev-parse HEAD)"
git -C "$scratch/b/work" tag go/cli/v0.1.0 "$sha"
if (cd "$scratch/b/work" && bash "$script" v0.1.0 "$sha" origin >/dev/null 2>&1); then fail "half-tagged set was NOT refused"; else
  n_remote="$(git -C "$scratch/b/origin.git" tag -l 'go/*/v0.1.0' | wc -l)"
  [ "$n_remote" -eq 0 ] && ok "half-tagged set refused, nothing pushed" || fail "half-tagged refusal still pushed $n_remote tags"
fi

# 4. Empty module set is refused (positive floor).
rm -rf "$scratch/c"; mkdir -p "$scratch/c/work"; git -C "$scratch/c/work" init -q
if (cd "$scratch/c/work" && bash "$script" v0.1.0 HEAD origin >/dev/null 2>&1); then fail "empty module set was NOT refused"; else ok "empty module set refused"; fi

# 5. Bad version string is refused.
if (cd "$scratch/a/work" && bash "$script" 0.1.0 "$sha" origin >/dev/null 2>&1); then fail "non-vX.Y.Z version accepted"; else ok "non-vX.Y.Z version refused"; fi

# 6. The workflow delegates to this script (no inline `git tag` left to drift).
wf="$(cd "$(dirname "$0")/../.." && pwd)/.github/workflows/tag-go-modules.yml"
if grep -q "tools/go-module-proxy/tag_go_modules.sh" "$wf" && ! grep -qE '^\s+git tag ' "$wf"; then ok "workflow delegates to the script and has no inline git tag"; else fail "workflow does not delegate (or still tags inline)"; fi

echo "Results: $passed passed, $failed failed, $((passed + failed)) total"
[ "$failed" -eq 0 ] && [ "$passed" -ge 1 ]
