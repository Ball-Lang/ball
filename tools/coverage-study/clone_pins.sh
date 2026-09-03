#!/usr/bin/env bash
# Shallow-clone every pinned third-party package of a Tier A pin list at its
# recorded commit (issue #493).
#
#   tools/coverage-study/clone_pins.sh <pins.json> <checkouts-dir>
#
# A pin that cannot be fetched is reported as a WARNING and its directory is
# removed: the harness then counts it under "unreachable pins (not scored)".
# A network hiccup must never read as an encoder regression, which is why this
# deliberately does NOT fail the job — the positive-floor guard in
# summarize.sh is what catches "nothing was cloned at all".
set -euo pipefail

pins="${1:?usage: clone_pins.sh <pins.json> <checkouts-dir>}"
dest_root="${2:?usage: clone_pins.sh <pins.json> <checkouts-dir>}"

mkdir -p "$dest_root"

list="$(mktemp)"
# newline="\n" matters: on Windows (where a developer may well run this)
# Python's text stdout would emit CRLF, and the CR would end up inside `ref`,
# making every fetch fail with `invalid refspec` and reporting every pin as
# unreachable — a silent, total loss of measurement.
python3 - "$pins" >"$list" <<'PY'
import json
import sys

sys.stdout.reconfigure(newline="\n")
with open(sys.argv[1], encoding="utf-8") as handle:
    for pin in json.load(handle)["packages"]:
        print(pin["name"], pin["repo"], pin["ref"])
PY

while read -r name repo ref; do
  dest="$dest_root/$name"
  if git init -q "$dest" \
     && git -C "$dest" remote add origin "$repo" \
     && git -C "$dest" fetch -q --depth 1 origin "$ref" \
     && git -C "$dest" checkout -q FETCH_HEAD; then
    echo "cloned $name @ $ref"
  else
    echo "::warning::could not fetch pin $name @ $ref — it will be reported as unreachable, not scored"
    rm -rf "$dest"
  fi
done <"$list"
