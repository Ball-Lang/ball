#!/usr/bin/env bash
# Unit test for the required-status-checks doc guard (issue #655).
#
# WHY: docs/TESTING_STRATEGY.md states, as a load-bearing fact, exactly which
# status checks the `Protect main` ruleset requires — the list a lane reads to
# decide "the checks are green". It was hand-written and byte-identical to the
# live ruleset on 2026-09-14, with NOTHING keeping the two in sync: add a
# required context in the ruleset UI and the doc quietly becomes a lie, which is
# the worst shape for a doc a human trusts to be mechanical.
# `tools/ci/check_required_contexts.sh` compares the two and fails on any
# difference. It is itself a gate, so it needs its own regression coverage: a
# comparator that stopped comparing looks exactly like one that found no drift.
#
# Every case below drives the guard OFFLINE (`--ruleset-json`) against a
# synthetic doc and a synthetic ruleset payload — no network, no repo state,
# sub-second. The guard's LIVE leg (the real doc vs. the real ruleset) runs
# beside this one in ci.yml's always-on `Proto Checks` job.
#
# Usage: bash tools/test/test_check_required_contexts.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
GUARD="$ROOT/tools/ci/check_required_contexts.sh"
REAL_DOC="$ROOT/docs/TESTING_STRATEGY.md"

if [ ! -f "$GUARD" ]; then
  echo "::error::missing $GUARD — the required-contexts guard this test drives does not exist (issue #655)."
  echo "Results: 0 passed, 1 failed, 1 total"
  exit 1
fi

pass=0
fail=0
SCRATCH="$(mktemp -d)"
cleanup() {
  rm -rf "$SCRATCH"
  return 0
}
trap cleanup EXIT

# The list the live ruleset carries today. Used to build synthetic payloads —
# the guard is never asked to trust this copy, only to compare two inputs.
LIVE_CONTEXTS='Ball Artifact Freshness
C#
C++ (macos-latest)
C++ (ubuntu-latest)
C++ (windows-latest)
C++ Self-Host Tally (every fixture must pass)
CLI Verb Parity
Dart
Dart Coverage Ratchet
Dart Regression Gate (engine + encoder + compiler)
Detect changed stacks
Go
Proto Checks
Protobuf Codegen (gen + rpc)
Python
Rust
TS Regression Gate (engine + compiler)
TypeScript
Upstream Conformance (Editions)'

# make_doc <file> <prose-count> <contexts-as-lines>
make_doc() {
  local file="$1" count="$2" contexts="$3" line
  {
    echo "# Testing strategy (synthetic)"
    echo
    echo "The list is not a convention: it is enforced by the repository's"
    echo "\`Protect main\` ruleset, whose **${count} required status check contexts** are:"
    echo
    echo "<!-- BEGIN REQUIRED-CONTEXTS repo=Ball-Lang/ball ruleset=17056238 -->"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf -- '- `%s`\n' "$line"
    done <<<"$contexts"
    echo "<!-- END REQUIRED-CONTEXTS -->"
    echo
    echo "A PR is BLOCKED until all ${count} report success, so \"the checks are"
    echo "green\" is a mechanical statement about that list."
  } >"$file"
}

# make_ruleset <file> <name> <enforcement> <contexts-as-lines>
make_ruleset() {
  local file="$1" name="$2" enforcement="$3" contexts="$4"
  CTX="$contexts" NAME="$name" ENF="$enforcement" python3 - "$file" <<'PY'
import json
import os
import sys

contexts = [c for c in os.environ["CTX"].splitlines() if c.strip()]
doc = {
    "id": 17056238,
    "name": os.environ["NAME"],
    "target": "branch",
    "enforcement": os.environ["ENF"],
    "rules": [
        {"type": "deletion"},
        {
            "type": "required_status_checks",
            "parameters": {
                "strict_required_status_checks_policy": False,
                "required_status_checks": [
                    {"context": c, "integration_id": 15368} for c in contexts
                ],
            },
        },
    ],
}
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(doc, fh, indent=2)
PY
}

