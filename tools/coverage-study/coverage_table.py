#!/usr/bin/env python3
"""Publish the third-party coverage table and enforce its ratchet floors (#493).

Slices 1-3 of issue #493 built the instruments: six Tier A harnesses and two
Tier B harnesses, each printing an honest number and uploading a JSON report as
a workflow artifact. Nothing consumed them. A regression on third-party code
was visible only to someone who downloaded seven artifacts and compared them by
hand against a number written in a GitHub comment, and the numbers themselves
were published nowhere a reader of the repository would find them.

This script is the consumer. It does two jobs in one place, deliberately:

  * RENDER the measured numbers into README.md, between generated-block
    markers, next to the engine-parity table; and
  * FLOOR them against `tools/coverage-study/baseline.json`, failing the run on
    a drop and raising the baseline on an improvement.

They are one script because they must not disagree: a table rendered by one
program and floored by another can publish a number nothing is guarding.

WHY A RATCHET AND NOT THE ISSUE'S 95% / 75%. Issue #493 proposed "Dart Tier A
>= 95%, Tier B >= 75%". Measured, Dart Tier A is 61% and four of the six Tier A
rows are at 0% clean, because those pipelines' compilers emit runtime-call
shaped source their syntactic encoders were never built to read back. A 95%
floor would be red on the first run and stay red, and the project's own rule
for a known-incomplete leg is to RATCHET it: fail only on a drop below a
checked-in baseline, never parity-gate it and never skip it. So every row is
floored at exactly what it measured, and an improvement raises the floor
automatically so the gain cannot be given back silently.

WHAT IS FLOORED, PER ROW. Three axes, because a percentage alone is trivially
gamed by a shrinking denominator, and a 0%-clean row would otherwise have no
live guard at all:

  1. `scored` — the denominator itself, as an absolute floor. Fewer files
     scored than the baseline is a failure even if the percentage improved: a
     shrinking corpus almost always means a checkout or a pin broke, and it
     makes the percentage incomparable. (This is the same reasoning behind
     summarize.sh's positive floor, which fails a run that scored zero.)
  2. `clean / scored` — the headline ratio, compared exactly (by
     cross-multiplication, never on the rounded percentage, so a sub-1% drop
     cannot hide inside the rounding).
  3. `encoded / scored` — Tier A only: how many scored files survived stage 1
     of the funnel. This is what gives the five 0%-clean rows a live guard.
     `clean` cannot fall below 0, but "110 Rust files reached stage 1" can, and
     that is precisely the regression the funnel exists to make visible.

WHAT IS RECORDED BUT NOT FLOORED. `excluded` — the test-only files each Tier A
harness takes out of the denominator since the owner's 2026-09-14 methodology
decision on issue #491. It is not a quality measure (a pin whose own test suite
grew moves it up; one that dropped a test moves it down, and neither is a
regression), but it IS what makes the denominator explainable: a ratio that
moved because an exclusion RULE moved has to be visible in the committed diff,
not only inside a job log. So it is read from every Tier A artifact — where a
MISSING count is a hard failure, exactly like a missing artifact, because a
harness whose rule silently vanished would otherwise publish a denominator
nobody can account for — carried in the baseline, and published in the table.

A row whose artifact is missing, whose report scores nothing, whose verdicts
are not bools, or whose taxonomy tag is unrecognised is a hard failure. An
absent artifact that read as "0 scored, 0 clean" would satisfy every
percentage floor forever, which is the most expensive failure mode available
here.

Usage:
    python3 tools/coverage-study/coverage_table.py \
      --artifacts <dir with the downloaded coverage-study-* artifacts> \
      --baseline tools/coverage-study/baseline.json \
      --readme README.md \
      [--write] [--summary "$GITHUB_STEP_SUMMARY"]

Without `--write` nothing on disk changes: the floors are checked, the raises
and the table staleness are reported, and the exit code is the verdict.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from dataclasses import dataclass
from pathlib import Path

BEGIN_MARKER = "<!-- BEGIN GENERATED: coverage-study (tools/coverage-study/coverage_table.py) -->"
END_MARKER = "<!-- END GENERATED: coverage-study -->"

# Mirrors `_stageByTag` in tools/coverage-study/rq1_study.dart, which the five
# Tier A ports copy verbatim. An unknown tag throws rather than defaulting, for
# the same reason it throws there: a new failure mode quietly folded into the
# wrong funnel row is a number that lies.
_TIER_A_STAGE_BY_TAG = {
    "read-error": 0,
    "encode-error": 0,
    "compile-error": 1,
    "reencode-error": 2,
    "declaration-drift": 3,
    "fixpoint-error": 4,
    "fixpoint-drift": 4,
    "clean": 5,
    # Not scored, so it never reaches the funnel; listed so it is recognised
    # rather than throwing.
    "skipped": 0,
}

# Mirrors `tierBTags` / `scoredTierBTags` in tools/coverage-study/rq1_tierb.dart.
_TIER_B_TAGS = {
    "clean",
    "behavioral-drift",
    "not-compiled",
    "test-timeout",
    "baseline-unstable",
    "skipped",
}

_STAGE_HEADERS = ["1 encoded", "2 compiled back", "3 re-encoded", "4 declarations kept"]


class StudyError(Exception):
    """A condition that must stop the run rather than be reported as a number."""


def pct(n: int, d: int) -> int:
    """The percentage exactly as every harness prints it.

    Dart's `num.round()` rounds halves away from zero; Python's `round()` is
    banker's rounding. `floor(x + 0.5)` matches the harnesses, so a number
    published here is the number the job log shows.
    """
    if d == 0:
        return 0
    return math.floor(n * 100 / d + 0.5)


def _lower_first(key: str) -> str:
    return key[:1].lower() + key[1:]


def _normalise(obj: dict) -> dict:
    """Lower-case the first letter of every key.

    The C# harness serialises through System.Text.Json and emits
    `Package`/`Scored`/`Clean`/`Reason`; the other five emit camelCase. A
    renderer that understood only one casing would read the C# artifact as an
    empty report — that is, as a pass.
    """
    return {_lower_first(k): v for k, v in obj.items()}


def _require_bool(entry: dict, key: str, where: str) -> bool:
    value = entry.get(key)
    if not isinstance(value, bool):
        raise StudyError(
            f"{where}: verdict field '{key}' is {value!r} ({type(value).__name__}), "
            "not a bool — a string verdict is truthy and would silently inflate "
            "the tally"
        )
    return value


def _require_int(value: object, where: str) -> int:
    # `bool` is an `int` subclass in Python; a baseline count of `true` must not
    # sail through as 1.
    if isinstance(value, bool) or not isinstance(value, int):
        raise StudyError(
            f"{where}: {value!r} is not a bare integer — a count that is not an "
            "integer cannot be compared, and comparing it anyway is how a gate "
            "silently disables itself"
        )
    if value < 0:
        raise StudyError(f"{where}: {value!r} is negative")
    return value


@dataclass(frozen=True)
class Measurement:
    """One row's measured numbers, derived from one artifact."""

    scored: int
    clean: int
    stages: tuple[int, int, int, int] | None  # Tier A funnel stages 1..4
    # Test-only files this run took OUT of the denominator (Tier A only).
    # Recorded and published, never floored — see `check_row`.
    excluded: int | None = None

    @property
    def encoded(self) -> int:
        return 0 if self.stages is None else self.stages[0]


