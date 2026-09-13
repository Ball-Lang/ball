#!/usr/bin/env bash
# Drift guard for the conformance matrix's path filter (issue #619).
#
# WHY THIS EXISTS: `.github/workflows/conformance-matrix.yml` is a PR gate since
# #619, and BOTH of its triggers — `push` (to main) and `pull_request` — are
# path-filtered by the SAME list. The file expresses that with a YAML anchor
# (`paths: &matrix_paths`) and an alias (`paths: *matrix_paths`), so today there
# is literally one list. The failure this guard exists for is the next edit:
# someone adds a language directory, or a tool rewrites the file, and the two
# triggers end up with two hand-kept copies that disagree.
#
# THAT DRIFT IS INVISIBLE WITHOUT A GATE. A path present in `push` but missing
# from `pull_request` means a PR that touches only that path gets NO matrix rows
# at all — and an absent check reads as green (the same failure mode #619 was
# filed to close, and the one that has bitten this repo before: see ci.yml's
# "Changed-stacks truth table" and "Release dispatch wiring guard" steps). The
# reverse direction is a matrix that runs on PRs and then never re-runs on main.
#
# HOW IT CHECKS: the comparison is made on the PARSED YAML, after the parser has
# expanded the alias. So it passes trivially while the anchor is in place, and
# it is exactly the assertion that still bites if a future edit replaces the
# alias with a literal list — which is the only shape in which this can break.
#
# POSITIVE FLOOR: a guard that found nothing to compare must not report success.
# A missing `push`/`pull_request` trigger, an absent or empty `paths:` list, or
# a parse failure are all hard errors — "0 paths compared, 0 differences" is
# rejected, never treated as agreement.
#
# Usage:
#   bash tools/ci/check_matrix_paths.sh                  # gate the repo
#   bash tools/ci/check_matrix_paths.sh --file FILE       # a synthetic workflow
#   bash tools/ci/check_matrix_paths.sh --self-test       # drive the cases
#
# Exits 0 when the two lists are identical and non-empty; 1 otherwise, printing
# every path that is in one trigger only. Needs bash + python3 (the runner image
# ships both), so it runs in ci.yml's always-on `proto` job with no toolchain.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/conformance-matrix.yml"
SELF_TEST=0

while [ $# -gt 0 ]; do
  case "$1" in
  --file)
    WORKFLOW="$2"
    shift 2
    ;;
  --file=*)
    WORKFLOW="${1#--file=}"
    shift
    ;;
  --self-test)
    SELF_TEST=1
    shift
    ;;
  -h | --help)
    sed -n '2,40p' "${BASH_SOURCE[0]}"
    exit 0
    ;;
  *)
    echo "::error::unknown argument: $1" >&2
    exit 2
    ;;
  esac
done

# ── the check itself ────────────────────────────────────────────────────────
# Kept in python3 because a YAML anchor can only be resolved by a YAML parser:
# a grep/awk comparison of the two blocks would "pass" on the anchor form by
# reading the alias line as a path, which is precisely the wrong answer.
check_file() {
  local file="$1"
  python3 - "$file" <<'PY'
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - the runner image ships PyYAML
    print("::error::PyYAML is required by tools/ci/check_matrix_paths.sh")
    sys.exit(1)

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
except FileNotFoundError:
    print(f"::error::workflow not found: {path}")
    sys.exit(1)
except yaml.YAMLError as exc:
    print(f"::error::{path} is not parseable YAML: {exc}")
    sys.exit(1)

if not isinstance(doc, dict):
    print(f"::error::{path} does not parse to a mapping")
    sys.exit(1)

# YAML 1.1 (what PyYAML implements) resolves a bare `on:` key to the BOOLEAN
# True, not the string "on". Accept either so this works against both a real
# workflow and a quoted-key fixture.
triggers = doc.get(True, doc.get("on"))
if not isinstance(triggers, dict):
    print(f"::error::{path} has no `on:` trigger mapping")
    sys.exit(1)

lists = {}
for trigger in ("push", "pull_request"):
    block = triggers.get(trigger)
    if not isinstance(block, dict):
        print(
            f"::error::{path}: `on.{trigger}` is missing or not a mapping — the "
            "conformance matrix must be triggered by BOTH push and pull_request "
            "(issue #619)."
        )
        sys.exit(1)
    paths = block.get("paths")
    if not isinstance(paths, list) or not paths:
        print(
            f"::error::{path}: `on.{trigger}.paths` is missing or empty. An "
            "empty filter is not 'no restriction' here — it is an unchecked "
            "gate, and this guard refuses to compare zero paths."
        )
        sys.exit(1)
    lists[trigger] = [str(p) for p in paths]

push, pull = lists["push"], lists["pull_request"]
only_push = [p for p in push if p not in pull]
only_pull = [p for p in pull if p not in push]

if only_push or only_pull:
    print(
        f"::error::{path}: the `push` and `pull_request` path filters have "
        "drifted. They MUST be one list referenced twice (the `&matrix_paths` "
        "anchor + `*matrix_paths` alias) — see issue #619."
    )
    for p in only_push:
        print(f"  only in push:         {p}")
    for p in only_pull:
        print(f"  only in pull_request: {p}")
    print(f"Results: 0 passed, 1 failed, 1 total ({len(push)} push paths, {len(pull)} pull_request paths)")
    sys.exit(1)

if push != pull:
    # Same members, different order. Harmless to GitHub, but it means the alias
    # was replaced by a copy — say so before the members diverge too.
    print(
        f"::error::{path}: the `push` and `pull_request` path filters contain "
        "the same entries in a DIFFERENT ORDER, so they are two copies rather "
        "than one aliased list. Restore the `*matrix_paths` alias (issue #619)."
    )
    print("Results: 0 passed, 1 failed, 1 total")
    sys.exit(1)

print(f"conformance-matrix.yml: push and pull_request share one {len(push)}-entry path filter.")
for p in push:
    print(f"  {p}")
print(f"Results: {len(push)} passed, 0 failed, {len(push)} total")
PY
}

