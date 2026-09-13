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
#      hard-coded fixture COUNT (`\d+\s+fixtures`) or a hard-coded ENGINE/ROW
#      tally ("7 engines", "seven engine rows", "each of the 7 rows above") —
#      both counts belong to the workflow's own run output, never to frozen
#      prose.
#   2. Derives the current "one engine, one row" set MECHANICALLY from
#      `conformance-matrix.yml`'s `summary` job `needs:` list (every job that
#      is not a `-compiler`/`-roundtrip` measurement/ratchet leg — those are
#      explicitly NOT full-parity claims, see the summary job's own comments)
#      and requires BOTH docs to name every one of those engines by its
#      language token (the first word of the job's display `name:` — "TS
#      Self-Hosted Engine"/"TS Compiled Engine"/"TS Compiled (Direct)" all
#      collapse to one "TS" token, matching the one-row-per-language shape
#      both docs use).
#   3. Matches those tokens against the DATA ROWS of each doc's engine TABLE —
#      never against the whole file. This is the load-bearing detail: a
#      whole-file name scan is a fake-green gate, because an engine's name
#      almost always survives somewhere else in the same file (a "Reproduce
#      locally" command line, a caveat paragraph), so the whole table could be
#      deleted and a whole-file scan would still exit 0. Both tables are
#      additionally floored at one data row per derived engine, so an
#      unrelated table shrink is caught even when every name still appears
#      inside the surviving rows.
#
# POSITIVE FLOOR: deriving zero engines, finding the `summary` job absent,
# finding a doc's engine section absent, and finding that section carrying no
# table at all are ALL hard errors — never silent agreement.
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
    # Print the header comment (everything between the shebang and `set -uo`)
    # so the help text cannot go stale against a hard-coded line range.
    awk 'NR > 1 { if ($0 ~ /^set -uo/) exit; print }' "${BASH_SOURCE[0]}"
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

failures = []
passed = 0


def fail(msg):
    print(f"::error::{msg}")


def ok(msg):
    global passed
    passed += 1
    print(msg)


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


# ── Markdown helpers ───────────────────────────────────────────────────────
# Tokens are matched against the TABLE, never the file: every engine name this
# guard protects also appears in ordinary prose (build commands, caveats), so
# a whole-file scan keeps passing after the table it protects is deleted.
SEPARATOR_RE = re.compile(r"^\|[\s:|-]+$")


def extract_section(text, heading_pattern):
    m = re.search(
        r"^##[ \t]+" + heading_pattern + r"[^\n]*\n(.*?)(?=^##[ \t]|\Z)",
        text,
        re.MULTILINE | re.DOTALL,
    )
    return m.group(1) if m else None


def extract_table_rows(section):
    """DATA rows of the first markdown table in `section` (header and `|---|`
    separator excluded). None when the section carries no table at all."""
    lines = section.splitlines()
    for i in range(len(lines) - 1):
        head = lines[i].strip()
        sep = lines[i + 1].strip()
        if head.startswith("|") and SEPARATOR_RE.match(sep):
            rows = []
            for line in lines[i + 2 :]:
                s = line.strip()
                if not s.startswith("|"):
                    break
                rows.append(s)
            return rows
    return None


def gate_engine_table(path, text, heading_pattern, heading_label):
    section = extract_section(text, heading_pattern)
    if section is None:
        failures.append(
            f"{path}: could not find the '## {heading_label}' section — this guard refuses to pass a doc whose engine table it cannot even locate"
        )
        return
    rows = extract_table_rows(section)
    if not rows:
        failures.append(
            f"{path}: the '## {heading_label}' section carries NO markdown table (header + `|---|` separator + at least one data row) — the table this guard protects is gone"
        )
        return
    if len(rows) < len(languages):
        failures.append(
            f"{path}: the '## {heading_label}' table has {len(rows)} data row(s) but the workflow defines {len(languages)} engine(s) ({', '.join(languages)})"
        )
    else:
        ok(f"{path}: the '## {heading_label}' table has {len(rows)} data row(s) >= {len(languages)} derived engine(s) (OK)")
    row_text = "\n".join(rows)
    missing = [t for t in languages if not bounded_present(row_text, t)]
    if missing:
        failures.append(
            f"{path}: the '## {heading_label}' table is missing row(s) for {', '.join(missing)} — a name in prose elsewhere in the file does NOT count, the table is what a reader reads"
        )
    else:
        ok(f"{path}: the '## {heading_label}' table names all {len(languages)} derived engine(s) (OK)")


