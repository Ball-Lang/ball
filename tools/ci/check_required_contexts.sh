#!/usr/bin/env bash
# Doc-vs-ruleset guard for the required status checks (issue #655).
#
# WHY THIS EXISTS: docs/TESTING_STRATEGY.md states which status checks the
# `Protect main` ruleset requires, and says so as a MECHANICAL claim — "a PR is
# BLOCKED until all N report success, so 'the checks are green' is not a
# judgement call". A lane reads that list to decide whether a PR is actually
# gated on the thing it just changed.
#
# NOTHING KEPT IT TRUE. The list was hand-written, byte-identical to ruleset
# 17056238 on 2026-09-14, and the ruleset is edited in a web UI that touches no
# file in this repo. Add a required context there and the doc silently understates
# the gate; remove one and it silently overstates it — and the overstating
# direction is the dangerous one, because a lane concludes a PR is gated on a
# check that is not required at all. #644's review called this out (advisory 4)
# after verifying the two matched THAT DAY, which is exactly the shape of fact
# this repo refuses to leave ungated.
#
# HOW: `GET /repos/{owner}/{repo}/rulesets/{ruleset_id}` needs only "Metadata"
# repository permissions (read), and "can be used without authentication or the
# aforementioned permissions if only public resources are requested" —
# https://docs.github.com/en/rest/repos/rules?apiVersion=2022-11-28#get-a-repository-ruleset
# Ball-Lang/ball is public, so the workflow's own GITHUB_TOKEN reads it; no
# documented extra token and no scheduled-job workaround are needed. (The
# endpoint redacts only `bypass_actors` without write access; this guard never
# reads it.) The repo and ruleset id are parsed FROM the doc's own marker, so the
# guard can never quietly compare against some other ruleset than the one the doc
# names.
#
# POSITIVE FLOOR: a comparator that compared nothing must not report success.
# This refuses an empty doc list, a ruleset that requires zero checks, a doc
# whose prose count disagrees with its own list, and it exits 1 if fewer than 5
# assertions ran. tools/test/test_check_required_contexts.sh drives the negative
# controls offline.
#
# Usage:
#   bash tools/ci/check_required_contexts.sh                     # gate the repo
#   bash tools/ci/check_required_contexts.sh --doc FILE          # another doc
#   bash tools/ci/check_required_contexts.sh --ruleset-json FILE # offline payload
#
# Exits 0 when the doc and the ruleset agree; 1 otherwise, naming the difference.
# Needs bash + python3 + curl (the runner image ships all three), so it runs in
# ci.yml's always-on `Proto Checks` job with no toolchain.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DOC="$ROOT/docs/TESTING_STRATEGY.md"
RULESET_JSON=""

while [ $# -gt 0 ]; do
  case "$1" in
  --doc)
    DOC="$2"
    shift 2
    ;;
  --doc=*)
    DOC="${1#--doc=}"
    shift
    ;;
  --ruleset-json)
    RULESET_JSON="$2"
    shift 2
    ;;
  --ruleset-json=*)
    RULESET_JSON="${1#--ruleset-json=}"
    shift
    ;;
  -h | --help)
    sed -n '2,45p' "${BASH_SOURCE[0]}"
    exit 0
    ;;
  *)
    echo "::error::unknown argument: $1" >&2
    exit 2
    ;;
  esac
done

if [ ! -f "$DOC" ]; then
  echo "::error::doc not found: $DOC"
  echo "Results: 0 passed, 1 failed, 1 total"
  exit 1
fi

# ── the doc's marked list, and the ruleset it names ─────────────────────────
# The markers are machine-readable on purpose: prose around them can be rewritten
# freely, and a guard that had to find the list by matching English would drift
# with the first editorial pass.
MARKER_LINE=""
if grep -q -- '<!-- BEGIN REQUIRED-CONTEXTS' "$DOC"; then
  MARKER_LINE="$(grep -m1 -- '<!-- BEGIN REQUIRED-CONTEXTS' "$DOC")"
fi
if [ -z "$MARKER_LINE" ]; then
  echo "::error::$DOC carries no '<!-- BEGIN REQUIRED-CONTEXTS … -->' marker — this guard compares the doc's required-status-check list against the live ruleset and refuses to guess where that list is (#655)."
  echo "Results: 0 passed, 1 failed, 1 total"
  exit 1
fi

