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
  3. EVERY funnel stage, as `<stage> / scored` — Tier A only: how many scored
     files survived stage 1 (`encoded`), stage 2 (`compiledBack`), stage 3
     (`reencoded`) and stage 4 (`declarationsKept`). This is what gives the
     five 0%-clean rows a live guard. `clean` cannot fall below 0, but "110
     Rust files reached stage 1" can, and that is precisely the regression the
     funnel exists to make visible.

     Stage 3 earns its own floor by name (issue #632): it is the only stage
     whose INPUT is this repository's own output. Stages 1 and 2 read
     third-party source and the Ball IR encoded from it, while stage 3
     re-encodes what this project's compiler just emitted — so a construct the
     compiler emits that its own encoder refuses lands here and nowhere else,
     which is how `rust/compiler`'s `panic!` dispatcher arm, refused by
     `rust/encoder`, went unseen by every other gate the project has. The
     funnel is monotone (a file that failed stage n cannot pass stage n+1), so
     every stage's floor also fails when an earlier stage regresses; they are
     kept separate anyway, because WHERE a row stopped is the whole signal on a
     pipeline whose round trip is not closed, and a trade (stage 1 up, stage 3
     down) must not net out to silence.

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

THE PER-FILE LIST, AND WHY A COUNT WAS NOT ENOUGH (issue #676). Every Tier A
harness also writes the exclusions it applied as `excluded: [{package, file,
rule}]`, and `tools/coverage-study/excluded.json` is that list COMMITTED — per
language, per pin, sorted paths. It is read here and diffed, because the counts
alone cannot state the property that matters: a PARTIAL drop (34 -> 31, three
files readmitted into the denominator) is arithmetically identical to "the pin's
test suite shrank by 3 while its library grew by 3", so `scored`, `clean`, the
funnel and the total-collapse check below are all satisfied by it. The diff is
not arithmetic and needs no inference: a path the committed list excludes and
this run SCORED was readmitted, and the breach names it. A path that is merely
gone is NOT a breach — the pin may simply have deleted the file — so only
positive evidence fires, the same rule the count-based check follows. A newly
excluded path is reported and the committed list is regenerated, exactly the way
`baseline.json` is; when a pin's test population legitimately changes, that
regenerated list is committed in the same reviewed PR.

The artifact must CARRY that list, and its length must agree with the count: a
report with a count and no list is back to a number nothing can diff, and
reading it as "nothing was excluded" would disarm this check silently. Every
Tier A row must also have an entry in the committed list — an empty object is
how a row with no exclusions is declared; an ABSENT key is not a way to say
anything, and would leave that row's exclusions diffed against nothing.

THE ONE SHAPE OF THAT COUNT THAT *IS* A BREACH (issue #648). `excluded` falling
to 0 from a baseline above it, while `scored` rises by at least that many files,
is not a pin that dropped its tests: it is the whole excluded population
RE-ENTERING the denominator, which is an exclusion RULE that stopped firing. The
measured way for that to happen is Rust's — its 34 exclusions all come from the
`#[cfg(test)]` reachability half, which is anchored on a crate root, so a pin
whose layout moved or a `--source-dir` one level too deep used to switch that
half off silently. None of the three floors can see it: the denominator GREW,
and if the readmitted files happen to be clean every ratio improves too, so the
run reads as a pure raise and re-floors the row on a population nobody chose.
So that shape is reported as a breach naming that cause, and the baseline is not
raised. A drop to 0 with an UNCHANGED denominator stays an ordinary raise —
nothing was readmitted, so there is nothing to explain.

A row whose artifact is missing, whose report scores nothing, whose verdicts
are not bools, or whose taxonomy tag is unrecognised is a hard failure. An
absent artifact that read as "0 scored, 0 clean" would satisfy every
percentage floor forever, which is the most expensive failure mode available
here.

Usage:
    python3 tools/coverage-study/coverage_table.py \
      --artifacts <dir with the downloaded coverage-study-* artifacts> \
      --baseline tools/coverage-study/baseline.json \
      --excluded-list tools/coverage-study/excluded.json \
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

# The baseline key carrying each stage above, index for index. Named rather
# than positional: a baseline is read as a diff by a human, and `[141, 140, 58,
# 0]` says which number moved only to a reader who has this file open.
_STAGE_KEYS = ("encoded", "compiledBack", "reencoded", "declarationsKept")


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


def _require_name(value: object, where: str) -> str:
    """A pin name or a relative path: a non-empty string, and nothing else.

    These are the keys the exclusion diff joins on, so an absent or oddly-typed
    one would silently make a file un-matchable — i.e. would take it out of the
    check rather than out of the denominator.
    """
    if not isinstance(value, str) or not value:
        raise StudyError(
            f"{where}: {value!r} is not a non-empty string — the excluded-list "
            "diff joins on (package, file), so a nameless entry cannot be "
            "matched and would silently escape the check"
        )
    return value


def _read_excluded_files(path: Path, report: dict, count: int) -> dict[str, list[str]]:
    """The per-file exclusion list a Tier A artifact carries (issue #676).

    Required, like the count beside it: a harness that reports "34 excluded" and
    no list is a number nothing can diff, and reading that as "nothing was
    excluded" would silently disarm the readmission check — the exact shape of
    failure this project keeps being bitten by. The count and the list are two
    views of one population written by one harness, so a disagreement between
    them means one is stale and neither can stand for the other.
    """
    if "excluded" not in report:
        raise StudyError(
            f"artifact {path}: carries 'excludedTestOnly' but no 'excluded' "
            "per-file list — a count with no list behind it cannot be diffed "
            "against tools/coverage-study/excluded.json, so a partially "
            "readmitted population would be invisible (issue #676). Every Tier A "
            "harness writes the list as [{package, file, rule}]."
        )
    raw = report["excluded"]
    if not isinstance(raw, list):
        raise StudyError(f"artifact {path}: 'excluded' is not a list")
    by_pin: dict[str, list[str]] = {}
    seen: set[tuple[str, str]] = set()
    for index, item in enumerate(raw):
        where = f"{path} 'excluded'[{index}]"
        if not isinstance(item, dict):
            raise StudyError(f"{where}: expected an object")
        entry = _normalise(item)
        pin = _require_name(entry.get("package"), f"{where} 'package'")
        file = _require_name(entry.get("file"), f"{where} 'file'")
        # The rule is not diffed (its wording is harness prose, and churning the
        # committed list on a reworded string would bury real movement), but it
        # must be there: an exclusion with no stated rule is a filter again.
        _require_name(entry.get("rule"), f"{where} 'rule'")
        if (pin, file) in seen:
            raise StudyError(
                f"{where}: {pin}/{file} is excluded twice — the count and the "
                "list would describe different populations"
            )
        seen.add((pin, file))
        by_pin.setdefault(pin, []).append(file)
    if len(seen) != count:
        raise StudyError(
            f"artifact {path}: 'excludedTestOnly' is {count} but the 'excluded' "
            f"list holds {len(seen)} files — the count and the list disagree, so "
            "one of them is stale and neither can be trusted to stand for the "
            "other"
        )
    return {pin: sorted(files) for pin, files in sorted(by_pin.items())}


@dataclass(frozen=True)
class Measurement:
    """One row's measured numbers, derived from one artifact."""

    scored: int
    clean: int
    stages: tuple[int, int, int, int] | None  # Tier A funnel stages 1..4
    # Test-only files this run took OUT of the denominator (Tier A only).
    # Recorded and published, never floored — see `check_row`.
    excluded: int | None = None
    # The same population as PATHS, pin -> sorted relative paths, and the
    # (pin, path) pairs this run scored (Tier A only). The count above says how
    # many files an exclusion rule removed; these two say WHICH, which is the
    # only way to tell a partial readmission from a pin whose own test suite
    # moved (issue #676).
    excluded_files: dict[str, list[str]] | None = None
    scored_files: frozenset[tuple[str, str]] | None = None


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
    excluded_files: dict[str, list[str]] | None = None
    if kind == "tier-a":
        if "excludedTestOnly" not in report:
            raise StudyError(
                f"artifact {path}: no 'excludedTestOnly' count — the Tier A harness's "
                "test-only exclusion rule is missing, so the denominator cannot be "
                "explained (issue #491). A count of 0 is a valid answer; an absent "
                "one is not."
            )
        excluded = _require_int(report["excludedTestOnly"], f"{path} 'excludedTestOnly'")
        excluded_files = _read_excluded_files(path, report, excluded)

    scored = []
    scored_pairs: set[tuple[str, str]] = set()
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
            if kind == "tier-a":
                scored_pairs.add(
                    (
                        _require_name(entry.get("package"), f"{where} 'package'"),
                        _require_name(entry.get("file"), f"{where} 'file'"),
                    )
                )

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
    return Measurement(
        scored=total,
        clean=clean,
        stages=stages,
        excluded=excluded,
        excluded_files=excluded_files,
        scored_files=frozenset(scored_pairs) if kind == "tier-a" else None,
    )


@dataclass
class BaselineRow:
    language: str
    tier: str
    kind: str
    artifact: str
    scored: int
    clean: int
    # Tier A only: the four funnel stages, index for index with _STAGE_KEYS
    # (and so with _STAGE_HEADERS and Measurement.stages). `None` on a Tier B
    # row, which has no funnel at all.
    funnel: tuple[int, int, int, int] | None
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
        funnel = None
        excluded = None
        if kind == "tier-a":
            # Every stage is required. A missing one cannot default to 0 (that
            # floors the row at nothing) and cannot default to the measured
            # value (that floors it at whatever this run happened to do), so it
            # is an error naming the key.
            funnel = tuple(
                _require_int(entry.get(key), f"{where} '{key}'") for key in _STAGE_KEYS
            )
            for earlier, later in zip(_STAGE_KEYS, _STAGE_KEYS[1:]):
                if entry[earlier] < entry[later]:
                    raise StudyError(
                        f"{where}: funnel stage '{later}' ({entry[later]}) is above "
                        f"'{earlier}' ({entry[earlier]}) — the funnel is monotone (a "
                        "file that failed a stage cannot pass the next one), so this "
                        "row cannot have come from a real run; re-seed it from one"
                    )
            excluded = _require_int(entry.get("excluded"), f"{where} 'excluded'")
        else:
            for key in _STAGE_KEYS:
                if key in entry:
                    raise StudyError(
                        f"{where}: a Tier B row has no funnel, so no '{key}'"
                    )
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
                funnel=funnel,  # type: ignore[arg-type]
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


def load_excluded_list(path: Path) -> dict[str, dict[str, list[str]]]:
    """The committed per-file exclusion list: language -> pin -> sorted paths.

    Canonical by construction — sorted, unique, no empty names — so the file
    `--write` regenerates is byte-comparable with the one in git, and a hand
    edit that appends out of order is rejected with an instruction to regenerate
    rather than producing a diff nobody can read.
    """
    if not path.is_file():
        raise StudyError(
            f"excluded list {path} is missing — without it a readmitted "
            "exclusion has nothing to be diffed against (issue #676)"
        )
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict) or not isinstance(raw.get("languages"), dict):
        raise StudyError(f"{path}: expected an object with a 'languages' object")
    out: dict[str, dict[str, list[str]]] = {}
    for language, pins in raw["languages"].items():
        if not isinstance(pins, dict):
            raise StudyError(f"{path}: '{language}' must map pin names to path lists")
        by_pin: dict[str, list[str]] = {}
        for pin, paths in pins.items():
            where = f"{path} '{language}'/'{pin}'"
            _require_name(pin, f"{where} pin name")
            if not isinstance(paths, list):
                raise StudyError(f"{where}: expected a list of paths")
            files = [_require_name(item, f"{where}[{i}]") for i, item in enumerate(paths)]
            if files != sorted(files) or len(set(files)) != len(files):
                raise StudyError(
                    f"{where}: the paths are not sorted and unique. This file is "
                    "generated — regenerate it with coverage_table.py --write "
                    "rather than editing it by hand."
                )
            by_pin[pin] = files
        out[language] = by_pin
    return out


def excluded_diff(
    committed: dict[str, list[str]], measured: dict[str, list[str]]
) -> tuple[list[tuple[str, str]], list[tuple[str, str]]]:
    """(newly excluded, no longer excluded) as sorted (pin, path) pairs."""
    before = {(pin, path) for pin, paths in committed.items() for path in paths}
    after = {(pin, path) for pin, paths in measured.items() for path in paths}
    return sorted(after - before), sorted(before - after)


# A breach message is one `::error::` annotation, which is one line, so a row
# that readmitted its whole population would otherwise print an unreadable wall.
# The count is always exact; the names are truncated with the remainder stated.
_MAX_NAMED_FILES = 20


def _name_files(pairs: list[tuple[str, str]]) -> str:
    shown = ", ".join(f"{pin}/{path}" for pin, path in pairs[:_MAX_NAMED_FILES])
    rest = len(pairs) - _MAX_NAMED_FILES
    return f"{shown} (+{rest} more)" if rest > 0 else shown


def readmission_breach(
    row: BaselineRow, measured: Measurement, committed: dict[str, list[str]]
) -> list[str]:
    """Files the committed list excludes and this run SCORED (issue #676).

    This is the check the three ratio floors and the #648 count check cannot
    express. A PARTIAL readmission — 3 of 34 — moves `excluded` down by 3 and
    `scored` up by 3, which is indistinguishable from a pin whose test suite
    shrank by 3 while its library grew by 3. Diffing the paths needs no such
    inference: these exact files were out of the denominator by a RULE, and now
    they are in it.

    Only positive evidence fires. A committed path that is simply absent from
    this run (neither excluded nor scored) is NOT reported here — the pin may
    have deleted the file — and the regenerated list drops it quietly.
    """
    if measured.scored_files is None:
        return []
    readmitted = sorted(
        (pin, path)
        for pin, paths in committed.items()
        for path in paths
        if (pin, path) in measured.scored_files
    )
    if not readmitted:
        return []
    return [
        f"{row.label}: {len(readmitted)} file(s) that "
        "tools/coverage-study/excluded.json records as test-only were SCORED by "
        f"this run: {_name_files(readmitted)}. They were readmitted into the "
        "denominator, which is an exclusion RULE that stopped applying to them — "
        "no ratio can see it, because the denominator grew and the readmitted "
        "files may well be clean. The baseline is NOT raised. Fix the harness or "
        "the pin; if that pin's test population legitimately changed, regenerate "
        "tools/coverage-study/excluded.json and commit it in the same PR."
    ]


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


def exclusion_rule_breach(row: BaselineRow, measured: Measurement) -> list[str]:
    """The breach for an exclusion rule that stopped firing (issue #648).

    Fires on ONE shape and says so: the row's whole excluded population is gone
    (`excluded` 34 -> 0) and at least that many extra files turned up in the
    denominator. Those files did not appear — they were readmitted, because the
    rule that removed them no longer does. The three ratio/denominator floors
    are blind to it by construction (the denominator grew, and the ratios may
    well have improved), and `excluded` itself is deliberately not floored, so
    without this the run is a silent RAISE onto a population nobody chose.

    A PARTIAL drop is not flagged HERE, and cannot be: "the test suite shrank by
    3 while the library grew by 3" and "3 files stopped being excluded" have the
    same arithmetic signature, and this check only reports a cause it can
    positively show. `readmission_breach` is what sees a partial drop (#676), by
    diffing the committed per-file list instead of the counts; the harness-side
    guard catches the crate-root cause in-job (#648). This check remains the one
    that needs no committed list at all, so it still fires on a row whose whole
    population vanished even if the list were empty.
    """
    if row.excluded is None or measured.excluded is None:
        return []
    if row.excluded <= 0 or measured.excluded != 0:
        return []
    readmitted = measured.scored - row.scored
    if readmitted < row.excluded:
        return []
    return [
        f"{row.label}: the test-only exclusion count dropped {row.excluded} -> 0 while "
        f"`scored` rose {row.scored} -> {measured.scored} (+{readmitted}) — the whole "
        "excluded population re-entered the denominator, so this is an exclusion RULE "
        "that stopped firing (a crate root that no longer resolves, a studied subtree one "
        "level too deep, a pin whose layout moved), not an improvement. The baseline is "
        "NOT raised. Fix the harness or the pin; if the rule legitimately no longer "
        "applies to this row, re-seed it deliberately in a reviewed commit."
    ]


def check_row(
    row: BaselineRow,
    measured: Measurement,
    committed_excluded: dict[str, list[str]],
) -> tuple[list[str], BaselineRow | None]:
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
        assert row.funnel is not None and measured.stages is not None
        for header, floor, now in zip(_STAGE_HEADERS, row.funnel, measured.stages):
            if ratio_below(now, measured.scored, floor, row.scored):
                breaches.append(
                    f"{row.label}: funnel stage {header} "
                    f"{now}/{measured.scored} "
                    f"({pct(now, measured.scored)}%) is below the "
                    f"baseline {floor}/{row.scored} "
                    f"({pct(floor, row.scored)}%)"
                )
        breaches += exclusion_rule_breach(row, measured)
        breaches += readmission_breach(row, measured, committed_excluded)

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
            and (measured.stages != row.funnel or measured.excluded != row.excluded)
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
        funnel=measured.stages if row.kind == "tier-a" else None,
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
        "in the clean ratio, in ANY funnel stage's ratio, or in the scored "
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
                {
                    **dict(zip(_STAGE_KEYS, row.funnel or ())),
                    "excluded": row.excluded,
                }
                if row.kind == "tier-a"
                else {}
            ),
        }
        for row in rows
    ]
    return json.dumps(out, indent=2) + "\n"


