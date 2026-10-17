#!/usr/bin/env bash
# Mirror the six published `go/<module>/vX.Y.Z` tags into the Go release
# line's own `go-modules/vX.Y.Z` channel tag, LOCALLY ONLY — never pushed
# (issue #623, extracted to its own script by issue #879).
#
# WHY THIS EXISTS: semantic-release computes `semver.inc(lastRelease.version,
# type)` and falls back to 1.0.0 when it finds NO tag matching `tagFormat`
# (lib/get-next-version.js). The Go release line's tagFormat —
# `go-modules/vX.Y.Z` — is new (#623), so its first run would otherwise jump
# the Go module line from 0.2.x to 1.0.0: a legal version, a silent lie about
# API stability, and one breaking change from the v2 module-path cliff.
#
# The line's real history is already in the repo, as the six
# `go/<module>/vX.Y.Z` tags. Mirroring them into the channel tag ONCE, LOCALLY
# makes both a real run and a dry-run rehearsal compute the SAME version —
# and it is a permanent no-op from the first real `go-modules/v*` tag onward
# (the common-case early-return below).
#
# Called by both tools/release/open_go_release_pr.sh (Phase 1 — the computed
# version must account for it) and go-release.yml's own `workflow_dispatch`
# rehearsal step (so a rehearsal dispatched directly on `main`, before the
# very first release through this mechanism, computes the real next version
# instead of 1.0.0).
#
# Fails loud rather than guessing: if the module tags for the version in the
# tree are missing, or do not all sit on one commit, there is no published
# line to continue from and the operator must look.
#
# Usage: tools/go-module-proxy/bootstrap_channel_tag.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT"

existing="$(git tag --list 'go-modules/v*' | tr '\n' ' ')"
if [ -n "${existing// /}" ]; then
  echo "Channel tag line already exists:${existing% } — nothing to bootstrap."
  exit 0
fi

version="$(python3 "$HERE/build_local_proxy.py" --print-version)"
sha=""
missing=()
count=0
for dir in go/*/; do
  [ -f "$dir/go.mod" ] || continue
  count=$((count + 1))
  tag="go/$(basename "$dir")/$version"
  if ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    missing+=("$tag")
    continue
  fi
  at="$(git rev-list -n1 "$tag")"
  if [ -z "$sha" ]; then
    sha="$at"
  elif [ "$sha" != "$at" ]; then
    echo "::error::$tag points at $at but a sibling module tag points at $sha — the $version module set is split across commits, which no consumer can resolve consistently. Refusing to bootstrap a version line from it." >&2
    exit 1
  fi
done
if [ "$count" -lt 1 ]; then
  echo "::error::found no Go modules under go/ — the sweep itself is broken" >&2
  exit 1
fi
if [ "${#missing[@]}" -ne 0 ]; then
  echo "::error::the Go module line in this tree is $version, but these tags do not exist: ${missing[*]}. There is no published line to continue from; cut them first by dispatching tag-go-modules.yml at main." >&2
  exit 1
fi
git tag "go-modules/$version" "$sha"
echo "Bootstrapped go-modules/$version at $sha (local only, from the $count published module tags)."