REPO="$(sed -n 's/.*repo=\([^ ]*\).*/\1/p' <<<"$MARKER_LINE")"
RULESET_ID="$(sed -n 's/.*ruleset=\([0-9]*\).*/\1/p' <<<"$MARKER_LINE")"
if [ -z "$REPO" ] || [ -z "$RULESET_ID" ]; then
  echo "::error::$DOC's REQUIRED-CONTEXTS marker must name the ruleset it documents, as 'repo=<owner>/<name> ruleset=<id>'; found: $MARKER_LINE"
  echo "Results: 0 passed, 1 failed, 1 total"
  exit 1
fi

# ── fetch the live ruleset (unless an offline payload was supplied) ─────────
FETCHED=""
cleanup() {
  [ -n "$FETCHED" ] && rm -f "$FETCHED"
  return 0
}
trap cleanup EXIT

if [ -z "$RULESET_JSON" ]; then
  FETCHED="$(mktemp)"
  RULESET_JSON="$FETCHED"
  url="https://api.github.com/repos/${REPO}/rulesets/${RULESET_ID}"
  token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  if [ -n "$token" ]; then
    mode="authenticated (GITHUB_TOKEN)"
  else
    mode="anonymous (public repository)"
  fi

  status=""
  attempt=1
  while [ "$attempt" -le 3 ]; do
    if [ -n "$token" ]; then
      status="$(curl -sS -o "$RULESET_JSON" -w '%{http_code}' \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -H "Authorization: Bearer ${token}" \
        "$url")"
    else
      status="$(curl -sS -o "$RULESET_JSON" -w '%{http_code}' \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$url")"
    fi
    echo "GET $url -> HTTP $status ($mode, attempt $attempt/3)"
    [ "$status" = "200" ] && break
    attempt=$((attempt + 1))
    [ "$attempt" -le 3 ] && sleep 5
  done

  if [ "$status" != "200" ]; then
    echo "::error::could not read ruleset ${RULESET_ID} of ${REPO}: HTTP $status after 3 attempts, $mode. GET /repos/{owner}/{repo}/rulesets/{ruleset_id} needs only \"Metadata\" repository permissions (read) and works unauthenticated for a public repository (https://docs.github.com/en/rest/repos/rules?apiVersion=2022-11-28#get-a-repository-ruleset), so this is an outage or a permissions change — NOT something to skip past."
    head -c 500 "$RULESET_JSON" | sed 's/^/  | /'
    echo
    echo "Results: 0 passed, 1 failed, 1 total"
    exit 1
  fi
fi

if [ ! -f "$RULESET_JSON" ]; then
  echo "::error::ruleset payload not found: $RULESET_JSON"
  echo "Results: 0 passed, 1 failed, 1 total"
  exit 1
fi

# ── the comparison ──────────────────────────────────────────────────────────
python3 - "$DOC" "$RULESET_JSON" "$RULESET_ID" <<'PY'
import json
import re
import sys

doc_path, rules_path, ruleset_id = sys.argv[1], sys.argv[2], sys.argv[3]

passed = 0
failures = []


def ok(msg):
    global passed
    passed += 1
    print(f"PASS {msg}")


def bad(msg):
    failures.append(msg)
    print(f"FAIL {msg}")


def die(msg):
    print(f"::error::{msg}")
    print("Results: 0 passed, 1 failed, 1 total")
    sys.exit(1)


text = open(doc_path, encoding="utf-8").read()

block = re.search(
    r"<!-- BEGIN REQUIRED-CONTEXTS[^>]*-->\n(?P<body>.*?)<!-- END REQUIRED-CONTEXTS -->",
    text,
    re.S,
)
if block is None:
    die(
        f"{doc_path}: the '<!-- BEGIN REQUIRED-CONTEXTS … -->' marker has no matching "
        "'<!-- END REQUIRED-CONTEXTS -->'"
    )

doc_contexts = []
for line in block.group("body").splitlines():
    if not line.strip():
        continue
    m = re.fullmatch(r"- `(.+)`", line)
    if m is None:
        die(
            f"{doc_path}: the line {line!r} inside the REQUIRED-CONTEXTS block is not a "
            "`- `context`` bullet. Every line between the markers is compared against the "
            "live ruleset, so nothing else may live there."
        )
    doc_contexts.append(m.group(1))

if not doc_contexts:
    die(
        f"{doc_path}: the required-contexts list is empty. A guard that compared an empty "
        "list against the ruleset would pass only by removing every entry from the doc — "
        "refusing (#655)."
    )

dupes = sorted({c for c in doc_contexts if doc_contexts.count(c) > 1})
if dupes:
    bad(f"{doc_path} lists a context twice: " + ", ".join(dupes))

