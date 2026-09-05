#!/usr/bin/env bash
# Create the six `go/<module>/vX.Y.Z` tags for issue #361 (called by
# .github/workflows/tag-go-modules.yml; unit-tested by
# tools/test/test_tag_go_modules.sh so the tagging logic never again ships
# untested inside a workflow that only runs on a manual dispatch).
#
# Contract:
#   $1 = version (vX.Y.Z), $2 = commit sha to tag, $3 = remote name to push to.
#   Runs from the repo root. Enumerates go/*/go.mod, refuses an empty set
#   (positive floor), refuses a HALF-tagged set (all-or-nothing invariant:
#   every intra-repo `require` names the same version, so six tags must land on
#   ONE commit together), is idempotent when all tags exist, and otherwise
#   creates every tag and pushes them in ONE push so they become resolvable
#   together, never partially.
#
# Why one `git tag` call PER TAG: `git tag <name> <commit>` takes exactly one
# tag name; `git tag $six_names $sha` is "fatal: too many arguments" — which is
# exactly how the first live dispatch (run 33939440446, 2026-09-05) failed with
# zero tags created. `git push origin a b c` DOES accept many refs, so the push
# stays a single call.
set -euo pipefail

version="${1:?usage: tag_go_modules.sh <vX.Y.Z> <sha> <remote>}"
sha="${2:?usage: tag_go_modules.sh <vX.Y.Z> <sha> <remote>}"
remote="${3:?usage: tag_go_modules.sh <vX.Y.Z> <sha> <remote>}"

case "$version" in
  v[0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "::error::derived Go module version '$version' is not vX.Y.Z"; exit 1 ;;
esac

modules=()
for dir in go/*/; do
  [ -f "$dir/go.mod" ] || continue
  modules+=("go/$(basename "$dir")/$version")
done
count=${#modules[@]}
# Positive floor: an empty module set must never read as success.
if [ "$count" -lt 1 ]; then
  echo "::error::found no Go modules under go/ — the sweep itself is broken"
  exit 1
fi

existing=0
missing=0
for tag in "${modules[@]}"; do
  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    existing=$((existing + 1))
  else
    missing=$((missing + 1))
  fi
done

if [ "$missing" -eq 0 ]; then
  echo "All $count go/<module>/$version tags already exist — nothing to do."
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "Go modules: $version already tagged ($count modules)" >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi
if [ "$existing" -ne 0 ]; then
  echo "::error::$existing of $count go/<module>/$version tags already exist and $missing do not — refusing to publish a half-tagged module set. Resolve by hand."
  exit 1
fi

for tag in "${modules[@]}"; do
  git tag "$tag" "$sha"
done
# One push: the tags become resolvable together, never partially.
git push "$remote" "${modules[@]}"
echo "Tagged $count Go modules at $version on $sha"
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "Go modules: tagged $count modules at $version" >> "$GITHUB_STEP_SUMMARY"
exit 0
