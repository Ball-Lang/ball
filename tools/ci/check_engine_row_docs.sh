#!/usr/bin/env bash
# Drift guard for two engine-row docs (issues #610, #613).
#
# WHY THIS EXISTS: two prose surfaces claim to enumerate "every engine that
# actually runs a Ball program end-to-end", and both had drifted independently
# of the thing that would have caught it — `.github/workflows/conformance-matrix.yml`,
# which is the ONLY place the current engine-row set is defined:
#
#   * `tests/editions/portability_matrix.md` (#610) hard-coded a fixture COUNT
#     ("293 fixtures") that the corpus outgrew, and named only 3 of the 7
#     engines that actually run `256_editions_resolver` in the matrix (Rust,
#     C#, Go and Python rows were added to the workflow later and never
#     backfilled into this doc).
#   * `plugins/ball/skills/embed/SKILL.md`'s per-target table (#613) called C#
#     "No" (stale — the epic finished) and had no Go/Python rows at all, even
#     though both ship a self-hosted engine and a `ball` CLI.
#
# A hard-coded number is a lie waiting to happen (the corpus only ever grows);
# a hand-kept "every engine" list is a lie waiting to happen the moment a new
# engine job is added and nobody remembers the two docs that also claim to
# enumerate engines. Per this project's policy against frozen tallies
# (`tools/check_conformance_doc_counts.sh` is the sibling guard for the
# `Results: N passed, ...` shape), this guard:
#
#   1. Fails `tests/editions/portability_matrix.md` if it contains a
#      hard-coded fixture COUNT (`\d+\s+fixtures`) — the count belongs to the
#      workflow's own run output, never a number frozen in prose.
#   2. Derives the current "one engine, one row" set MECHANICALLY from
#      `conformance-matrix.yml`'s `summary` job `needs:` list (every job that
#      is not a `-compiler`/`-roundtrip` measurement/ratchet leg — those are
#      explicitly NOT full-parity claims, see the summary job's own comments)
#      and requires BOTH docs to name every one of those engines by its
#      language token (the first word of the job's display `name:` — "TS
#      Self-Hosted Engine"/"TS Compiled Engine"/"TS Compiled (Direct)" all
#      collapse to one "TS" token, matching the one-row-per-language shape
#      both docs use).
#   3. For the embed skill's table specifically, also requires the table to
#      carry at least as many DATA ROWS as there are derived engines — so an
#      unrelated table shrink (not just a missing name) is caught too.
#
# POSITIVE FLOOR: deriving zero engines, finding zero table rows, or finding
# the `summary` job absent are all hard errors, never silent agreement.
#
# Usage:
#   bash tools/ci/check_engine_row_docs.sh                       # gate the repo
#   bash tools/ci/check_engine_row_docs.sh --self-test            # drive the cases
#   bash tools/ci/check_engine_row_docs.sh --workflow F --portability F --embed F
#
# Exits 0 when both docs pass; 1 otherwise. Needs bash + python3 (no PyYAML
# required — the workflow is small enough to parse with a tiny hand-rolled
# `needs:`/`name:` scanner, so this has no third-party dependency at all).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/conformance-matrix.yml"
PORTABILITY="$ROOT/tests/editions/portability_matrix.md"
EMBED="$ROOT/plugins/ball/skills/embed/SKILL.md"
SELF_TEST=0

while [ $# -gt 0 ]; do
  case "$1" in
  --workflow)
    WORKFLOW="$2"
    shift 2
    ;;
  --workflow=*)
    WORKFLOW="${1#--workflow=}"
    shift
    ;;
  --portability)
    PORTABILITY="$2"
    shift 2
    ;;
  --portability=*)
    PORTABILITY="${1#--portability=}"
    shift
    ;;
  --embed)
    EMBED="$2"
    shift 2
    ;;
  --embed=*)
    EMBED="${1#--embed=}"
    shift
    ;;
  --self-test)
    SELF_TEST=1
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

