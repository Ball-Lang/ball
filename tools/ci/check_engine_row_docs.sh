#!/usr/bin/env bash
# Drift guard for three engine-row docs (issues #610, #613, #709).
#
# WHY THIS EXISTS: three prose surfaces claim to enumerate "every engine that
# actually runs a Ball program end-to-end", and each had drifted independently
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
#   * `plugins/ball/skills/embed/references/embedding-per-target.md` (#709) —
#     the copy-ready backing for that table — makes the same class of claim one
#     level deeper, as a `## <Language> — …` section per target. It is where the
#     retired "C# — not embeddable yet" verdict ("even then does not reach
#     golden output … There is no working `.Run()` today") lived until #652
#     hand-corrected it, and until #709 nothing stopped it drifting again: this
#     file carries no markdown table, so rules 1-4 could not reach it even if it
#     had been passed in.
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
#   2. Derives the current "one engine, one row" set MECHANICALLY from the
#      PARITY TABLE `conformance-matrix.yml`'s `summary` job prints — the
#      `print_row "<display name>" … needs.<job>.result` calls between its
#      box-drawing header and footer. That table is where the workflow itself
#      declares a full-parity row (its "adding a new engine" checklist is
#      `needs:` + a `print_row` call + a failure check), and the ratcheted
#      compiler / measurement round-trip legs printed AFTER the footer are
#      excluded by construction rather than by a name blacklist. The language
#      token is the first word of the row's display name — "TS Self-Hosted
#      Engine"/"TS Compiled Engine"/"TS Compiled (Direct)" all collapse to one
#      "TS" token, matching the one-row-per-language shape both docs use.
#      `summary.needs` stays a cross-check: a parity row reporting a job the
#      summary does not depend on can never fail the matrix, so that is a hard
#      error here.
#   3. Matches those tokens against the DATA ROWS of each doc's engine TABLE —
#      never against the whole file. This is the load-bearing detail: a
#      whole-file name scan is a fake-green gate, because an engine's name
#      almost always survives somewhere else in the same file (a "Reproduce
#      locally" command line, a caveat paragraph), so the whole table could be
#      deleted and a whole-file scan would still exit 0. Both tables are
#      additionally floored at one data row per derived engine, so an
#      unrelated table shrink is caught even when every name still appears
#      inside the surviving rows.
#   4. Fails any row that tells a reader one of those engines CANNOT EXECUTE a
#      Ball program. Rules 2 and 3 count rows and names; they cannot see a row
#      that is present, correctly named, and flatly wrong — which is what #613
#      actually reported ("**No.** Engine does not execute to golden output
#      yet"). A language in the parity table runs the whole corpus to a
#      byte-exact golden on every run, so that claim contradicts the same
#      source of truth rules 2-3 derive from. Deliberately narrow: only
#      execution claims, so "Trusted only", "no public constructor" and "no
#      NuGet package yet" (all currently true, and all about embeddability
#      rather than execution) keep passing.
#   5. Applies the SAME two questions to `embedding-per-target.md`, whose
#      per-language unit is a `## <Language> — …` SECTION rather than a table
#      row (#709): every derived language must have a section, that section must
#      carry prose, and it may not claim its engine cannot execute a Ball
#      program. The section's language token is the FIRST WORD of its heading —
#      the same convention rule 2 applies to a parity row's display name — so
#      `## C# — trusted only, and only in a -p:SelfHost=true build` is the C#
#      section while `## Transport: .ball.bin vs .ball.json` is not a language
#      at all. The prose (not the file) is the unit for the same reason rule 3
#      scopes to table rows: every engine's name survives in this file's
#      snippets and caveats long after its section is gone.
#
# The per-language PROSE is gated rather than generated because only two things
# in that file are derivable — which languages it must cover, and whether a
# section contradicts the parity table. The rest is hand-written, per-target,
# copy-ready embedding code (constructor shapes, file:line citations, verified
# gaps) that no generator has the inputs to write.
#
# POSITIVE FLOOR: deriving zero engines, finding the `summary` job absent,
# finding its parity table absent, finding a doc's engine section absent,
# finding that section carrying no table at all, finding the per-target doc with
# no `## ` sections at all, and finding a per-language section with an empty
# body are ALL hard errors — never silent agreement.
#
# Usage:
#   bash tools/ci/check_engine_row_docs.sh                       # gate the repo
#   bash tools/ci/check_engine_row_docs.sh --self-test            # drive the cases
#   bash tools/ci/check_engine_row_docs.sh --workflow F --portability F --embed F --per-target F
#
# Exits 0 when all three docs pass; 1 otherwise. Needs bash + python3 (no PyYAML
# required — the workflow is small enough to parse with a tiny hand-rolled
# `jobs:`/`needs:`/`print_row` scanner, so this has no third-party dependency
# at all).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/conformance-matrix.yml"
PORTABILITY="$ROOT/tests/editions/portability_matrix.md"
EMBED="$ROOT/plugins/ball/skills/embed/SKILL.md"
PER_TARGET="$ROOT/plugins/ball/skills/embed/references/embedding-per-target.md"
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
  --per-target)
    PER_TARGET="$2"
    shift 2
    ;;
  --per-target=*)
    PER_TARGET="${1#--per-target=}"
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
  local workflow="$1" portability="$2" embed="$3" per_target="$4"
  python3 - "$workflow" "$portability" "$embed" "$per_target" <<'PY'