def read_report(path: Path) -> tuple[dict, list[dict]]:
    """One harness report: its top-level object, and its per-file verdicts.

    Tier A writes `{"files": [...]}`; Tier B writes `{"packages": [{"files":
    [...]}]}`. A file that is absent, unreadable or neither shape is an error —
    never an empty list, which would read as a flawless 0/0.
    """
    if not path.is_file():
        raise StudyError(
            f"artifact {path} is missing — a report that cannot be read is a "
            "workflow/harness failure, never a 0-scored result (which would "
            "satisfy every percentage floor forever)"
        )
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as err:
        raise StudyError(f"artifact {path} is not valid JSON: {err}") from err
    if not isinstance(raw, dict):
        raise StudyError(f"artifact {path}: expected a JSON object, got {type(raw).__name__}")
    report = _normalise(raw)

    if "files" in report:
        entries = report["files"]
    elif "packages" in report:
        entries = [
            entry
            for package in report["packages"]
            for entry in _normalise(package).get("files", [])
        ]
    else:
        raise StudyError(
            f"artifact {path}: no 'files' or 'packages' key — this is not a "
            "coverage-study harness report"
        )
    if not isinstance(entries, list):
        raise StudyError(f"artifact {path}: 'files' is not a list")
    return report, [_normalise(entry) for entry in entries]