# ── Step 2: portability_matrix.md must not freeze a tally in prose ─────────
count_hits = [m.group(0) for m in re.finditer(r"\d+\s+fixtures\b", portability_text)]
if count_hits:
    for hit in count_hits:
        failures.append(
            f"{portability_path}: hard-coded fixture count \"{hit}\" -- point at conformance-matrix.yml instead (issue #610)"
        )
else:
    ok(f"{portability_path}: no hard-coded fixture count found (OK)")

# The same frozen-tally failure mode, one noun over: "all 7 engines",
# "seven engine rows", "each of the 7 rows above", "All seven produce …".
# How many engine rows there are is the workflow's to state, not this file's.
#
# Two deliberately narrow shapes, NOT a blanket "no digits" rule — this file
# legitimately names editions and sizes ("the 2023 row above", "65 KB"):
#   A. a count qualifying the noun `engine(s)` ("7 engines", "seven engine rows");
#   B. a count introduced by an exhaustive quantifier ("all 7 …", "All seven
#      …", "each of the 7 …") — which is a tally whatever noun follows.
NUM = r"\d+|two|three|four|five|six|seven|eight|nine|ten"
ENGINE_TALLY_RES = (
    re.compile(r"(?<![A-Za-z0-9_])(?:" + NUM + r")\s+(?:[A-Za-z][A-Za-z-]*\s+){0,2}engines?\b", re.IGNORECASE),
    re.compile(r"(?<![A-Za-z0-9_])(?:all|each\s+of\s+the|every\s+one\s+of\s+the|any\s+of\s+the)\s+(?:the\s+)?(?:" + NUM + r")\b", re.IGNORECASE),
)
tally_hits = [m.group(0) for rx in ENGINE_TALLY_RES for m in rx.finditer(portability_text)]
if tally_hits:
    for hit in tally_hits:
        failures.append(
            f"{portability_path}: hard-coded engine count \"{hit}\" -- how many engine rows there are is conformance-matrix.yml's to state (issue #610)"
        )
else:
    ok(f"{portability_path}: no hard-coded engine count found (OK)")

gate_engine_table(portability_path, portability_text, r"Engines\b", "Engines")

# ── Step 3: the embed skill's per-target table ─────────────────────────────
gate_engine_table(embed_path, embed_text, r"Per-target honest status", "Per-target honest status")

if failures:
    for f in failures:
        fail(f)
    print(f"Results: {passed} passed, {len(failures)} failed, {passed + len(failures)} total")
    sys.exit(1)

print(f"Results: {passed} passed, 0 failed, {passed} total")
PY
}

# ── self-test ───────────────────────────────────────────────────────────────
SCRATCH=""
cleanup() {
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  return 0
}

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

## Engines

| Engine | How it runs the program | job(s) |
|---|---|---|
| **Dart** | tree-walking interpreter | `dart-engine` |
| **TypeScript** | self-hosted engine | `ts-engine` |
| **C++** | self-hosted engine | `cpp-compiled` |
| **Rust** | self-hosted engine | `rust-engine` |
| **C#** | self-hosted engine | `csharp-engine` |
| **Go** | self-hosted engine | `go-engine` |
| **Python** | self-hosted engine | `python-engine` |