def dump_excluded_list(
    rows: list[tuple[BaselineRow, Measurement]], previous: dict
) -> str:
    """The committed list, regenerated from this run's Tier A artifacts.

    Every top-level key but `languages` is carried through, so the file's own
    header notes survive a regeneration.
    """
    out = dict(previous)
    out["languages"] = {
        row.language: dict(measured.excluded_files or {})
        for row, measured in sorted(rows, key=lambda pair: pair[0].language)
        if row.kind == "tier-a"
    }
    return json.dumps(out, indent=2) + "\n"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts", required=True, help="directory holding the downloaded coverage-study-* artifacts")
    parser.add_argument("--baseline", required=True, help="path to baseline.json")
    parser.add_argument(
        "--excluded-list",
        required=True,
        help="path to excluded.json, the committed per-file exclusion list (issue #676)",
    )
    parser.add_argument("--readme", required=True, help="path to the README carrying the generated block")
    parser.add_argument("--write", action="store_true", help="persist the regenerated table and the raised baseline")
    parser.add_argument("--summary", default=None, help="append the rendered table to this file (GITHUB_STEP_SUMMARY)")
    args = parser.parse_args(argv)

    artifacts_dir = Path(args.artifacts)
    baseline_path = Path(args.baseline)
    excluded_path = Path(args.excluded_list)
    readme_path = Path(args.readme)

    try:
        baseline = load_baseline(baseline_path)
        committed_excluded = load_excluded_list(excluded_path)
        tier_a_languages: list[str] = []
        for row in baseline:
            if row.kind != "tier-a":
                continue
            if row.language in tier_a_languages:
                raise StudyError(
                    f"{baseline_path}: two Tier A rows are both '{row.language}' — "
                    f"{excluded_path} is keyed by language, so their exclusions "
                    "would collide"
                )
            tier_a_languages.append(row.language)
        unlisted = sorted(set(tier_a_languages) - set(committed_excluded))
        if unlisted:
            raise StudyError(
                f"{excluded_path} has no entry for "
                + ", ".join(unlisted)
                + " — that row's exclusions would be diffed against nothing, so "
                "a readmitted file could not be seen (issue #676). A row that "
                'excludes nothing is declared as an empty object ("{}"); an '
                "absent key says nothing at all."
            )
        orphaned = sorted(set(committed_excluded) - set(tier_a_languages))
        if orphaned:
            raise StudyError(
                f"{excluded_path} names "
                + ", ".join(orphaned)
                + f", which no Tier A row in {baseline_path} claims — a stale "
                "entry guards nothing. Remove it in the same commit that removed "
                "the row."
            )
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
        committed = committed_excluded.get(row.language, {}) if row.kind == "tier-a" else {}
        row_breaches, raised = check_row(row, measured, committed)
        breaches += row_breaches
        if raised is not None:
            detail = (
                f"{row.label}: clean {row.clean}/{row.scored} -> "
                f"{raised.clean}/{raised.scored}"
            )
            if row.kind == "tier-a":
                assert row.funnel is not None and raised.funnel is not None
                moved = [
                    f"{header} {before}/{row.scored} -> {after}/{raised.scored}"
                    for header, before, after in zip(
                        _STAGE_HEADERS, row.funnel, raised.funnel
                    )
                    if before != after
                ]
                if moved:
                    detail += ", funnel " + "; ".join(moved)
            raises.append(detail)
        final_rows.append(raised if raised is not None else row)
        status = "BELOW" if row_breaches else ("up" if raised is not None else "at floor")
        print(
            f"  {row.label:<32} clean {measured.clean}/{measured.scored} "
            f"({pct(measured.clean, measured.scored)}%)  "
            f"floor {row.clean}/{row.scored} ({pct(row.clean, row.scored)}%)  {status}"
        )
        # The exclusion list's own movement, per row, printed whether or not the
        # regenerated file is later committed: a path leaving or entering the
        # denominator is the provenance a reader needs in the job log, not only
        # in a diff.
        if row.kind == "tier-a" and not row_breaches:
            added, gone = excluded_diff(committed, measured.excluded_files or {})
            if added:
                print(f"    newly excluded: {_name_files(added)}")
            if gone:
                print(
                    f"    no longer excluded, and not scored either: {_name_files(gone)}"
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

    excluded_text, excluded_crlf = read_preserving_newlines(excluded_path)
    new_excluded = dump_excluded_list(measured_rows, json.loads(excluded_text))
    excluded_stale = new_excluded != excluded_text

    if args.write:
        if readme_stale:
            write_preserving_newlines(readme_path, new_readme, readme_crlf)
        if baseline_stale:
            write_preserving_newlines(baseline_path, new_baseline, baseline_crlf)
        if excluded_stale:
            write_preserving_newlines(excluded_path, new_excluded, excluded_crlf)
        print(
            f"Wrote: README {'updated' if readme_stale else 'already current'}, "
            f"baseline {'updated' if baseline_stale else 'already current'}, "
            f"excluded list {'updated' if excluded_stale else 'already current'}"
        )
    else:
        print(
            f"Check only: README {'is stale' if readme_stale else 'is current'}, "
            f"baseline {'is stale' if baseline_stale else 'is current'}, "
            f"excluded list {'is stale' if excluded_stale else 'is current'} "
            "(pass --write to regenerate)"
        )

    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as handle:
            handle.write("## Third-party coverage study\n\n")
            handle.write(block + "\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