def measure(path: Path, kind: str) -> Measurement:
    """Tally one report exactly the way its harness's own summary line does."""
    report, entries = read_report(path)

    # The test-only exclusion count (the owner's 2026-09-14 methodology decision
    # on issue #491). Tier A no longer scores a package's own test suite, so this
    # count is provenance for the denominator, not decoration — and a report that
    # does not carry it is a harness whose exclusion rule vanished. Reading that
    # as "excluded 0" would publish a denominator nobody could explain, so it is
    # REQUIRED for Tier A, with the same reasoning that makes a missing artifact
    # a failure rather than a flawless 0/0. `summarize.sh` enforces the same
    # requirement on the job's log, inside the job.
    excluded: int | None = None
    if kind == "tier-a":
        if "excludedTestOnly" not in report:
            raise StudyError(
                f"artifact {path}: no 'excludedTestOnly' count — the Tier A harness's "
                "test-only exclusion rule is missing, so the denominator cannot be "
                "explained (issue #491). A count of 0 is a valid answer; an absent "
                "one is not."
            )
        excluded = _require_int(report["excludedTestOnly"], f"{path} 'excludedTestOnly'")

    scored = []
    for entry in entries:
        where = f"{path}: {entry.get('package', '?')}/{entry.get('file', '?')}"
        reason = entry.get("reason")
        if not isinstance(reason, str) or not reason:
            raise StudyError(f"{where}: missing taxonomy reason")
        tag = reason.split(":", 1)[0]
        if kind == "tier-a":
            if tag not in _TIER_A_STAGE_BY_TAG:
                raise StudyError(
                    f'{where}: unrecognised Tier A taxonomy tag "{tag}" — the '
                    "funnel would silently lie; teach this script the tag and "
                    "its stage"
                )
        elif tag not in _TIER_B_TAGS:
            raise StudyError(
                f'{where}: unrecognised Tier B taxonomy tag "{tag}" — the tally '
                "would silently lie"
            )
        if _require_bool(entry, "scored", where):
            scored.append((tag, _require_bool(entry, "clean", where)))

    total = len(scored)
    if total < 1:
        raise StudyError(
            f"artifact {path} scored 0 files — that is a checkout/harness "
            "failure, never a 0% result (tools/coverage-study/summarize.sh "
            "applies the same positive floor inside each job)"
        )
    clean = sum(1 for _, is_clean in scored if is_clean)

    stages: tuple[int, int, int, int] | None = None
    if kind == "tier-a":
        reached = [_TIER_A_STAGE_BY_TAG[tag] for tag, _ in scored]
        stages = tuple(sum(1 for r in reached if r >= n) for n in (1, 2, 3, 4))  # type: ignore[assignment]
    return Measurement(scored=total, clean=clean, stages=stages, excluded=excluded)


@dataclass
class BaselineRow:
    language: str
    tier: str
    kind: str
    artifact: str
    scored: int
    clean: int
    encoded: int | None
    excluded: int | None

    @property
    def label(self) -> str:
        return f"{self.language} {self.tier}"


def load_baseline(path: Path) -> list[BaselineRow]:
    if not path.is_file():
        raise StudyError(f"baseline {path} is missing")
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict) or not isinstance(raw.get("rows"), list):
        raise StudyError(f"baseline {path}: expected an object with a 'rows' list")
    rows: list[BaselineRow] = []
    for index, entry in enumerate(raw["rows"]):
        where = f"{path} row {index}"
        if not isinstance(entry, dict):
            raise StudyError(f"{where}: expected an object")
        kind = entry.get("kind")
        if kind not in ("tier-a", "tier-b"):
            raise StudyError(f"{where}: kind must be 'tier-a' or 'tier-b', got {kind!r}")
        for key in ("language", "tier", "artifact"):
            if not isinstance(entry.get(key), str) or not entry[key]:
                raise StudyError(f"{where}: '{key}' must be a non-empty string")
        encoded = None
        excluded = None
        if kind == "tier-a":
            encoded = _require_int(entry.get("encoded"), f"{where} 'encoded'")
            excluded = _require_int(entry.get("excluded"), f"{where} 'excluded'")
        else:
            if "encoded" in entry:
                raise StudyError(f"{where}: a Tier B row has no funnel, so no 'encoded'")
            if "excluded" in entry:
                raise StudyError(
                    f"{where}: a Tier B row has no test-only exclusion rule, so no 'excluded'"
                )
        rows.append(
            BaselineRow(
                language=entry["language"],
                tier=entry["tier"],
                kind=kind,
                artifact=entry["artifact"],
                scored=_require_int(entry.get("scored"), f"{where} 'scored'"),
                clean=_require_int(entry.get("clean"), f"{where} 'clean'"),
                encoded=encoded,
                excluded=excluded,
            )
        )
    # A baseline with no rows would check nothing and exit 0 — the exact
    # fake-green shape this whole file exists to prevent.
    if not rows:
        raise StudyError(f"baseline {path} declares no rows — nothing would be floored")
    seen = set()
    for row in rows:
        if row.artifact in seen:
            raise StudyError(f"baseline {path}: two rows claim artifact {row.artifact}")
        seen.add(row.artifact)
    return rows