import re
import sys

workflow_path, portability_path, embed_path, per_target_path = sys.argv[1:5]

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
per_target_text = read(per_target_path, "embed per-target reference doc")

# ── Step 1: derive the current engine-row set from conformance-matrix.yml ──
# Deliberately NOT a full YAML parse (no PyYAML dependency), and deliberately
# NOT a blacklist of job-id suffixes either. The authoritative declaration of
# "this is a full-parity engine row" is the `summary` job's PARITY TABLE — the
# `print_row "<Display name>" … needs.<job-id>.result` calls printed between
# the box-drawing header and footer. The workflow says so itself: its
# "adding a new engine" checklist is `1. Add "<lang>-engine" to the needs:
# array / 2. Add a print_row call for the new engine / 3. Add a failure check`,
# and the compiler/round-trip legs that follow the footer carry the comment
# "Deliberately NOT part of the parity table above: this leg does not claim
# full parity". A suffix blacklist got this wrong the moment a non-engine job
# joined `summary.needs` — #671 added the `changes` classifier to it, which a
# `-compiler`/`-roundtrip` blacklist happily derived as an engine named
# "Detect".
#
# The language token is the FIRST word of the row's display name: "TS
# Self-Hosted Engine"/"TS Compiled Engine"/"TS Compiled (Direct)" all collapse
# to one "TS" token, matching the one-row-per-language shape both docs use.
#
# `summary.needs` stays load-bearing as a CROSS-CHECK: a parity row printed for
# a job the summary does not depend on cannot make the matrix fail, so that is
# a hard error here rather than a silently weaker gate.
jobs_m = re.search(r"^jobs:\s*$", workflow_text, re.MULTILINE)
if not jobs_m:
    fail(f"{workflow_path}: no top-level `jobs:` block")
    sys.exit(1)
jobs_text = workflow_text[jobs_m.end() :]
job_ids = set(re.findall(r"^  ([a-zA-Z0-9_-]+):\s*$", jobs_text, re.MULTILINE))

needs_m = re.search(r"^  summary:\s*\n(?:.*\n)*?    needs:\s*\[([^\]]*)\]", workflow_text, re.MULTILINE)
if not needs_m:
    fail(f"{workflow_path}: could not find the `summary` job's `needs: [...]` list")
    sys.exit(1)
needs = [n.strip() for n in needs_m.group(1).split(",") if n.strip()]
if not needs:
    fail(f"{workflow_path}: the `summary` job's `needs:` list is empty")
    sys.exit(1)

# The table body is what the `summary` step prints between its box-drawing
# header separator and its footer. Those two glyphs are the only anchor that
# does not depend on job ids or row wording, and the legs printed AFTER the
# footer are excluded by construction — which is what makes this a parity-only
# set. Scoped to the `summary` job's own block so an unrelated box drawn
# earlier in the workflow cannot be mistaken for it.
TABLE_TOP = "\u2560"  # the header separator's leading glyph
TABLE_BOTTOM = "\u255a"  # the footer's leading glyph
summary_block = workflow_text[needs_m.start() :]
table_m = re.search(TABLE_TOP + r"[^\n]*\n(.*?)" + TABLE_BOTTOM, summary_block, re.DOTALL)
if not table_m:
    fail(
        f"{workflow_path}: could not find the `summary` job's parity table "
        f"(the box-drawing header/footer around its `print_row` calls)"
    )
    sys.exit(1)

table_body = table_m.group(1)
# One entry per `print_row` call; a call's arguments run until the NEXT call
# (or the end of the table), so this does not care whether a call is written
# on one line or continued over five.
calls = list(re.finditer(r'print_row\s+"([^"]+)"', table_body))
parity_rows = []  # (display name, job id)
for i, m in enumerate(calls):
    row_name = m.group(1)
    args = table_body[m.end() : calls[i + 1].start() if i + 1 < len(calls) else len(table_body)]
    job_m = re.search(r"needs\.([a-zA-Z0-9_-]+)\.result", args)
    if not job_m:
        fail(
            f"{workflow_path}: parity row \"{row_name}\" does not reference a `needs.<job>.result` "
            f"— cannot tell which job it reports"
        )
        sys.exit(1)
    parity_rows.append((row_name, job_m.group(1)))

if not parity_rows:
    fail(f"{workflow_path}: derived ZERO parity rows from the `summary` job's table — refusing to gate on nothing")
    sys.exit(1)

for row_name, jid in parity_rows:
    if jid not in job_ids:
        fail(f"{workflow_path}: parity row \"{row_name}\" reports job `{jid}`, which is not a job in this workflow")
        sys.exit(1)
    if jid not in needs:
        fail(
            f"{workflow_path}: parity row \"{row_name}\" reports job `{jid}`, which is NOT in the `summary` job's "
            f"`needs:` — that row can never fail the matrix"
        )
        sys.exit(1)

languages = []
for row_name, _ in parity_rows:
    token = row_name.split()[0]
    if token not in languages:
        languages.append(token)