See `.github/workflows/conformance-matrix.yml` for current pass/fail counts.
An edition year is NOT a tally, and neither is a size: the 2023 row above and
the 65 KB linear-memory budget must both survive the frozen-tally rules.

## Reproduce locally

Run the Rust, C#, Go and Python regen chains from root CLAUDE.md.
MD

  # The exact fake-green shape this guard exists to catch: every engine is
  # still named in the surrounding prose (the "Reproduce locally" line), but
  # the TABLE has lost a row. A whole-file name scan passes this; the guard
  # must not.
  local prose_only_portability="$SCRATCH/portability_prose_only.md"
  cat >"$prose_only_portability" <<'MD'
# Editions Portability Matrix

## Engines

| Engine | How it runs the program | job(s) |
|---|---|---|
| **Dart** | tree-walking interpreter | `dart-engine` |
| **TypeScript** | self-hosted engine | `ts-engine` |
| **C++** | self-hosted engine | `cpp-compiled` |
| **Rust** | self-hosted engine | `rust-engine` |
| **C#** | self-hosted engine | `csharp-engine` |
| **Python** | self-hosted engine | `python-engine` |

## Reproduce locally

Run the Rust, C#, Go and Python regen chains from root CLAUDE.md.
MD

  # The whole table deleted, prose untouched — also a fake green before the fix.
  local no_table_portability="$SCRATCH/portability_no_table.md"
  cat >"$no_table_portability" <<'MD'
# Editions Portability Matrix

## Engines

The engine rows live in the workflow.

## Reproduce locally

Dart, TypeScript, C++, Rust, C#, Go and Python all run this program.
MD

  local counted_portability="$SCRATCH/portability_counted.md"
  cat >"$counted_portability" <<'MD'
# Editions Portability Matrix

All engines pass the full conformance corpus (293 fixtures, including 256).

## Engines

| Engine | How it runs the program | job(s) |
|---|---|---|
| **Dart** | tree-walking interpreter | `dart-engine` |
| **TypeScript** | self-hosted engine | `ts-engine` |
| **C++** | self-hosted engine | `cpp-compiled` |
| **Rust** | self-hosted engine | `rust-engine` |
| **C#** | self-hosted engine | `csharp-engine` |
| **Go** | self-hosted engine | `go-engine` |
| **Python** | self-hosted engine | `python-engine` |
MD

  local tallied_portability="$SCRATCH/portability_tallied.md"
  cat >"$tallied_portability" <<'MD'
# Editions Portability Matrix

## Engines

The program runs on all 7 engines below.

| Engine | How it runs the program | job(s) |
|---|---|---|
| **Dart** | tree-walking interpreter | `dart-engine` |
| **TypeScript** | self-hosted engine | `ts-engine` |
| **C++** | self-hosted engine | `cpp-compiled` |
| **Rust** | self-hosted engine | `rust-engine` |
| **C#** | self-hosted engine | `csharp-engine` |
| **Go** | self-hosted engine | `go-engine` |
| **Python** | self-hosted engine | `python-engine` |
MD

  local quantified_portability="$SCRATCH/portability_quantified.md"
  cat >"$quantified_portability" <<'MD'
# Editions Portability Matrix

## Engines

Each of the 7 rows below runs the whole conformance corpus.

| Engine | How it runs the program | job(s) |
|---|---|---|
| **Dart** | tree-walking interpreter | `dart-engine` |
| **TypeScript** | self-hosted engine | `ts-engine` |
| **C++** | self-hosted engine | `cpp-compiled` |
| **Rust** | self-hosted engine | `rust-engine` |
| **C#** | self-hosted engine | `csharp-engine` |
| **Go** | self-hosted engine | `go-engine` |
| **Python** | self-hosted engine | `python-engine` |

An edition year is NOT a tally: the 2023 row above is fine.
MD

  local partial_portability="$SCRATCH/portability_partial.md"
  cat >"$partial_portability" <<'MD'
# Editions Portability Matrix

## Engines