def discover_artifacts(artifacts_dir: Path) -> set[str]:
    """Every report file present, as a POSIX path relative to the download dir."""
    if not artifacts_dir.is_dir():
        raise StudyError(f"artifact directory {artifacts_dir} does not exist")
    return {
        path.relative_to(artifacts_dir).as_posix()
        for path in sorted(artifacts_dir.rglob("*.json"))
    }


def ratio_below(measured_n: int, measured_d: int, base_n: int, base_d: int) -> bool:
    """`measured_n/measured_d < base_n/base_d`, exactly.

    Cross-multiplied rather than compared on the rounded percentage, so a drop
    smaller than the rounding step still fails.
    """
    return measured_n * base_d < base_n * measured_d


def check_row(row: BaselineRow, measured: Measurement) -> tuple[list[str], BaselineRow | None]:
    """Floor one row. Returns its breaches and, if any, the raised baseline."""
    breaches: list[str] = []

    if measured.scored < row.scored:
        breaches.append(
            f"{row.label}: scored {measured.scored} files, below the baseline "
            f"{row.scored} — the corpus shrank, so the percentage is not "
            "comparable (a pin that failed to clone, or files that stopped "
            "being collected). Fix the run, or re-seed this row deliberately."
        )
    if ratio_below(measured.clean, measured.scored, row.clean, row.scored):
        breaches.append(
            f"{row.label}: clean {measured.clean}/{measured.scored} "
            f"({pct(measured.clean, measured.scored)}%) is below the baseline "
            f"{row.clean}/{row.scored} ({pct(row.clean, row.scored)}%)"
        )
    if row.kind == "tier-a":
        assert row.encoded is not None and measured.stages is not None
        if ratio_below(measured.encoded, measured.scored, row.encoded, row.scored):
            breaches.append(
                f"{row.label}: funnel stage 1 encoded "
                f"{measured.encoded}/{measured.scored} "
                f"({pct(measured.encoded, measured.scored)}%) is below the "
                f"baseline {row.encoded}/{row.scored} "
                f"({pct(row.encoded, row.scored)}%)"
            )

    if breaches:
        return breaches, None

    # `excluded` is RECORDED, NOT FLOORED. It is not a quality measure: a pin
    # whose own test suite grew moves it up and a pin that dropped one moves it
    # down, and neither is a regression. What it is for is the committed diff —
    # a denominator that moved because an exclusion RULE moved must be visible
    # in `baseline.json`, not only inside a job log nobody reads. So a change to
    # it updates the row without being a breach.
    raised = (
        measured.scored != row.scored
        or measured.clean != row.clean
        or (
            row.kind == "tier-a"
            and (measured.encoded != row.encoded or measured.excluded != row.excluded)
        )
    )
    if not raised:
        return [], None
    return [], BaselineRow(
        language=row.language,
        tier=row.tier,
        kind=row.kind,
        artifact=row.artifact,
        scored=measured.scored,
        clean=measured.clean,
        encoded=measured.encoded if row.kind == "tier-a" else None,
        excluded=measured.excluded if row.kind == "tier-a" else None,
    )