# ── self-test ───────────────────────────────────────────────────────────────
SCRATCH=""
cleanup() { [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"; return 0; }

self_test() {
  local pass=0 fail=0
  SCRATCH="$(mktemp -d)"
  trap cleanup EXIT

  # expect <name> <want-exit> <yaml-body> [needle...]
  expect() {
    local name="$1" want="$2" body="$3"
    shift 3
    local f out rc=0 ok=1 needle
    f="$SCRATCH/wf.$RANDOM.yml"
    printf '%s' "$body" >"$f"
    out="$(check_file "$f" 2>&1)" || rc=$?
    [ "$rc" -eq "$want" ] || ok=0
    for needle in "$@"; do
      case "$out" in
      *"$needle"*) ;;
      *) ok=0 ;;
      esac
    done
    if [ "$ok" -eq 1 ]; then
      pass=$((pass + 1))
      echo "PASS $name"
    else
      fail=$((fail + 1))
      echo "FAIL $name (exit $rc, wanted $want)"
      echo "$out" | sed 's/^/    | /'
    fi
  }

  local anchored='name: t
on:
  push:
    branches: [main]
    paths: &matrix_paths
      - "a/**"
      - "b/**"
  pull_request:
    paths: *matrix_paths
jobs:
  j:
    runs-on: ubuntu-latest
    steps: [{run: "true"}]
'
  local duplicated='name: t
on:
  push:
    paths:
      - "a/**"
      - "b/**"
  pull_request:
    paths:
      - "a/**"
      - "b/**"
jobs: {}
'
  local drifted='name: t
on:
  push:
    paths:
      - "a/**"
      - "b/**"
  pull_request:
    paths:
      - "a/**"
jobs: {}
'
  local reordered='name: t
on:
  push:
    paths:
      - "a/**"
      - "b/**"
  pull_request:
    paths:
      - "b/**"
      - "a/**"
jobs: {}
'
  local no_pr='name: t
on:
  push:
    paths:
      - "a/**"
jobs: {}
'
  local empty='name: t
on:
  push:
    paths: []
  pull_request:
    paths: []
jobs: {}
'
  local no_paths='name: t
on:
  push:
    branches: [main]
  pull_request: {}
jobs: {}
'
  local broken='name: t
on:
  push:
   paths:
  - "a/**"
    bad: [
'

  expect "anchor+alias passes" 0 "$anchored" "Results: 2 passed, 0 failed, 2 total"
  expect "identical copies pass" 0 "$duplicated" "Results: 2 passed, 0 failed, 2 total"
  expect "a missing path fails" 1 "$drifted" "only in push:         b/**" "drifted"
  expect "reordered copies fail" 1 "$reordered" "DIFFERENT ORDER"
  expect "no pull_request fails" 1 "$no_pr" "on.pull_request\` is missing"
  expect "empty filters fail" 1 "$empty" "is missing or empty"
  expect "absent paths fail" 1 "$no_paths" "is missing or empty"
  expect "unparseable YAML fails" 1 "$broken" "::error::"

  # The floor the whole file exists for: the guard must still bite on the REAL
  # workflow, so a self-test that only ever saw fixtures cannot report success.
  local out rc=0
  out="$(check_file "$WORKFLOW" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "^Results: [1-9][0-9]* passed, 0 failed,"; then
    pass=$((pass + 1))
    echo "PASS real conformance-matrix.yml passes with a non-empty filter"
  else
    fail=$((fail + 1))
    echo "FAIL real conformance-matrix.yml (exit $rc)"
    echo "$out" | sed 's/^/    | /'
  fi

  echo "Results: $pass passed, $fail failed, $((pass + fail)) total"
  if [ "$pass" -lt 9 ]; then
    echo "::error::self-test executed fewer cases than expected ($pass < 9) — a self-test that ran nothing is not a passing self-test."
    return 1
  fi
  [ "$fail" -eq 0 ]
}

if [ "$SELF_TEST" -eq 1 ]; then
  self_test
  exit $?
fi

check_file "$WORKFLOW"
exit $?