if not languages:
    fail(f"{workflow_path}: derived zero language tokens from {len(parity_rows)} parity row(s)")
    sys.exit(1)

print(
    f"derived {len(languages)} engine language(s) from {workflow_path}'s `summary` parity table "
    f"({len(parity_rows)} row(s)): {', '.join(languages)}"
)


def aliases(token):
    # TS/TypeScript is the one token both docs spell out in full prose.
    if token == "TS":
        return ("TS", "TypeScript")
    return (token,)


def bounded_present(text, token):
    """Is `token` present in `text` as a WHOLE word?

    Both boundaries are enforced, but the trailing one only when the spelling
    ends on a word character: a `\\b` after "C++"/"C#" can never match (they
    already end on punctuation) and would make the check permanently fail for
    exactly those two tokens. Without the trailing boundary "Go" matches
    "Golden" and "Dart" matches "Darts", so a table that never mentions Go
    would still be reported as naming it."""
    for spelling in aliases(token):
        pat = re.escape(spelling)
        if spelling[-1].isalnum() or spelling[-1] == "_":
            pat += r"(?![A-Za-z0-9_])"
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
    return rows


# A language that appears as a row in the `summary` job's PARITY TABLE runs the
# whole conformance corpus to a byte-exact golden on every matrix run. So a doc
# row for that language may not tell an embedder the opposite. This is #613's
# headline symptom, and the one the row-count/row-presence rules above cannot
# see: the stale table already HAD a C# row, it just said "**No.** Engine does
# not execute to golden output yet (`SelfHostPendingException`)" — seven rows,
# seven names, a flatly false verdict.
#
# Deliberately narrow: only claims that the engine cannot EXECUTE A PROGRAM.
# "Trusted only", "no public constructor", "no NuGet package yet", "does not
# compile for Flutter web" are all legitimate (and currently true) statements
# about embeddability and packaging, and must keep passing.
CANNOT_EXECUTE_RES = (
    re.compile(r"(?:does|do)\s+not\s+execute", re.IGNORECASE),
    re.compile(r"can(?:not|'t|’t)\s+execute", re.IGNORECASE),
    re.compile(r"(?:does|do)\s+not\s+(?:yet\s+)?run\s+(?:a\s+|any\s+)?(?:Ball\s+)?programs?", re.IGNORECASE),
    re.compile(r"can(?:not|'t|’t)\s+(?:yet\s+)?run\s+(?:a\s+|any\s+)?(?:Ball\s+)?programs?", re.IGNORECASE),
    re.compile(r"no\s+working\s+engine", re.IGNORECASE),
    # The pre-#652 wording of this file's C# section. "Reaches golden output"
    # is precisely what a parity row asserts on every run, so its negation is
    # an execution claim however it is phrased (verified: zero hits across all
    # three docs today).
    re.compile(r"(?:does|do)\s+not\s+(?:yet\s+)?reach\s+golden\s+output", re.IGNORECASE),
    re.compile(r"never\s+reach(?:es)?\s+golden\s+output", re.IGNORECASE),
)


def cannot_execute_hit(text):
    """The first "this engine cannot run a program" claim in `text`, or None."""
    for rx in CANNOT_EXECUTE_RES:
        m = rx.search(text)
        if m:
            return m.group(0)
    return None


def gate_no_cannot_execute_verdict(path, rows, heading_label):
    """No row for a language in the parity table may claim its engine cannot
    run a Ball program. `rows` is the table's data rows (None when the table
    could not be located — the caller already failed in that case)."""
    if not rows:
        return
    bad = []
    for row in rows:
        row_langs = [t for t in languages if bounded_present(row, t)]
        if not row_langs:
            continue
        hit = cannot_execute_hit(row)
        if hit:
            bad.append((", ".join(row_langs), hit))
    if bad:
        for lang, hit in bad:
            failures.append(
                f"{path}: the '## {heading_label}' table's {lang} row claims \"{hit}\" — that language has a row in "
                f"conformance-matrix.yml's `summary` parity table, i.e. its engine runs the WHOLE corpus to a "
                f"byte-exact golden on every run (issue #613)"
            )
    else:
        ok(f"{path}: no '## {heading_label}' row claims a parity-table engine cannot execute a program (OK)")


# ── Step 2: portability_matrix.md must not freeze a tally in prose ─────────
# `\\d+ fixtures` is the bare shape; the adjectives are the ones this repo
# actually writes ("351 golden fixtures", "351 conformance fixtures"), and
# they are the same frozen tally (review round 1, A4b).
FIXTURE_COUNT_RE = re.compile(r"(?<![A-Za-z0-9_])\d+\s+(?:[A-Za-z][A-Za-z-]*\s+){0,2}fixtures\b")
count_hits = [m.group(0) for m in FIXTURE_COUNT_RE.finditer(portability_text)]
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

portability_rows = gate_engine_table(portability_path, portability_text, r"Engines\b", "Engines")
gate_no_cannot_execute_verdict(portability_path, portability_rows, "Engines")

# ── Step 3: the embed skill's per-target table ─────────────────────────────
embed_rows = gate_engine_table(embed_path, embed_text, r"Per-target honest status", "Per-target honest status")
gate_no_cannot_execute_verdict(embed_path, embed_rows, "Per-target honest status")