if doc_contexts != sorted(doc_contexts):
    bad(
        f"{doc_path}: the required-contexts list must be sorted, so the next change to it "
        "is a one-line diff instead of a re-ordering. Out of order at: "
        + next(
            a
            for a, b in zip(doc_contexts, sorted(doc_contexts))
            if a != b
        )
    )

# The prose numbers that INTRODUCE the list ("19 required status check contexts",
# "all 19 report success") are the part a human actually reads. A list that grew
# by one while the sentence still says 19 is drift too.
count_claims = [
    int(n)
    for n in re.findall(r"\*\*(\d+) required status check contexts\*\*", text)
    + re.findall(r"all (\d+) report success", text)
]
if not count_claims:
    bad(
        f"{doc_path}: no prose count found ('**N required status check contexts**' / "
        "'all N report success'). The list's own size must be stated where a human reads it."
    )
else:
    wrong = sorted({n for n in count_claims if n != len(doc_contexts)})
    if wrong:
        bad(
            f"{doc_path}: the prose count says "
            + ", ".join(str(n) for n in wrong)
            + f" but the marked list has {len(doc_contexts)} entries"
        )
    else:
        ok(
            f"{doc_path}'s prose count agrees with its {len(doc_contexts)}-entry list "
            f"({len(count_claims)} statement(s))"
        )

try:
    with open(rules_path, encoding="utf-8") as fh:
        ruleset = json.load(fh)
except json.JSONDecodeError as exc:
    die(f"{rules_path} is not parseable JSON: {exc}")

if not isinstance(ruleset, dict):
    die(f"{rules_path} does not parse to a JSON object")

name = str(ruleset.get("name") or "")
if name != "Protect main":
    die(
        f"ruleset {ruleset_id} is named {name!r}, not 'Protect main' — the id the doc "
        "names now points at a different ruleset, so this comparison would be meaningless."
    )
ok(f"ruleset {ruleset_id} is still `Protect main`")

enforcement = str(ruleset.get("enforcement") or "")
if enforcement != "active":
    die(
        f"ruleset {ruleset_id}'s enforcement is {enforcement!r}, not 'active' — the doc "
        "claims these checks BLOCK a PR, and a non-enforcing ruleset blocks nothing."
    )
ok(f"ruleset {ruleset_id} is actively enforced")

rules = ruleset.get("rules")
rules = rules if isinstance(rules, list) else []
live_contexts = []
found_rule = False
for rule in rules:
    if not isinstance(rule, dict) or rule.get("type") != "required_status_checks":
        continue
    found_rule = True
    params = rule.get("parameters")
    params = params if isinstance(params, dict) else {}
    for check in params.get("required_status_checks") or []:
        if isinstance(check, dict) and check.get("context"):
            live_contexts.append(str(check["context"]))

if not found_rule:
    die(
        f"ruleset {ruleset_id} carries no `required_status_checks` rule — the doc's whole "
        "'a PR is BLOCKED until all N report success' claim rests on it."
    )
if not live_contexts:
    die(
        f"ruleset {ruleset_id} requires zero status checks. Comparing a doc list against an "
        "empty ruleset would 'pass' by emptying the doc — refusing (#655)."
    )
ok(f"ruleset {ruleset_id} requires {len(live_contexts)} status check context(s)")

doc_set = set(doc_contexts)
live_set = set(live_contexts)

only_live = sorted(live_set - doc_set)
only_doc = sorted(doc_set - live_set)

if only_live:
    bad(
        "only in the ruleset (missing from the doc — a lane reading "
        f"{doc_path} would not know these gate the PR): " + ", ".join(only_live)
    )
if only_doc:
    bad(
        "only in the doc (not required by the ruleset — a lane would believe the PR is "
        "gated on a check that blocks nothing): " + ", ".join(only_doc)
    )
if not (only_live or only_doc):
    ok(
        f"all {len(doc_contexts)} documented contexts match ruleset {ruleset_id} exactly"
    )

total = passed + len(failures)
print(f"Results: {passed} passed, {len(failures)} failed, {total} total")
if failures:
    print(
        f"::error::{doc_path} and ruleset {ruleset_id} disagree about the required status "
        "checks. Fix the doc (or the ruleset) — the list is a mechanical claim, not prose "
        "(issue #655)."
    )
    sys.exit(1)
if passed < 5:
    print(
        f"::error::only {passed} assertion(s) ran — a comparator that checked almost "
        "nothing is not a passing guard."
    )
    sys.exit(1)
sys.exit(0)
PY
