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
# ── SECOND INVARIANT: EVERY FILTER PATH MAPS ONTO A ROW SIGNAL (issue #666) ──
# Since the per-row conditions landed, conformance-matrix.yml's rows run only
# when the classifier says this diff needs them, and the `infra` fail-safe is
# deliberately NOT one of the signals they read. That is only safe while every
# path which can START the workflow also sets a signal some row reads. A filter
# entry that maps to nothing is a SILENTLY GREEN MATRIX: the workflow starts,
# all 17 rows evaluate false, and a summary that (correctly) treats `skipped` as
# benign prints a full table of SKIPs and exits 0 — a green Conformance Matrix
# that executed zero rows.
#
# So the mapping is a correctness invariant of the matrix, and this guard
# enforces it rather than merely asserting it in prose: for every entry in the
# filter it synthesizes a concrete path that entry matches, runs the REAL
# classifier (`.github/actions/detect-changed-stacks/detect.sh`, sourced — the
# same contract the truth table uses) over it, and fails unless at least one
# signal the row conditions actually read comes back `true`. The signal set is
# scraped out of the workflow itself (`needs.<classifier>.outputs.<name>`), so
# there is no second table to keep in sync. `Parity Matrix` carries the RUN-time
# half of the same invariant: on a pull_request it fails if every engine row was
# skipped.
#
# Usage:
#   bash tools/ci/check_matrix_paths.sh                  # gate the repo
#   bash tools/ci/check_matrix_paths.sh --file FILE       # a synthetic workflow
#   bash tools/ci/check_matrix_paths.sh --self-test       # drive the cases
#
# Exits 0 when the two lists are identical and non-empty AND every path maps
# onto a row signal; 1 otherwise, printing every path that is in one trigger
# only and every path that maps to nothing. Needs bash + python3 (the runner
# image ships both), so it runs in ci.yml's always-on `proto` job with no
# toolchain.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/conformance-matrix.yml"
DETECT="$ROOT/.github/actions/detect-changed-stacks/detect.sh"
SELF_TEST=0
TAB=$'\t'

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
    sed -n '2,/^set -uo pipefail$/p' "${BASH_SOURCE[0]}"
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