# ── Step 4: the embed skill's per-target REFERENCE doc (issue #709) ────────
# Same two questions as rules 3-4, against a file whose per-language unit is a
# `## <Language> — …` SECTION, not a table row. Scoped to the sections for the
# same reason rule 3 is scoped to table rows: every engine's name survives in
# this file's snippets and caveats (`ball-engine`, `go/engine`, "the Dart CLI")
# long after its section is gone, so a whole-file name scan is a fake green.
H2_RE = re.compile(r"^##[ \t]+([^\n]+)$", re.MULTILINE)


def extract_h2_sections(text):
    """[(heading, body)] for every top-level `## ` heading, in document order."""
    heads = list(H2_RE.finditer(text))
    out = []
    for i, m in enumerate(heads):
        end = heads[i + 1].start() if i + 1 < len(heads) else len(text)
        out.append((m.group(1).strip(), text[m.end() : end]))
    return out


def heading_token(heading):
    """The FIRST WORD of a heading — the same convention rule 2 applies to a
    parity row's display name. `## C# — trusted only …` -> "C#";
    `## Transport: …` -> "Transport", which matches no derived language."""
    cleaned = heading.replace("`", "").replace("*", "").strip()
    if not cleaned:
        return ""
    return cleaned.split()[0].rstrip(":,.;")


def has_prose(body):
    """Does this section body carry anything but blank lines and rules?"""
    for line in body.splitlines():
        stripped = line.strip()
        if not stripped or set(stripped) <= set("-=*_"):
            continue
        return True
    return False


sections = extract_h2_sections(per_target_text)
if not sections:
    failures.append(
        f"{per_target_path}: carries no '## ' sections at all — this guard refuses to pass a per-target doc whose per-language sections it cannot even locate"
    )
else:
    by_token = {}
    for heading, body in sections:
        by_token.setdefault(heading_token(heading), []).append((heading, body))

    missing = []
    empty = []
    verdicts = []
    for lang in languages:
        hits = [sec for alias in aliases(lang) for sec in by_token.get(alias, [])]
        if not hits:
            missing.append(lang)
            continue
        for heading, body in hits:
            if not has_prose(body):
                empty.append((lang, heading))
                continue
            hit = cannot_execute_hit(body)
            if hit:
                verdicts.append((lang, hit))

    if missing:
        failures.append(
            f"{per_target_path}: no '## ' section for {', '.join(missing)} — a name in the file's snippets or caveats does NOT count, the per-language section is what an embedder reads"
        )
    else:
        ok(f"{per_target_path}: names all {len(languages)} derived engine(s) in per-language sections (OK)")

    for lang, heading in empty:
        failures.append(
            f"{per_target_path}: the '## {lang}' section carries no prose (heading: \"{heading}\") — a heading with nothing under it is not per-target guidance"
        )

    if verdicts:
        for lang, hit in verdicts:
            failures.append(
                f"{per_target_path}: the '## {lang}' section claims \"{hit}\" — that language has a row in "
                f"conformance-matrix.yml's `summary` parity table, i.e. its engine runs the WHOLE corpus to a "
                f"byte-exact golden on every run (issue #709)"
            )
    elif not missing and not empty:
        ok(f"{per_target_path}: no per-language section claims a parity-table engine cannot execute a program (OK)")

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

  # The fixture mirrors the real workflow's SHAPE, which is what the guard
  # parses: a `jobs:` map, and a `summary` job whose parity table is a run of
  # `print_row "<name>" … needs.<job>.result` calls between the box-drawing
  # header and footer. `changes` and the compiler/round-trip legs are in
  # `needs:` but NOT in the parity table — exactly as in the real file — so a
  # derivation that read `needs:` instead would invent a "Detect"/"C#
  # Compiler" engine here.
  local wf="$SCRATCH/wf.yml"
  cat >"$wf" <<'YAML'
jobs:
  changes:
    name: Detect matrix rows
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
    needs: [changes, dart-engine, ts-engine, ts-compiled-engine, ts-compiled-direct, cpp-compiled, rust-engine, csharp-engine, go-engine, python-engine, csharp-compiler, rust-roundtrip]
    steps:
      - name: Print conformance matrix
        run: |
          echo "╔══╦══╗"
          echo "║ Engine ║"
          echo "╠══╬══╣"

          print_row "Dart Engine (reference)" \
            "${{ needs.dart-engine.result }}"

          print_row "TS Self-Hosted Engine" \
            "${{ needs.ts-engine.result }}"

          print_row "TS Compiled Engine" \
            "${{ needs.ts-compiled-engine.result }}"

          print_row "TS Compiled (Direct)" \
            "${{ needs.ts-compiled-direct.result }}"

          print_row "C++ Compiled" \
            "${{ needs.cpp-compiled.result }}"

          print_row "Rust Self-Hosted Engine" \
            "${{ needs.rust-engine.result }}"

          print_row "C# Self-Hosted Engine" \
            "${{ needs.csharp-engine.result }}"

          print_row "Go Self-Hosted Engine" \
            "${{ needs.go-engine.result }}"

          print_row "Python Self-Hosted Engine" \
            "${{ needs.python-engine.result }}"

          echo "╚══╩══╝"

          printf "%s" "C# Compiler Leg (ratcheted) ${{ needs.csharp-compiler.result }}"
          printf "%s" "Rust Round-Trip Leg (measurement) ${{ needs.rust-roundtrip.result }}"
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

  # "Go" must not be satisfied by "Golden"/"Google": without a TRAILING word
  # boundary a table that never mentions Go still reports as naming it.
  local substring_embed="$SCRATCH/embed_substring.md"
  cat >"$substring_embed" <<'MD'