# expect <name> <want-exit> <doc> <ruleset-json> [needle...]
expect() {
  local name="$1" want="$2" doc="$3" rules="$4"
  shift 4
  local out rc=0 ok=1 needle
  out="$(bash "$GUARD" --doc "$doc" --ruleset-json "$rules" 2>&1)" || rc=$?
  [ "$rc" -eq "$want" ] || ok=0
  for needle in "$@"; do
    case "$out" in
    *"$needle"*) ;;
    *) ok=0 ;;
    esac
  done
  if [ "$ok" -eq 1 ]; then
    pass=$((pass + 1))
    echo "PASS  $name"
  else
    fail=$((fail + 1))
    echo "FAIL  $name: expected exit $want, got $rc"
    printf '%s\n' "$out" | sed 's/^/  | /'
  fi
}

RULES_OK="$SCRATCH/rules-ok.json"
make_ruleset "$RULES_OK" "Protect main" "active" "$LIVE_CONTEXTS"

# ── 1. The doc and the ruleset agree. ───────────────────────────────────────
DOC_OK="$SCRATCH/doc-ok.md"
make_doc "$DOC_OK" 19 "$LIVE_CONTEXTS"
expect "doc matches the ruleset -> exit 0" 0 "$DOC_OK" "$RULES_OK" \
  "Results: " " passed, 0 failed,"

# ── 2. A context required by the ruleset but missing from the doc. ──────────
DOC_SHORT="$SCRATCH/doc-short.md"
make_doc "$DOC_SHORT" 18 "$(grep -v '^Dart Coverage Ratchet$' <<<"$LIVE_CONTEXTS")"
expect "a context missing from the doc -> exit 1" 1 "$DOC_SHORT" "$RULES_OK" \
  "only in the ruleset" "Dart Coverage Ratchet"

# ── 3. A context the doc invents that the ruleset does not require. ─────────
DOC_EXTRA="$SCRATCH/doc-extra.md"
make_doc "$DOC_EXTRA" 20 "$LIVE_CONTEXTS
Zebra Imaginary Gate"
expect "a fabricated context in the doc -> exit 1" 1 "$DOC_EXTRA" "$RULES_OK" \
  "only in the doc" "Zebra Imaginary Gate"

# ── 4. The prose count must track the list it introduces. ──────────────────
DOC_COUNT="$SCRATCH/doc-count.md"
make_doc "$DOC_COUNT" 18 "$LIVE_CONTEXTS"
expect "prose count disagreeing with the list -> exit 1" 1 "$DOC_COUNT" "$RULES_OK" \
  "prose count"

# ── 5. An unsorted list: the comparison would still pass, but a human diff of
#      the next change would be unreadable. Order is part of the contract. ───
DOC_UNSORTED="$SCRATCH/doc-unsorted.md"
make_doc "$DOC_UNSORTED" 19 "$(tac <<<"$LIVE_CONTEXTS")"
expect "an unsorted doc list -> exit 1" 1 "$DOC_UNSORTED" "$RULES_OK" "sorted"

# ── 6. A line inside the block that is not a `- \`context\`` bullet. ────────
DOC_MALFORMED="$SCRATCH/doc-malformed.md"
make_doc "$DOC_MALFORMED" 19 "$LIVE_CONTEXTS"
python3 - "$DOC_MALFORMED" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
text = text.replace("- `Go`\n", "- Go (backticks dropped)\n")
open(path, "w", encoding="utf-8").write(text)
PY
expect "a malformed bullet inside the block -> exit 1" 1 "$DOC_MALFORMED" "$RULES_OK" \
  "not a"

# ── 7. No markers at all — the guard must not "find" an empty list. ─────────
DOC_NOMARKERS="$SCRATCH/doc-nomarkers.md"
printf '# Testing strategy\n\nNo marked list here at all.\n' >"$DOC_NOMARKERS"
expect "a doc with no markers -> exit 1" 1 "$DOC_NOMARKERS" "$RULES_OK" \
  "BEGIN REQUIRED-CONTEXTS"

# ── 8. Markers with nothing between them (the positive floor). ─────────────
DOC_EMPTY="$SCRATCH/doc-empty.md"
make_doc "$DOC_EMPTY" 0 ""
expect "an empty doc list -> exit 1" 1 "$DOC_EMPTY" "$RULES_OK" "empty"