# ── invariant 2: every filter path maps onto a row signal ───────────────────
# Emits a machine-readable spec for the mapping check, derived from the
# workflow ITSELF (never a second hand-kept table):
#   MAPPING classifier=<job-id> signals=<a,b,c>
#   PROBE   <filter pattern>\t<a concrete path that pattern matches>
#   NOTE    <a pattern deliberately not probed, with the reason>
# A workflow with no detect-changed-stacks job has no per-row conditions to
# protect, so it emits NOTE and no MAPPING, and the caller reports "not
# applicable" — the REAL workflow's applicability is floored separately, in the
# self-test.
mapping_spec() {
  local file="$1"
  python3 - "$file" <<'PY'
import re
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - the runner image ships PyYAML
    print("::error::PyYAML is required by tools/ci/check_matrix_paths.sh")
    sys.exit(1)

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as fh:
        raw = fh.read()
    doc = yaml.safe_load(raw)
except FileNotFoundError:
    print(f"::error::workflow not found: {path}")
    sys.exit(1)
except yaml.YAMLError as exc:
    print(f"::error::{path} is not parseable YAML: {exc}")
    sys.exit(1)

if not isinstance(doc, dict):
    print(f"::error::{path} does not parse to a mapping")
    sys.exit(1)

ACTION = "./.github/actions/detect-changed-stacks"

jobs = doc.get("jobs")
jobs = jobs if isinstance(jobs, dict) else {}

classifiers = []
for jid, job in jobs.items():
    if not isinstance(job, dict):
        continue
    steps = job.get("steps")
    if not isinstance(steps, list):
        continue
    for step in steps:
        if isinstance(step, dict) and str(step.get("uses", "")).strip() == ACTION:
            classifiers.append(str(jid))
            break

if not classifiers:
    print(f"NOTE\tno `{ACTION}` job in {path} - no per-row conditions to protect")
    sys.exit(0)

if len(classifiers) > 1:
    print(
        f"::error::{path} has more than one `{ACTION}` job "
        f"({', '.join(classifiers)}) - which one selects the rows is ambiguous."
    )
    sys.exit(1)

cid = classifiers[0]

# Which classifier outputs do the row conditions actually read? Scraped from the
# raw file text rather than from job-level `if:` alone, so a condition that
# moved into a step `if:`, an `env:` or a `with:` still counts - this check must
# never go RED because a real reference sat in a shape the parser walk did not
# visit.
signals = sorted(set(re.findall(r"needs\.%s\.outputs\.([A-Za-z0-9_]+)" % re.escape(cid), raw)))
if not signals:
    print(
        f"::error::{path}: the `{cid}` job classifies the diff but NOTHING reads "
        f"`needs.{cid}.outputs.*` - every row would run unconditionally and the "
        "classifier would be decoration."
    )
    sys.exit(1)

triggers = doc.get(True, doc.get("on"))
if not isinstance(triggers, dict):
    print(f"::error::{path} has no `on:` trigger mapping")
    sys.exit(1)
block = triggers.get("pull_request")
paths = block.get("paths") if isinstance(block, dict) else None
if not isinstance(paths, list) or not paths:
    print(f"::error::{path}: `on.pull_request.paths` is missing or empty")
    sys.exit(1)


def to_regex(pattern):
    """GitHub path-filter globbing: `*` stops at `/`, `**` does not, `?` is one
    non-`/` character. See
    https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#patterns-to-match-file-paths
    """
    out = ["^"]
    i = 0
    while i < len(pattern):
        if pattern[i] == "*":
            if pattern[i : i + 2] == "**":
                out.append(".*")
                i += 2
            else:
                out.append("[^/]*")
                i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    out.append("$")
    return "".join(out)


def probe_for(pattern):
    """A concrete repository path that `pattern` matches."""
    segments = []
    for seg in pattern.split("/"):
        if seg == "**":
            segments.append("probe_file")
        elif "*" in seg or "?" in seg:
            segments.append(
                seg.replace("**", "probe").replace("*", "probe").replace("?", "p")
            )
        else:
            segments.append(seg)
    return "/".join(s for s in segments if s)


print("MAPPING\tclassifier=%s\tsignals=%s" % (cid, ",".join(signals)))
for pattern in [str(p) for p in paths]:
    if pattern.startswith("!"):
        # An exclusion narrows the trigger; it can never be the sole reason a
        # run starts, so it has no row to map onto.
        print(f"NOTE\t{pattern} is an exclusion pattern - nothing reaches a job through it")
        continue
    probe = probe_for(pattern)
    if not re.match(to_regex(pattern), probe):
        print(
            f"::error::{path}: could not synthesize a path matching the filter "
            f"entry `{pattern}` (built `{probe}`). Extend probe_for() in "
            "tools/ci/check_matrix_paths.sh rather than dropping the entry."
        )
        sys.exit(1)
    print(f"PROBE\t{pattern}\t{probe}")
PY
}