# Ball Embed

## Per-target honest status

| Target | Embeddable for untrusted input? |
|---|---|
| **Dart** | Yes |
| **TypeScript** | Partial |
| **Rust** | Trusted only |
| **C++** | Trusted only |
| **C#** | Trusted only |
| **Golden Retriever** | Trusted only |
| **Python** | Trusted only |

## Dangerous assumptions
Not part of the table.
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

  # #613's HEADLINE symptom, and the one every count/name rule is blind to:
  # seven rows, seven names, and a C# verdict that flatly contradicts the
  # parity table the guard derives from.
  local stale_embed="$SCRATCH/embed_stale_verdict.md"
  cat >"$stale_embed" <<'MD'
# Ball Embed

## Per-target honest status

| Target | Embeddable for untrusted input? |
|---|---|
| **Dart** | Yes |
| **TypeScript** | Partial |
| **Rust** | Trusted only, and `pub fn run(&self)` takes no parameters. |
| **C++** | Trusted only: no public constructor, and no `ball audit` for C++ at all. |
| **C#** | **No.** Engine does not execute to golden output yet (`SelfHostPendingException`). Encoder + value model only. |
| **Go** | Trusted only. No sandbox, no module-allowlist, no NuGet package yet. |
| **Python** | Trusted only. No sandbox, no module-allowlist, no custom modules. |

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
Not part of the table. Go and Python are named here too.
MD

  # ── embedding-per-target.md fixtures (issue #709) ─────────────────────────
  # The third surface that repeats the same per-language claim, one level
  # deeper than the SKILL.md table: a `## <Language> — …` section per target.
  local good_per_target="$SCRATCH/per_target_good.md"
  cat >"$good_per_target" <<'MD'
# Embedding the Ball engine, per target

## Dart — the reference target (`ball_engine` + `ball_base`, pub.dev)

Sandbox, all resource limits, `moduleHandlers`, and an in-process audit.

## TypeScript — `@ball-lang/engine` (npm)

No run-time module allowlist; the audit is the whole gate.

## Rust — `ball-engine` (NOT published; vendor from git)

Trusted programs only: `run(&self)` takes no arguments.

## C++ — `engine_rt` (vendored, no package)

Trusted-source-only: no public constructor and no `ball audit` for C++.

## C# — trusted only, and only in a `-p:SelfHost=true` build

Built WITH the flag the self-hosted engine runs at Dart parity, but `Run()`
still takes zero parameters.

## Go — `go/engine` (module `github.com/ball-lang/ball/go/engine`)

Trusted only: `TimeoutMs` is the one public knob.

## Python — `ball-lang` wheel (PyPI, package `ball_engine`)

Trusted only: `timeout_ms` is the one public knob.

## Transport: `.ball.bin` vs `.ball.json`

Not a per-language section, and must not be mistaken for one.
MD

  # The fake-green shape, one file over from the table cases: the Go SECTION is
  # gone, but "Go" still appears in the surrounding prose, so a whole-file name
  # scan keeps passing while an embedder gets no Go guidance at all.
  local missing_per_target="$SCRATCH/per_target_missing.md"
  sed '/^## Go — /,/^## Python — /{/^## Python — /!d;}' "$good_per_target" >"$missing_per_target"
  printf '\nGo and Python both ship a `ball` CLI.\n' >>"$missing_per_target"

  # A heading with nothing under it is not a section — that is a fake green too.
  local empty_section_per_target="$SCRATCH/per_target_empty_section.md"
  sed 's/^Trusted only: `TimeoutMs` is the one public knob\.$//' "$good_per_target" >"$empty_section_per_target"

  # #709's headline symptom, faithful to the text #652 hand-corrected in this
  # very file: a present, correctly named C# section carrying a verdict that
  # contradicts the parity table the guard derives from.
  local stale_per_target="$SCRATCH/per_target_stale_verdict.md"
  sed -e 's|^## C# — trusted only.*$|## C# — not embeddable yet|' \
    -e 's|^Built WITH the flag.*$|`CompiledEngine.cs` is generated only under `-p:SelfHost=true`, and even then|' \
    -e 's|^still takes zero parameters\.$|does not reach golden output. There is no working `.Run()` today.|' \
    "$good_per_target" >"$stale_per_target"

  # A doc with no `## ` sections at all must fail loud, never pass trivially.
  local no_sections_per_target="$SCRATCH/per_target_no_sections.md"
  cat >"$no_sections_per_target" <<'MD'
# Embedding the Ball engine, per target