# ── 9. A duplicated context in the doc. ────────────────────────────────────
DOC_DUP="$SCRATCH/doc-dup.md"
make_doc "$DOC_DUP" 20 "$LIVE_CONTEXTS
Upstream Conformance (Editions)"
expect "a duplicated doc entry -> exit 1" 1 "$DOC_DUP" "$RULES_OK" "twice"

# ── 10. A ruleset that carries no required_status_checks rule. ─────────────
RULES_NORULE="$SCRATCH/rules-norule.json"
printf '{"id":17056238,"name":"Protect main","target":"branch","enforcement":"active","rules":[{"type":"deletion"}]}\n' \
  >"$RULES_NORULE"
expect "a ruleset with no required_status_checks rule -> exit 1" 1 "$DOC_OK" "$RULES_NORULE" \
  "required_status_checks"

# ── 11. A ruleset that exists but is not enforcing. ────────────────────────
RULES_DISABLED="$SCRATCH/rules-disabled.json"
make_ruleset "$RULES_DISABLED" "Protect main" "disabled" "$LIVE_CONTEXTS"
expect "a disabled ruleset -> exit 1" 1 "$DOC_OK" "$RULES_DISABLED" "enforcement"

# ── 12. The id was reassigned to some other ruleset. ──────────────────────
RULES_RENAMED="$SCRATCH/rules-renamed.json"
make_ruleset "$RULES_RENAMED" "Something else entirely" "active" "$LIVE_CONTEXTS"
expect "a ruleset with a different name -> exit 1" 1 "$DOC_OK" "$RULES_RENAMED" \
  "Something else entirely"

# ── 13. A ruleset that requires zero checks (the other positive floor). ────
RULES_ZERO="$SCRATCH/rules-zero.json"
make_ruleset "$RULES_ZERO" "Protect main" "active" ""
expect "a ruleset requiring zero checks -> exit 1" 1 "$DOC_OK" "$RULES_ZERO" "zero"

# ── 14. Unparseable ruleset JSON. ─────────────────────────────────────────
RULES_BAD="$SCRATCH/rules-bad.json"
printf '{"name": "Protect main", \n' >"$RULES_BAD"
expect "unparseable ruleset JSON -> exit 1" 1 "$DOC_OK" "$RULES_BAD" "JSON"

# ── 15. Inputs that are not there at all fail loud, never vacuously pass. ──
expect "a missing doc -> exit 1" 1 "$SCRATCH/no-such-doc.md" "$RULES_OK" "::error::"
expect "a missing ruleset file -> exit 1" 1 "$DOC_OK" "$SCRATCH/no-such-rules.json" "::error::"

# ── 16. THE REAL DOC parses. Without this the whole suite could be green
#       against synthetic docs while the file that actually ships is
#       unparseable by the guard — the "nothing ran" trap one level up. The
#       ruleset here is synthesised FROM the real doc's own list, so this case
#       tests the parser, not the live ruleset (that is the guard's live leg).
REAL_LIST="$SCRATCH/real-list.txt"
python3 - "$REAL_DOC" "$REAL_LIST" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(
    r"<!-- BEGIN REQUIRED-CONTEXTS[^>]*-->\n(.*?)<!-- END REQUIRED-CONTEXTS -->",
    text,
    re.S,
)
if not m:
    sys.stderr.write("the real doc carries no REQUIRED-CONTEXTS markers\n")
    sys.exit(1)
names = re.findall(r"^- `(.+)`$", m.group(1), re.M)
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(names) + "\n")
PY
real_rc=$?
if [ "$real_rc" -ne 0 ]; then
  fail=$((fail + 1))
  echo "FAIL  the real docs/TESTING_STRATEGY.md carries no parseable REQUIRED-CONTEXTS block"
else
  RULES_REAL="$SCRATCH/rules-real.json"
  make_ruleset "$RULES_REAL" "Protect main" "active" "$(cat "$REAL_LIST")"
  expect "the real doc parses and self-compares -> exit 0" 0 "$REAL_DOC" "$RULES_REAL" \
    "Results: " " passed, 0 failed,"
fi

total=$((pass + fail))
echo "Results: $pass passed, $fail failed, $total total"
if [ "$pass" -lt 16 ]; then
  echo "::error::required-contexts guard test executed fewer cases than expected ($pass < 16) — a test that ran nothing is not a passing test."
  exit 1
fi
[ "$fail" -eq 0 ] || exit 1