def render_table(rows: list[tuple[BaselineRow, Measurement]]) -> str:
    """The generated README block. A pure function of the measurements.

    Deliberately carries no timestamp and no run id: the weekly job commits
    this file, and a block that changed every week regardless of the numbers
    would bury a real movement in noise. Provenance lives in the bot commit
    message, which names the run that produced it.
    """
    lines = [
        BEGIN_MARKER,
        "<!-- Regenerated by .github/workflows/coverage-study.yml — do not hand-edit. -->",
        "",
        "| Measure | scored | clean | "
        + " | ".join(_STAGE_HEADERS)
        + " | excluded (test-only) |",
        "| --- | ---: | ---: | "
        + " | ".join("---:" for _ in _STAGE_HEADERS)
        + " | ---: |",
    ]
    for row, measured in rows:
        cells = [
            f"**{row.language}** — {row.tier}",
            str(measured.scored),
            f"{measured.clean} ({pct(measured.clean, measured.scored)}%)",
        ]
        if measured.stages is None:
            cells += ["—"] * len(_STAGE_HEADERS)
        else:
            cells += [str(n) for n in measured.stages]
        cells.append("—" if measured.excluded is None else str(measured.excluded))
        lines.append("| " + " | ".join(cells) + " |")
    lines += [
        "",
        "Measured over pinned **third-party** packages — code this project did not "
        "write — by `.github/workflows/coverage-study.yml` (weekly, plus "
        "`workflow_dispatch`). Tier A is structural (encode → compile back → "
        "re-encode → declaration inventory → fixpoint); Tier B substitutes the "
        "compiled-back file into the package's own test suite, which is the tier "
        "that sees a construct that round-trips cleanly but changes what the "
        "program computes.",
        "",
        "Tier A scores **library code only**: a package's own test suite is a "
        "different population — written against that package's internals, compiled "
        "under different settings, and encoded by nobody — so it is excluded from "
        "the denominator by each language's own convention, and the count of what "
        "that removed is published above rather than applied silently.",
        "",
        "Every row is **floored at the number shown**: the workflow fails on a drop "
        "in the clean ratio, in the stage-1 funnel ratio, or in the scored "
        "denominator, and raises the floor automatically on an improvement "
        "(`tools/coverage-study/baseline.json`). The exclusion count is recorded "
        "there too but is **not** floored — a pin whose own test suite grew moves it "
        "in either direction and neither is a regression. Four rows sit at 0% clean because "
        "those compilers emit runtime-call-shaped source their syntactic encoders "
        "cannot read back — for those, the funnel columns are the live signal. See "
        "`tests/conformance/COVERAGE_STUDY.md` for the methodology and the honest "
        "limits.",
        END_MARKER,
    ]
    return "\n".join(lines)


def splice(readme_text: str, block: str, readme_path: Path) -> str:
    begin = readme_text.find(BEGIN_MARKER)
    end = readme_text.find(END_MARKER)
    if begin == -1 or end == -1 or end < begin:
        raise StudyError(
            f"{readme_path} has no generated-block markers (or they are out of "
            f"order). Add these two lines where the table belongs:\n"
            f"  {BEGIN_MARKER}\n  {END_MARKER}"
        )
    if readme_text.count(BEGIN_MARKER) != 1 or readme_text.count(END_MARKER) != 1:
        raise StudyError(f"{readme_path}: the generated-block markers appear more than once")
    return readme_text[:begin] + block + readme_text[end + len(END_MARKER):]


def read_preserving_newlines(path: Path) -> tuple[str, bool]:
    """The file's text with LF line endings, plus whether it was CRLF on disk.

    A checkout on Windows (or with `core.autocrlf=true`) holds these files as
    CRLF. Writing them back as LF would rewrite every line of README.md and
    show up as a whole-file diff that has nothing to do with the numbers, so
    the original convention is detected here and restored on write.
    """
    raw = path.read_bytes().decode("utf-8")
    return raw.replace("\r\n", "\n"), "\r\n" in raw


def write_preserving_newlines(path: Path, text: str, crlf: bool) -> None:
    out = text.replace("\n", "\r\n") if crlf else text
    path.write_bytes(out.encode("utf-8"))