Dart, TypeScript, C++, Rust, C#, Go and Python are all covered below.
MD

  # ── the SWEPT prose docs (issue #765) ─────────────────────────────────────
  # The six docs PR #652 hand-corrected for the same stale-engine claim but
  # left ungated: CLAUDE.md, tests/AGENTS.md, dart/encoder/AGENTS.md,
  # dart/self_host/AGENTS.md, docs/SELF_HOST_STATUS.md and
  # dart/ball_protobuf/README.md. They carry no engine TABLE and no per-language
  # SECTION, so rules 3-5 cannot reach them; what they carry is the same two
  # claims in running prose.
  #
  # This fixture is the NEGATIVE-CONTROL half: every legitimate shape that must
  # keep passing lives here — the four documented embeddability caveats
  # ("Trusted only", "no public constructor", "no NuGet package yet", "does not
  # compile for Flutter web"), a PARTIAL language reference that is not an
  # exhaustive claim ("the TS/C#/Go/Python engine regeneration commands"), a
  # COMPLETE exhaustive enumeration, and two tallies that are not engine
  # tallies ("all four verbs", "three legs").
  local good_swept="$SCRATCH/swept_good.md"
  cat >"$good_swept" <<'MD'
# Notes

- Encoder changes hit user programs AND the self-hosted engine — verify every engine row of
  `conformance-matrix.yml`'s `summary` parity table, not Dart-only.