| Engine | How it runs the program | job(s) |
|---|---|---|
| **Dart** | tree-walking interpreter | `dart-engine` |
| **TypeScript** | self-hosted engine | `ts-engine` |
| **C++** | self-hosted engine | `cpp-compiled` |
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
Not part of the table. Go and Python are named here too.
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
Not part of the table. Go and Python are named here too.
MD

  # name, wanted exit code, required substring of the output, then the 3 files.
  # The needle is what keeps a case honest: an assertion on the exit code
  # alone would accept a failure for the wrong reason.
  expect() {
    local name="$1" want="$2" needle="$3"
    shift 3
    local out rc=0 ok=1
    out="$(check_files "$@" 2>&1)" || rc=$?
    [ "$rc" -eq "$want" ] || ok=0
    printf '%s\n' "$out" | grep -qF -- "$needle" || ok=0
    if [ "$ok" -eq 1 ]; then
      pass=$((pass + 1))
      echo "PASS $name"
    else
      fail=$((fail + 1))
      echo "FAIL $name (exit $rc, wanted $want; needle: $needle)"
      printf '%s\n' "$out" | sed 's/^/    | /'
    fi
  }

  # Doubles as the negative control for the two frozen-tally rules: this
  # fixture carries "the 2023 row above" and "the 65 KB … budget", neither of
  # which may be mistaken for an engine tally.
  expect "both docs clean passes" 0 "Results: 6 passed, 0 failed, 6 total" \
    "$wf" "$good_portability" "$good_embed"
  expect "hard-coded fixture count fails" 1 "hard-coded fixture count \"293 fixtures\"" \
    "$wf" "$counted_portability" "$good_embed"
  expect "hard-coded engine tally fails" 1 "hard-coded engine count \"7 engines\"" \
    "$wf" "$tallied_portability" "$good_embed"
  expect "quantified tally (\"Each of the 7 rows\") fails, edition years do not" 1 \
    "hard-coded engine count \"Each of the 7\"" \
    "$wf" "$quantified_portability" "$good_embed"
  expect "short portability table fails" 1 "table is missing row(s) for Rust, C#, Go, Python" \
    "$wf" "$partial_portability" "$good_embed"
  expect "portability table missing ONE engine its prose still names fails" 1 \
    "table is missing row(s) for Go" \
    "$wf" "$prose_only_portability" "$good_embed"
  expect "portability table deleted entirely fails" 1 "carries NO markdown table" \
    "$wf" "$no_table_portability" "$good_embed"
  expect "short embed table fails on the row floor" 1 \
    "table has 5 data row(s) but the workflow defines 7 engine(s)" \
    "$wf" "$good_portability" "$short_embed"
  expect "embed table missing engines its prose still names fails" 1 \
    "table is missing row(s) for Go, Python" \
    "$wf" "$good_portability" "$short_embed"

  # A workflow with an empty summary.needs must fail loud, not pass trivially.
  local empty_wf="$SCRATCH/wf_empty.yml"
  cat >"$empty_wf" <<'YAML'
jobs:
  summary:
    name: Parity Matrix
    needs: []
YAML
  expect "empty summary.needs fails loud" 1 "the \`summary\` job's \`needs:\` list is empty" \
    "$empty_wf" "$good_portability" "$good_embed"

  # A workflow with no summary job at all must fail loud too.
  local no_summary_wf="$SCRATCH/wf_no_summary.yml"
  cat >"$no_summary_wf" <<'YAML'
jobs:
  dart-engine:
    name: Dart Engine
YAML
  expect "missing summary job fails loud" 1 "could not find the \`summary\` job" \
    "$no_summary_wf" "$good_portability" "$good_embed"

  echo "Results: $pass passed, $fail failed, $((pass + fail)) total"
  if [ "$pass" -lt 11 ]; then
    echo "::error::self-test executed fewer cases than expected ($pass < 11) — a self-test that ran nothing is not a passing self-test."
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