# ── the check itself ────────────────────────────────────────────────────────
check_files() {
  local workflow="$1" portability="$2" embed="$3"
  python3 - "$workflow" "$portability" "$embed" <<'PY'
import re
import sys

workflow_path, portability_path, embed_path = sys.argv[1:4]

def fail(msg):
    print(f"::error::{msg}")

def read(path, label):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except FileNotFoundError:
        fail(f"{label} not found: {path}")
        sys.exit(1)

workflow_text = read(workflow_path, "workflow")
portability_text = read(portability_path, "portability doc")
embed_text = read(embed_path, "embed skill doc")

# ── Step 1: derive the current engine-row set from conformance-matrix.yml ──
# Deliberately NOT a full YAML parse (no PyYAML dependency): the workflow's
# `jobs:` block is a flat mapping of `  <job-id>:\n    name: <display name>`
# entries, and the `summary` job's `needs: [...]` is a single-line flow list.
# Both are matched structurally, not by hard-coding job ids.
job_name_re = re.compile(r"^  ([a-zA-Z0-9_-]+):\n(?:.*\n)*?    name:\s*(.+?)\s*$", re.MULTILINE)
job_names = {}
for m in re.finditer(r"^  ([a-zA-Z0-9_-]+):\s*$", workflow_text, re.MULTILINE):
    job_id = m.group(1)
    # Find this job's `name:` line: the first `    name:` after this job
    # header and before the next job header (or EOF).
    start = m.end()
    next_job = re.search(r"^  [a-zA-Z0-9_-]+:\s*$", workflow_text[start:], re.MULTILINE)
    block = workflow_text[start : start + next_job.start()] if next_job else workflow_text[start:]
    name_m = re.search(r"^    name:\s*(.+?)\s*$", block, re.MULTILINE)
    if name_m:
        job_names[job_id] = name_m.group(1)

needs_m = re.search(r"^  summary:\s*\n(?:.*\n)*?    needs:\s*\[([^\]]*)\]", workflow_text, re.MULTILINE)
if not needs_m:
    fail(f"{workflow_path}: could not find the `summary` job's `needs: [...]` list")
    sys.exit(1)
needs = [n.strip() for n in needs_m.group(1).split(",") if n.strip()]
if not needs:
    fail(f"{workflow_path}: the `summary` job's `needs:` list is empty")
    sys.exit(1)

LEG_SUFFIXES = ("-compiler", "-roundtrip")
engine_job_ids = [j for j in needs if j != "summary" and not any(j.endswith(s) for s in LEG_SUFFIXES)]
if not engine_job_ids:
    fail(f"{workflow_path}: derived ZERO full-parity engine jobs from `summary.needs` — refusing to gate on nothing")
    sys.exit(1)

languages = []
for jid in engine_job_ids:
    name = job_names.get(jid)
    if not name:
        fail(f"{workflow_path}: job `{jid}` (in summary.needs) has no `name:` field to derive a language token from")
        sys.exit(1)
    token = name.split()[0]
    if token not in languages:
        languages.append(token)

if not languages:
    fail(f"{workflow_path}: derived zero language tokens from {len(engine_job_ids)} engine job(s)")
    sys.exit(1)

print(f"derived {len(languages)} engine language(s) from {workflow_path}'s summary.needs ({len(engine_job_ids)} job(s)): {', '.join(languages)}")

def aliases(token):
    # TS/TypeScript is the one token both docs spell out in full prose.
    if token == "TS":
        return ("TS", "TypeScript")
    return (token,)

def bounded_present(text, token):
    for spelling in aliases(token):
        pat = re.escape(spelling)
        # A leading word-boundary is enough: "C++"/"C#" already end on a
        # non-word character, so a trailing \b never matches after them and
        # would make the check permanently fail for those two tokens.
        if re.search(r"(?<![A-Za-z0-9_])" + pat, text):
            return True
    return False

failures = []

# ── Step 2: portability_matrix.md must not hard-code a fixture COUNT ───────
count_hits = [
    (m.start(), m.group(0))
    for m in re.finditer(r"\d+\s+fixtures\b", portability_text)
]
if count_hits:
    for _, hit in count_hits:
        failures.append(f"{portability_path}: hard-coded fixture count \"{hit}\" -- point at conformance-matrix.yml instead (issue #610)")
else:
    print(f"{portability_path}: no hard-coded fixture count found (OK)")

missing_in_portability = [t for t in languages if not bounded_present(portability_text, t)]
if missing_in_portability:
    failures.append(f"{portability_path}: missing engine row(s) for {', '.join(missing_in_portability)} (derived {len(languages)} from the workflow: {', '.join(languages)})")
else:
    print(f"{portability_path}: names all {len(languages)} derived engine(s) (OK)")

# ── Step 3: the embed skill's table must carry >= one row per engine ───────
section_m = re.search(r"^##\s+Per-target honest status.*?$\n(.*?)(?=^##\s|\Z)", embed_text, re.MULTILINE | re.DOTALL)
if not section_m:
    failures.append(f"{embed_path}: could not find the '## Per-target honest status' section")
    table_text = ""
else:
    table_text = section_m.group(1)
    data_rows = [
        line for line in table_text.splitlines()
        if line.strip().startswith("|") and not re.match(r"^\|[-\s|:]+\|?\s*$", line.strip()) and "Embeddable for untrusted input" not in line
    ]
    if len(data_rows) < len(languages):
        failures.append(f"{embed_path}: the per-target table has {len(data_rows)} row(s) but the workflow defines {len(languages)} engine(s) ({', '.join(languages)})")
    else:
        print(f"{embed_path}: the per-target table has {len(data_rows)} row(s) >= {len(languages)} derived engine(s) (OK)")

    missing_in_embed = [t for t in languages if not bounded_present(table_text, t)]
    if missing_in_embed:
        failures.append(f"{embed_path}: table is missing row(s) for {', '.join(missing_in_embed)}")
    else:
        print(f"{embed_path}: table names all {len(languages)} derived engine(s) (OK)")

if failures:
    for f in failures:
        fail(f)
    print(f"Results: 0 passed, {len(failures)} failed, {len(failures)} total")
    sys.exit(1)

print("Results: 2 passed, 0 failed, 2 total")
PY
}