def dump_baseline(rows: list[BaselineRow], previous: dict) -> str:
    out = dict(previous)
    out["rows"] = [
        {
            "language": row.language,
            "tier": row.tier,
            "kind": row.kind,
            "artifact": row.artifact,
            "scored": row.scored,
            "clean": row.clean,
            **(
                {"encoded": row.encoded, "excluded": row.excluded}
                if row.kind == "tier-a"
                else {}
            ),
        }
        for row in rows
    ]
    return json.dumps(out, indent=2) + "\n"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts", required=True, help="directory holding the downloaded coverage-study-* artifacts")
    parser.add_argument("--baseline", required=True, help="path to baseline.json")
    parser.add_argument("--readme", required=True, help="path to the README carrying the generated block")
    parser.add_argument("--write", action="store_true", help="persist the regenerated table and the raised baseline")
    parser.add_argument("--summary", default=None, help="append the rendered table to this file (GITHUB_STEP_SUMMARY)")
    args = parser.parse_args(argv)

    artifacts_dir = Path(args.artifacts)
    baseline_path = Path(args.baseline)
    readme_path = Path(args.readme)

    try:
        baseline = load_baseline(baseline_path)
        present = discover_artifacts(artifacts_dir)
        floored = {row.artifact for row in baseline}
        unfloored = sorted(present - floored)
        if unfloored:
            raise StudyError(
                "these artifacts have no baseline row, so they would be "
                "published with nothing guarding them: "
                + ", ".join(unfloored)
                + f". Add a row to {baseline_path} with the numbers this run "
                "measured, in the same PR that added the job."
            )

        measured_rows: list[tuple[BaselineRow, Measurement]] = []
        for row in baseline:
            measured_rows.append((row, measure(artifacts_dir / row.artifact, row.kind)))
    except StudyError as err:
        print(f"ERROR: {err}", file=sys.stderr)
        return 1

    breaches: list[str] = []
    raises: list[str] = []
    final_rows: list[BaselineRow] = []
    for row, measured in measured_rows:
        row_breaches, raised = check_row(row, measured)
        breaches += row_breaches
        if raised is not None:
            detail = (
                f"{row.label}: clean {row.clean}/{row.scored} -> "
                f"{raised.clean}/{raised.scored}"
            )
            if row.kind == "tier-a":
                detail += f", stage 1 encoded {row.encoded}/{row.scored} -> {raised.encoded}/{raised.scored}"
            raises.append(detail)
        final_rows.append(raised if raised is not None else row)
        status = "BELOW" if row_breaches else ("up" if raised is not None else "at floor")
        print(
            f"  {row.label:<32} clean {measured.clean}/{measured.scored} "
            f"({pct(measured.clean, measured.scored)}%)  "
            f"floor {row.clean}/{row.scored} ({pct(row.clean, row.scored)}%)  {status}"
        )
    print(f"Rows checked: {len(measured_rows)}, breaches: {len(breaches)}")

    if breaches:
        for breach in breaches:
            print(f"::error::coverage-study floor breach — {breach}")
            print(f"ERROR: coverage-study floor breach — {breach}", file=sys.stderr)
        print(
            "ERROR: the baseline is NOT updated on a breach. Fix the regression, "
            f"or lower {baseline_path} deliberately in a reviewed commit.",
            file=sys.stderr,
        )
        return 1

    if raises:
        print("Baseline raised by this run (a gain must not be givable back silently):")
        for detail in raises:
            print(f"  {detail}")

    block = render_table(measured_rows)
    try:
        readme_text, readme_crlf = read_preserving_newlines(readme_path)
        new_readme = splice(readme_text, block, readme_path)
    except (OSError, StudyError) as err:
        print(f"ERROR: {err}", file=sys.stderr)
        return 1

    baseline_text, baseline_crlf = read_preserving_newlines(baseline_path)
    new_baseline = dump_baseline(final_rows, json.loads(baseline_text))
    baseline_stale = new_baseline != baseline_text
    readme_stale = new_readme != readme_text

    if args.write:
        if readme_stale:
            write_preserving_newlines(readme_path, new_readme, readme_crlf)
        if baseline_stale:
            write_preserving_newlines(baseline_path, new_baseline, baseline_crlf)
        print(
            f"Wrote: README {'updated' if readme_stale else 'already current'}, "
            f"baseline {'updated' if baseline_stale else 'already current'}"
        )
    else:
        print(
            f"Check only: README {'is stale' if readme_stale else 'is current'}, "
            f"baseline {'is stale' if baseline_stale else 'is current'} "
            "(pass --write to regenerate)"
        )

    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as handle:
            handle.write("## Third-party coverage study\n\n")
            handle.write(block + "\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