- The runtime behaves identically across every full-corpus Ball engine (Dart, TypeScript,
  C++, Rust, C#, Go, Python) — see the portability matrix.
- Regenerate via the TS/C#/Go/Python engine regeneration commands above; a partial reference
  to four of them is not a claim about the whole set.
- `ball` exposes all four verbs, and the C# conformance harness has three legs.
- Rust is Trusted only, C++ has no public constructor, Go has no NuGet package yet, and the
  Dart engine does not compile for Flutter web.
MD

  # The exact text PR #652 reverted out of dart/encoder/AGENTS.md and
  # dart/self_host/AGENTS.md. A frozen engine tally is a lie waiting to happen
  # (the set only ever grows), and this one is already wrong by four languages.
  local stale_tally_swept="$SCRATCH/swept_stale_tally.md"
  cat >"$stale_tally_swept" <<'MD'
# Notes

- A Dart-only engine fix is half a fix — re-run conformance on all three engines.
MD

  # An exhaustive claim that ENUMERATES, but omits languages the parity table
  # defines. "every full-corpus engine (Dart, TypeScript, C++)" is the shape
  # docs/SELF_HOST_STATUS.md and dart/ball_protobuf/README.md carry today with a
  # complete list — the moment an 8th engine row lands, theirs look like this.
  local stale_subset_swept="$SCRATCH/swept_stale_subset.md"
  cat >"$stale_subset_swept" <<'MD'
# Notes

The resolver behaves identically across every full-corpus Ball engine (Dart, TypeScript,
C++) — see the portability matrix.
MD

  # A stale EXECUTION verdict in prose, worded outside the five regexes the
  # guard shipped with (issue #765, bullet 1).
  local stale_verdict_swept="$SCRATCH/swept_stale_verdict.md"
  cat >"$stale_verdict_swept" <<'MD'
# Notes

For Go, engine execution is unsupported until the module tags move.
MD

  # ── differently-worded stale verdicts in a CURRENTLY guarded doc (#765) ────
  # Both fixtures are the #613 defect — a row that is present, correctly named
  # and flatly wrong — phrased outside the five regexes the guard shipped with.
  local nonfunctional_embed="$SCRATCH/embed_nonfunctional.md"
  cat >"$nonfunctional_embed" <<'MD'
# Ball Embed

## Per-target honest status

| Target | Embeddable for untrusted input? |
|---|---|
| **Dart** | Yes |
| **TypeScript** | Partial |
| **Rust** | Trusted only, and `pub fn run(&self)` takes no parameters. |
| **C++** | Trusted only: no public constructor, and no `ball audit` for C++ at all. |
| **C#** | **No.** The engine is non-functional for now (`SelfHostPendingException`). |
| **Go** | Trusted only. No sandbox, no module-allowlist, no NuGet package yet. |
| **Python** | Trusted only. No sandbox, no module-allowlist, no custom modules. |

## Dangerous assumptions
Not part of the table.
MD

  local no_output_embed="$SCRATCH/embed_no_output.md"
  cat >"$no_output_embed" <<'MD'
# Ball Embed

## Per-target honest status

| Target | Embeddable for untrusted input? |
|---|---|
| **Dart** | Yes |
| **TypeScript** | Partial |
| **Rust** | Trusted only, and `pub fn run(&self)` takes no parameters. |
| **C++** | Trusted only: no public constructor, and no `ball audit` for C++ at all. |
| **C#** | **No.** It still cannot produce output (`SelfHostPendingException`). |
| **Go** | Trusted only. No sandbox, no module-allowlist, no NuGet package yet. |
| **Python** | Trusted only. No sandbox, no module-allowlist, no custom modules. |

## Dangerous assumptions
Not part of the table.
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
  expect "all four doc surfaces clean pass" 0 "Results: 12 passed, 0 failed, 12 total" \
    "$wf" "$good_portability" "$good_embed" "$good_per_target" "$good_swept"
  expect "hard-coded fixture count fails" 1 "hard-coded fixture count \"293 fixtures\"" \
    "$wf" "$counted_portability" "$good_embed" "$good_per_target" "$good_swept"
  expect "hard-coded engine tally fails" 1 "hard-coded engine count \"7 engines\"" \
    "$wf" "$tallied_portability" "$good_embed" "$good_per_target" "$good_swept"
  expect "quantified tally (\"Each of the 7 rows\") fails, edition years do not" 1 \
    "hard-coded engine count \"Each of the 7\"" \
    "$wf" "$quantified_portability" "$good_embed" "$good_per_target" "$good_swept"
  expect "short portability table fails" 1 "table is missing row(s) for Rust, C#, Go, Python" \
    "$wf" "$partial_portability" "$good_embed" "$good_per_target" "$good_swept"
  expect "portability table missing ONE engine its prose still names fails" 1 \
    "table is missing row(s) for Go" \
    "$wf" "$prose_only_portability" "$good_embed" "$good_per_target" "$good_swept"
  expect "portability table deleted entirely fails" 1 "carries NO markdown table" \
    "$wf" "$no_table_portability" "$good_embed" "$good_per_target" "$good_swept"
  expect "short embed table fails on the row floor" 1 \
    "table has 5 data row(s) but the workflow defines 7 engine(s)" \
    "$wf" "$good_portability" "$short_embed" "$good_per_target" "$good_swept"
  expect "embed table missing engines its prose still names fails" 1 \
    "table is missing row(s) for Go, Python" \
    "$wf" "$good_portability" "$short_embed" "$good_per_target" "$good_swept"

  expect "a substring of an engine name does not count as its row" 1 \
    "table is missing row(s) for Go" \
    "$wf" "$good_portability" "$substring_embed" "$good_per_target" "$good_swept"

  # The verdict rule. The row COUNT and the row NAMES are both fine here, so
  # every other rule passes this fixture — which is exactly why #613's first
  # bullet had no test before.
  expect "embed row claiming a parity engine cannot execute fails" 1 \
    "row claims \"does not execute\"" \
    "$wf" "$good_portability" "$stale_embed" "$good_per_target" "$good_swept"

  # The legitimate vocabulary the verdict rule must NOT eat: "Trusted only",
  # "no public constructor", "no NuGet package yet" all survive in the clean
  # fixture above, whose rows carry each of them.
  expect "embeddability caveats are not execution claims" 0 \
    "no '## Per-target honest status' row claims a parity-table engine cannot execute a program (OK)" \
    "$wf" "$good_portability" "$good_embed" "$good_per_target" "$good_swept"

  # A workflow with an empty summary.needs must fail loud, not pass trivially.
  local empty_wf="$SCRATCH/wf_empty.yml"
  cat >"$empty_wf" <<'YAML'
jobs:
  summary:
    name: Parity Matrix
    needs: []
YAML
  expect "empty summary.needs fails loud" 1 "the \`summary\` job's \`needs:\` list is empty" \
    "$empty_wf" "$good_portability" "$good_embed" "$good_per_target" "$good_swept"

  # A parity row reporting a job the summary does NOT depend on can never make
  # the matrix fail — deriving an engine from it would be a fake green.
  local orphan_wf="$SCRATCH/wf_orphan_row.yml"
  cat >"$orphan_wf" <<'YAML'
jobs:
  dart-engine:
    name: Dart Engine
  zig-engine:
    name: Zig Self-Hosted Engine
  summary:
    name: Parity Matrix
    needs: [dart-engine]
    steps:
      - name: Print conformance matrix
        run: |
          echo "╠══╬══╣"
          print_row "Dart Engine (reference)" "${{ needs.dart-engine.result }}"
          print_row "Zig Self-Hosted Engine" "${{ needs.zig-engine.result }}"
          echo "╚══╩══╝"
YAML
  expect "parity row outside summary.needs fails loud" 1 \
    "which is NOT in the \`summary\` job's \`needs:\`" \
    "$orphan_wf" "$good_portability" "$good_embed" "$good_per_target" "$good_swept"

  # A summary job whose parity table is gone must fail loud, never derive zero
  # engines and pass both docs trivially.
  local no_table_wf="$SCRATCH/wf_no_parity_table.yml"
  cat >"$no_table_wf" <<'YAML'
jobs:
  dart-engine:
    name: Dart Engine
  summary:
    name: Parity Matrix
    needs: [dart-engine]
    steps:
      - name: Print conformance matrix
        run: |
          echo "the rows moved somewhere else"
YAML
  expect "summary job with no parity table fails loud" 1 \
    "could not find the \`summary\` job's parity table" \
    "$no_table_wf" "$good_portability" "$good_embed" "$good_per_target" "$good_swept"

  # A workflow with no summary job at all must fail loud too.
  local no_summary_wf="$SCRATCH/wf_no_summary.yml"
  cat >"$no_summary_wf" <<'YAML'
jobs:
  dart-engine:
    name: Dart Engine
YAML
  expect "missing summary job fails loud" 1 "could not find the \`summary\` job" \
    "$no_summary_wf" "$good_portability" "$good_embed" "$good_per_target" "$good_swept"

  # ── embedding-per-target.md (issue #709) ───────────────────────────────────
  # Rules 1-4 gate two TABLES. This file repeats the same per-language verdict
  # in PROSE and was ungated: adding an 8th engine row, or leaving a retired
  # verdict in place, reds both tables and says nothing about this file.
  expect "per-target doc missing a section for a derived engine fails" 1 \
    "no '## ' section for Go" \
    "$wf" "$good_portability" "$good_embed" "$missing_per_target" "$good_swept"
  expect "per-target section with no prose fails" 1 \
    "'## Go' section carries no prose" \
    "$wf" "$good_portability" "$good_embed" "$empty_section_per_target" "$good_swept"
  expect "per-target section claiming a parity engine cannot execute fails" 1 \
    "does not reach golden output" \
    "$wf" "$good_portability" "$good_embed" "$stale_per_target" "$good_swept"
  expect "per-target doc with no sections at all fails loud" 1 \
    "carries no '## ' sections at all" \
    "$wf" "$good_portability" "$good_embed" "$no_sections_per_target" "$good_swept"
  expect "per-target embeddability caveats are not execution claims" 0 \
    "names all 7 derived engine(s) in per-language sections (OK)" \
    "$wf" "$good_portability" "$good_embed" "$good_per_target" "$good_swept"

  # The mutation issue #709 names outright: an 8th engine row added to the
  # workflow. All three docs here are the CLEAN, real-shaped fixtures --
  # nothing in them changed -- so the ONLY moving part is the source of
  # truth, and the per-target doc must red alongside the two tables instead
  # of staying silent about the new language as it did before #709.
  local eighth_wf="$SCRATCH/wf_eighth_engine.yml"
  sed -e 's|^  summary:$|  zig-engine:\n    name: Zig Self-Hosted Engine\n  summary:|' \
    -e 's|needs: \[changes, |needs: [changes, zig-engine, |' \
    -e 's|^            "${{ needs.python-engine.result }}"$|&\n\n          print_row "Zig Self-Hosted Engine" \\\n            "${{ needs.zig-engine.result }}"|' \
    "$wf" >"$eighth_wf"
  expect "an 8th engine row reds the per-target doc, not just the two tables" 1 \
    "no '## ' section for Zig" \
    "$eighth_wf" "$good_portability" "$good_embed" "$good_per_target" "$good_swept"

  # ── issue #765, bullet 1: the verdict rule may not be a five-phrase allowlist ──
  # Both fixtures are #613's defect verbatim in SHAPE — a row that is present,
  # correctly named, and flatly wrong — worded outside the five hand-picked
  # phrasings the guard shipped with. A reader of either row is told the C#
  # engine cannot run a program, which the parity table contradicts on every run.
  expect "embed row calling a parity engine non-functional fails" 1 \
    "row claims \"engine is non-functional\"" \
    "$wf" "$good_portability" "$nonfunctional_embed" "$good_per_target" "$good_swept"
  expect "embed row saying a parity engine produces no output fails" 1 \
    "row claims \"cannot produce output\"" \
    "$wf" "$good_portability" "$no_output_embed" "$good_per_target" "$good_swept"

  # ── issue #765, bullet 2: the five other docs #652 swept, then left ungated ──
  expect "swept doc freezing an engine tally fails" 1 \
    "hard-coded engine count \"three engines\"" \
    "$wf" "$good_portability" "$good_embed" "$good_per_target" "$stale_tally_swept"
  expect "swept doc enumerating only some engines as if exhaustive fails" 1 \
    "omits Rust, C#, Go, Python" \
    "$wf" "$good_portability" "$good_embed" "$good_per_target" "$stale_subset_swept"
  expect "swept doc claiming a parity engine cannot execute fails" 1 \
    "claims \"execution is unsupported\"" \
    "$wf" "$good_portability" "$good_embed" "$good_per_target" "$stale_verdict_swept"

  # The negative controls the broadened verdict rule must NOT eat, plus the two
  # shapes the engine-set rule must NOT eat: a PARTIAL language reference that
  # makes no exhaustive claim, and a tally of something that is not an engine.
  expect "swept-doc caveats, partial references and non-engine tallies all pass" 0 \
    "no frozen engine-set claim (OK)" \
    "$wf" "$good_portability" "$good_embed" "$good_per_target" "$good_swept"

  # POSITIVE FLOOR. Gating zero swept docs, or one that is not there, must fail
  # loud — a guard that silently checked nothing is the failure mode this whole
  # file exists to prevent.
  expect "zero swept docs fails loud" 1 \
    "refusing to gate ZERO swept docs" \
    "$wf" "$good_portability" "$good_embed" "$good_per_target"
  expect "a swept doc that is not there fails loud" 1 \
    "swept doc not found" \
    "$wf" "$good_portability" "$good_embed" "$good_per_target" "$SCRATCH/does_not_exist.md"

  echo "Results: $pass passed, $fail failed, $((pass + fail)) total"
  if [ "$pass" -lt 30 ]; then
    echo "::error::self-test executed fewer cases than expected ($pass < 30) — a self-test that ran nothing is not a passing self-test."
    return 1
  fi
  [ "$fail" -eq 0 ]
}

if [ "$SELF_TEST" -eq 1 ]; then
  self_test
  exit $?
fi

check_files "$WORKFLOW" "$PORTABILITY" "$EMBED" "$PER_TARGET"
exit $?