# ── self-test ───────────────────────────────────────────────────────────────
SCRATCH=""
cleanup() { [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"; return 0; }

self_test() {
  local pass=0 fail=0
  SCRATCH="$(mktemp -d)"
  trap cleanup EXIT

  local wf="$SCRATCH/wf.yml"
  cat >"$wf" <<'YAML'
jobs:
  dart-engine:
    name: Dart Engine
  ts-engine:
    name: TS Self-Hosted Engine
  ts-compiled-engine:
    name: TS Compiled Engine
  ts-compiled-direct:
    name: TS Compiled (Direct)
  cpp-compiled:
    name: C++ Compiled
  rust-engine:
    name: Rust Self-Hosted Engine
  csharp-engine:
    name: C# Self-Hosted Engine
  go-engine:
    name: Go Self-Hosted Engine
  python-engine:
    name: Python Self-Hosted Engine
  csharp-compiler:
    name: C# Compiler Leg (ratcheted)
  rust-roundtrip:
    name: Rust Round-Trip Leg (measurement)
  summary:
    name: Parity Matrix
    needs: [dart-engine, ts-engine, ts-compiled-engine, ts-compiled-direct, cpp-compiled, rust-engine, csharp-engine, go-engine, python-engine, csharp-compiler, rust-roundtrip]
YAML

  local good_portability="$SCRATCH/portability_good.md"
  cat >"$good_portability" <<'MD'
# Editions Portability Matrix

| Engine | How it runs the program |
|---|---|
| Dart | tree-walking interpreter |
| TypeScript | self-hosted engine |
| C++ | self-hosted engine |
| Rust | self-hosted engine |
| C# | self-hosted engine |
| Go | self-hosted engine |
| Python | self-hosted engine |

See `.github/workflows/conformance-matrix.yml` for current pass/fail counts.
MD

  local counted_portability="$SCRATCH/portability_counted.md"
  cat >"$counted_portability" <<'MD'
# Editions Portability Matrix

All engines pass the full conformance corpus (293 fixtures, including 256).

Dart, TypeScript, C++, Rust, C#, Go, Python all run it.
MD

  local partial_portability="$SCRATCH/portability_partial.md"
  cat >"$partial_portability" <<'MD'
# Editions Portability Matrix

Only Dart, TypeScript and C++ run this program today.
MD

  local good_embed="$SCRATCH/embed_good.md"
  cat >"$good_embed" <<'MD'
# Ball Embed

## Per-target honest status

| Target | Embeddable for untrusted input? |
|---|---|
| **Dart** | Yes |
| **TypeScript** | Partial |
| **Rust** | Trusted only |
| **C++** | Trusted only |
| **C#** | Trusted only |
| **Go** | Trusted only |
| **Python** | Trusted only |

## Dangerous assumptions
Not part of the table.
MD

  local short_embed="$SCRATCH/embed_short.md"
  cat >"$short_embed" <<'MD'
# Ball Embed

## Per-target honest status

| Target | Embeddable for untrusted input? |
|---|---|
| **Dart** | Yes |
| **TypeScript** | Partial |
| **Rust** | Trusted only |
| **C++** | Trusted only |
| **C#** | No |

## Dangerous assumptions
Not part of the table.
MD

  expect() {
    local name="$1" want="$2"
    shift 2
    local out rc=0 ok=1 needle
    out="$(check_files "$@" 2>&1)" || rc=$?
    [ "$rc" -eq "$want" ] || ok=0
    if [ "$ok" -eq 1 ]; then
      pass=$((pass + 1))
      echo "PASS $name"
    else
      fail=$((fail + 1))
      echo "FAIL $name (exit $rc, wanted $want)"
      echo "$out" | sed 's/^/    | /'
    fi
  }

  expect "both docs clean passes" 0 "$wf" "$good_portability" "$good_embed"
  expect "hard-coded fixture count fails" 1 "$wf" "$counted_portability" "$good_embed"
  expect "missing engine rows in portability doc fails" 1 "$wf" "$partial_portability" "$good_embed"
  expect "short embed table fails" 1 "$wf" "$good_portability" "$short_embed"

  # A workflow with an empty summary.needs must fail loud, not pass trivially.
  local empty_wf="$SCRATCH/wf_empty.yml"
  cat >"$empty_wf" <<'YAML'
jobs:
  summary:
    name: Parity Matrix
    needs: []
YAML
  expect "empty summary.needs fails loud" 1 "$empty_wf" "$good_portability" "$good_embed"

  # A workflow with no summary job at all must fail loud too.
  local no_summary_wf="$SCRATCH/wf_no_summary.yml"
  cat >"$no_summary_wf" <<'YAML'
jobs:
  dart-engine:
    name: Dart Engine
YAML
  expect "missing summary job fails loud" 1 "$no_summary_wf" "$good_portability" "$good_embed"

  echo "Results: $pass passed, $fail failed, $((pass + fail)) total"
  if [ "$pass" -lt 6 ]; then
    echo "::error::self-test executed fewer cases than expected ($pass < 6) — a self-test that ran nothing is not a passing self-test."
    return 1
  fi
  [ "$fail" -eq 0 ]
}

if [ "$SELF_TEST" -eq 1 ]; then
  self_test
  exit $?
fi

check_files "$WORKFLOW" "$PORTABILITY" "$EMBED"
exit $?