# check_mapping — for every path in the filter, run the REAL classifier over a
# file that path would match and assert at least one signal the row conditions
# read comes back `true`. An unmapped path is a silently green matrix: the
# workflow starts, every row's condition is false, and `Parity Matrix` prints a
# table of SKIPs and exits 0.
check_mapping() {
  local file="$1"
  local spec rc=0
  spec="$(mapping_spec "$file")" || rc=$?
  printf '%s\n' "$spec" | sed -n "s/^NOTE${TAB}/note: /p"
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$spec" | grep -v "^NOTE${TAB}" || true
    return 1
  fi

  local header
  header="$(printf '%s\n' "$spec" | grep "^MAPPING${TAB}" || true)"
  if [ -z "$header" ]; then
    echo "path->signal mapping: not applicable (no detect-changed-stacks job in $file)."
    return 0
  fi

  if [ ! -f "$DETECT" ]; then
    echo "::error::the classifier $DETECT is missing — the mapping cannot be checked against the real signals."
    return 1
  fi
  # Sourcing defines ball_classify_stacks WITHOUT running the detector (its
  # BASH_SOURCE/$0 guard), the same contract test/truth_table.sh relies on. The
  # probe is therefore classified by the real thing, never by a restated regex.
  # shellcheck source=/dev/null
  . "$DETECT" || {
    echo "::error::could not source $DETECT"
    return 1
  }

  local signals sig_alt classifier
  classifier="$(printf '%s' "$header" | cut -f2 | cut -d= -f2)"
  signals="$(printf '%s' "$header" | cut -f3 | cut -d= -f2)"
  sig_alt="$(printf '%s' "$signals" | tr ',' '|')"
  if [ -z "$sig_alt" ]; then
    echo "::error::no row signals parsed out of: $header"
    return 1
  fi

  echo ""
  echo "path->signal mapping (classifier job '$classifier'; row signals: ${signals//,/, }):"
  local pattern probe hit checked=0 unmapped=0
  while IFS="$TAB" read -r pattern probe; do
    [ -n "$pattern" ] || continue
    checked=$((checked + 1))
    hit="$(ball_classify_stacks "$probe" "" | grep -E "^(${sig_alt})=true$" | cut -d= -f1 | tr '\n' ',' | sed 's/,$//')"
    if [ -n "$hit" ]; then
      printf '  %-24s -> %s\n' "$pattern" "$hit"
    else
      unmapped=$((unmapped + 1))
      printf '  %-24s -> NOTHING\n' "$pattern"
      echo "::error::$file: the filter entry \`$pattern\` starts this workflow but matches NO signal that any row condition reads (${signals//,/, }). A PR whose only change is such a path runs the workflow with every row's \`if:\` false, and the summary would print a full table of SKIPs and exit 0 — a green Conformance Matrix that executed zero rows. Fix it by giving the path a signal in .github/actions/detect-changed-stacks/detect.sh (plus a truth-table row), by adding an existing signal to the row conditions, or by removing the path from the filter."
    fi
  done < <(printf '%s\n' "$spec" | sed -n "s/^PROBE${TAB}//p")

  if [ "$checked" -lt 1 ]; then
    echo "::error::$file: the mapping check compared ZERO paths — a check that found nothing to check is not a pass."
    return 1
  fi
  if [ "$unmapped" -ne 0 ]; then
    echo "Results: $((checked - unmapped)) passed, $unmapped failed, $checked total (path->signal mapping)"
    return 1
  fi
  echo "Results: $checked passed, 0 failed, $checked total (path->signal mapping)"
  return 0
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

  # expect_map <name> <want-exit> <yaml-body> [needle...] — the path->signal
  # mapping half. Fixtures carry a REAL classifier job and REAL row conditions,
  # so the probe is classified by the repo's own detect.sh.
  expect_map() {
    local name="$1" want="$2" body="$3"
    shift 3
    local f out rc=0 ok=1 needle
    f="$SCRATCH/map.$RANDOM.yml"
    printf '%s' "$body" >"$f"
    out="$(check_mapping "$f" 2>&1)" || rc=$?
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

  # A miniature of the real workflow: a classifier job, two conditioned rows,
  # and a filter whose every entry maps onto one of the signals those rows read.
  local mapped='name: t
on:
  push:
    paths: &p
      - "rust/**"
      - "tests/conformance/**"
  pull_request:
    paths: *p
jobs:
  changes:
    name: Detect matrix rows
    runs-on: ubuntu-latest
    outputs:
      rust: ${{ steps.f.outputs.rust }}
      corpus: ${{ steps.f.outputs.corpus }}
    steps:
      - id: f
        uses: ./.github/actions/detect-changed-stacks
  rust-engine:
    needs: changes
    if: ${{ github.event_name != '"'"'pull_request'"'"' || needs.changes.outputs.corpus == '"'"'true'"'"' || needs.changes.outputs.rust == '"'"'true'"'"' }}
    runs-on: ubuntu-latest
    steps: [{run: "true"}]
'
  # The same workflow with ONE unmapped entry added: `proto/**` starts the
  # workflow but sets only `infra`, which no row reads. This is the exact probe
  # the review used against the old guard, where it came back green.
  local unmapped='name: t
on:
  push:
    paths: &p
      - "proto/**"
      - "rust/**"
      - "tests/conformance/**"
  pull_request:
    paths: *p
jobs:
  changes:
    name: Detect matrix rows
    runs-on: ubuntu-latest
    outputs:
      rust: ${{ steps.f.outputs.rust }}
      corpus: ${{ steps.f.outputs.corpus }}
    steps:
      - id: f
        uses: ./.github/actions/detect-changed-stacks
  rust-engine:
    needs: changes
    if: ${{ github.event_name != '"'"'pull_request'"'"' || needs.changes.outputs.corpus == '"'"'true'"'"' || needs.changes.outputs.rust == '"'"'true'"'"' }}
    runs-on: ubuntu-latest
    steps: [{run: "true"}]
'
  # A classifier whose outputs nothing reads: every row is unconditional, so the
  # classifier is decoration and the invariant it is supposed to carry is gone.
  local unread='name: t
on:
  push:
    paths: &p
      - "rust/**"
  pull_request:
    paths: *p
jobs:
  changes:
    runs-on: ubuntu-latest
    steps:
      - id: f
        uses: ./.github/actions/detect-changed-stacks
  rust-engine:
    needs: changes
    runs-on: ubuntu-latest
    steps: [{run: "true"}]
'

  expect "anchor+alias passes" 0 "$anchored" "Results: 2 passed, 0 failed, 2 total"
  expect "identical copies pass" 0 "$duplicated" "Results: 2 passed, 0 failed, 2 total"
  expect "a missing path fails" 1 "$drifted" "only in push:         b/**" "drifted"
  expect "reordered copies fail" 1 "$reordered" "DIFFERENT ORDER"
  expect "no pull_request fails" 1 "$no_pr" "on.pull_request\` is missing"
  expect "empty filters fail" 1 "$empty" "is missing or empty"
  expect "absent paths fail" 1 "$no_paths" "is missing or empty"
  expect "unparseable YAML fails" 1 "$broken" "::error::"

  expect_map "every filter path maps to a row signal" 0 "$mapped" \
    "rust/**" "tests/conformance/**" "Results: 2 passed, 0 failed, 2 total (path->signal mapping)"
  # THE NEGATIVE CONTROL this guard exists for.
  expect_map "an unmapped filter path is rejected" 1 "$unmapped" \
    "proto/**                 -> NOTHING" "executed zero rows"
  expect_map "a classifier nothing reads is rejected" 1 "$unread" \
    "NOTHING reads"
  expect_map "no classifier job -> not applicable" 0 "$anchored" \
    "not applicable"

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

  # The mapping half of the same floor: the real workflow must be APPLICABLE
  # (it has a classifier and conditioned rows) and must map a non-zero number of
  # paths. "not applicable" against the real file would mean the check silently
  # stopped covering the only workflow it exists for.
  rc=0
  out="$(check_mapping "$WORKFLOW" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] &&
    printf '%s' "$out" | grep -q "^Results: [1-9][0-9]* passed, 0 failed, .*(path->signal mapping)$" &&
    ! printf '%s' "$out" | grep -q "not applicable"; then
    pass=$((pass + 1))
    echo "PASS real conformance-matrix.yml maps every filter path onto a row signal"
  else
    fail=$((fail + 1))
    echo "FAIL real conformance-matrix.yml path->signal mapping (exit $rc)"
    echo "$out" | sed 's/^/    | /'
  fi

  echo "Results: $pass passed, $fail failed, $((pass + fail)) total"
  if [ "$pass" -lt 14 ]; then
    echo "::error::self-test executed fewer cases than expected ($pass < 14) — a self-test that ran nothing is not a passing self-test."
    return 1
  fi
  [ "$fail" -eq 0 ]
}

if [ "$SELF_TEST" -eq 1 ]; then
  self_test
  exit $?
fi

rc=0
check_file "$WORKFLOW" || rc=1
check_mapping "$WORKFLOW" || rc=1
exit "$rc"
