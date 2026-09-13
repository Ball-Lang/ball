#!/usr/bin/env python3
"""Self-test for the coverage-table renderer and its ratchet floors (issue #493).

WHAT GAP THIS CLOSES. Slices 1-3 of #493 built six Tier A harnesses and two
Tier B harnesses, and every one of them prints an honest number. Nothing
consumed those numbers: `coverage-study.yml` uploaded a JSON artifact per job
and exited, so a real regression on third-party code — the Rust encoder going
from 0/110 to 0/40 scored files, the Dart round trip falling from 65/106 to
50/106 — was visible only to a human who downloaded seven artifacts and diffed
them by hand against a number written in a GitHub comment. "The numbers exist
but nothing floors them and nothing publishes them" is the bug this file's
subject (`tools/coverage-study/coverage_table.py`) fixes.

WHAT THIS PROVES. That the floor is a floor, and that the renderer is a pure
function of the artifacts:

1. a run BELOW the checked-in baseline fails (exit 1) and names the language,
   the tier and BOTH numbers — a floor whose message does not say what dropped
   gets muted, not investigated;
2. a run exactly AT the baseline passes and raises nothing;
3. a run ABOVE the baseline passes AND emits the raised baseline (a ratchet
   that never ratchets up is a floor set once and rotting);
4. a MISSING artifact fails loud — the single most expensive failure mode
   available here, because an absent file that reads as "0 scored, 0 clean"
   would satisfy every percentage floor forever (the project has already been
   burned by exactly this: a gate whose parse silently disabled it, and a
   `Results:` line that could not tell "all passed" from "nothing ran");
5. a tally that is not a bare integer fails, on both sides — a baseline count
   written as a string, and an artifact verdict whose `scored` is a string
   rather than a bool (`"false"` is truthy, so it would inflate the
   denominator);
6. the denominator itself is floored: a run that scores fewer files than the
   baseline fails EVEN IF its percentage improved, because a shrinking corpus
   makes the percentage incomparable and usually means a checkout broke;
7. the funnel is floored too, which is what gives the five 0%-clean rows a live
   guard — `clean` cannot drop below 0, but "110 files reached stage 1" can;
8. rendering is idempotent, so the workflow's bot commit is a pure
   regeneration and a week with no change produces no commit at all;
9. the test-only exclusion count (the owner's 2026-09-14 methodology decision
   on #491) is published in the table and recorded in the baseline, and a Tier A
   artifact that carries NO exclusion count fails loud rather than reading as
   zero — that shape is a harness whose exclusion rule vanished, and publishing
   a denominator nobody can explain is the silent-filter failure the decision
   exists to end. It is RECORDED, NOT FLOORED: a pin whose own test suite grew
   moves that count in either direction and neither is a regression.
10. the COMMITTED per-file excluded list (issue #676) is diffed, not just the
    count: a path the committed list excludes and the artifact SCORES is a
    breach that names the file, even when `scored`, `clean`, the funnel and the
    count-based #648 check all pass — which is exactly the partial-drop shape
    (3 of 34) no arithmetic can distinguish from "the test suite shrank by 3
    while the library grew by 3". Its negative controls are here too: an
    unchanged list with the same totals is no breach, a newly excluded path is
    reported and regenerated rather than failed, and a legitimate change to a
    pin's test population passes once the committed list records it in the same
    commit.

WHAT THIS DOES NOT PROVE. Nothing here is a regression test for any encoder or
compiler defect. It validates the INSTRUMENT: the harnesses' own self-tests
(`rq1_study_self_test.dart` and its five ports, `rq1_tierb_self_test.dart`)
prove the numbers are honestly measured; this file proves they are honestly
floored and published.

Run from the repo root:
    python3 tools/coverage-study/test/coverage_table_self_test.py
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
SCRIPT = REPO_ROOT / "tools" / "coverage-study" / "coverage_table.py"

_passed = 0
_failed = 0


def check(name: str, ok: bool, detail: str = "") -> None:
    global _passed, _failed
    if ok:
        _passed += 1
        print(f"PASS  {name}")
    else:
        _failed += 1
        print(f"FAIL  {name}")
        if detail:
            for line in detail.splitlines():
                print(f"      {line}")


def tier_a_artifact(
    *,
    clean: int,
    drift: int,
    encode_errors: int,
    compile_errors: int = 0,
    reencode_errors: int = 0,
    skipped: int = 0,
    excluded: int = 0,
    excluded_entries: list[tuple[str, str]] | None = None,
    scored_entries: list[tuple[str, str]] | None = None,
    omit_excluded: bool = False,
    omit_excluded_list: bool = False,
    excluded_count_override: int | None = None,
    pascal_case: bool = False,
) -> dict:
    """A synthetic Tier A report in the shape every harness writes.

    ``pascal_case`` reproduces the C# harness's System.Text.Json output, whose
    keys are ``Package``/``Scored``/``Clean``/``Reason`` while the other five
    harnesses emit camelCase. A renderer that only understood one casing would
    read the C# artifact as an empty report — i.e. as a pass.

    ``compile_errors`` and ``reencode_errors`` are the files that stop AFTER
    stage 1: a `compile-error` survived stage 1 only, and a `reencode-error`
    survived stages 1 and 2 and then failed stage 3 — which is the shape issue
    #632 had (`rust/compiler` emitted a `panic!` its own `rust/encoder`
    refused). Without them every synthetic row has an identical funnel, and a
    stage-3 floor would have nothing to fail on.

    ``excluded`` is the test-only exclusion count every Tier A harness reports
    since the owner's 2026-09-14 methodology decision on #491. ``omit_excluded``
    writes a report WITHOUT that key — the shape a harness would produce if its
    exclusion rule silently vanished, which must fail rather than render a blank
    column.

    ``excluded_entries`` and ``scored_entries`` name (package, path) pairs
    explicitly instead of generating them, which is what the issue #676 cases
    below need: a readmission is only visible as the SAME path moving from the
    excluded list into the scored set, so both halves have to be addressable by
    name. ``omit_excluded_list`` keeps the count but drops the per-file list (a
    harness that regressed to the pre-#635 shape), and
    ``excluded_count_override`` makes the count disagree with the list it is
    supposed to summarise.
    """
    files = []
    for i in range(clean):
        files.append({"package": "p", "file": f"clean{i}.x", "scored": True, "clean": True, "irStable": True, "reason": "clean"})
    for i in range(drift):
        files.append({"package": "p", "file": f"drift{i}.x", "scored": True, "clean": False, "irStable": False, "reason": "fixpoint-drift: generation 3 differed"})
    for i in range(encode_errors):
        files.append({"package": "p", "file": f"enc{i}.x", "scored": True, "clean": False, "irStable": False, "reason": "encode-error: unsupported construct"})
    for i in range(compile_errors):
        files.append({"package": "p", "file": f"cmp{i}.x", "scored": True, "clean": False, "irStable": False, "reason": "compile-error: unsupported expression"})
    for i in range(reencode_errors):
        files.append({"package": "p", "file": f"reenc{i}.x", "scored": True, "clean": False, "irStable": False, "reason": "reencode-error: unsupported macro invocation `panic!`"})
    for i in range(skipped):
        files.append({"package": "p", "file": f"skip{i}.x", "scored": False, "clean": False, "irStable": False, "reason": "skipped: no declarations"})
    for package, name in scored_entries or []:
        files.append({"package": package, "file": name, "scored": True, "clean": False, "irStable": False, "reason": "encode-error: unsupported construct"})
    if excluded_entries is None:
        dropped = [
            {"package": "p", "file": f"x_test{i}.x", "rule": "test-only convention"}
            for i in range(excluded)
        ]
    else:
        dropped = [
            {"package": package, "file": name, "rule": "test-only convention"}
            for package, name in excluded_entries
        ]
    count = len(dropped) if excluded_count_override is None else excluded_count_override
    if pascal_case:
        files = [{k[0].upper() + k[1:]: v for k, v in f.items()} for f in files]
        dropped = [{k[0].upper() + k[1:]: v for k, v in d.items()} for d in dropped]
        report = {"MissingPins": [], "Files": files}
        if not omit_excluded:
            report["ExcludedTestOnly"] = count
            if not omit_excluded_list:
                report["Excluded"] = dropped
        return report
    report = {"missingPins": [], "files": files}
    if not omit_excluded:
        report["excludedTestOnly"] = count
        if not omit_excluded_list:
            report["excluded"] = dropped
    return report


def tier_b_artifact(*, clean: int, drift: int, not_compiled: int = 0) -> dict:
    """A synthetic Tier B report — packages, each carrying its own files."""
    files = []
    for i in range(clean):
        files.append({"package": "p", "file": f"clean{i}.dart", "scored": True, "clean": True, "reason": "clean"})
    for i in range(drift):
        files.append({"package": "p", "file": f"drift{i}.dart", "scored": True, "clean": False, "reason": "behavioral-drift: 12 -> 11 passing"})
    for i in range(not_compiled):
        files.append({"package": "p", "file": f"nc{i}.dart", "scored": False, "clean": False, "reason": "not-compiled: never reached stage 2"})
    return {"missingPins": [], "packages": [{"package": "p", "status": "scored", "files": files}]}


def baseline_row(**over) -> dict:
    row = {
        "language": "Dart",
        "tier": "Tier A",
        "kind": "tier-a",
        "artifact": "coverage-study-tier-a-dart/tier_a.json",
        "scored": 4,
        "clean": 3,
        # The whole funnel is floored, stage by stage (issue #632), so a
        # fixture that named only stage 1 would be rejected on its shape
        # before it could assert anything.
        "encoded": 4,
        "compiledBack": 4,
        "reencoded": 4,
        "declarationsKept": 4,
        # RECORDED, NOT FLOORED. The test-only exclusion count is context for
        # the denominator, not a quality measure: a pin list that grows its test
        # suite legitimately moves it in either direction. Keeping it in the
        # baseline is what makes a silent change to an exclusion rule show up in
        # the committed diff (the owner's 2026-09-14 decision on #491).
        "excluded": 0,
    }
    row.update(over)
    # A Tier B row has no funnel, so it carries none of the four stage keys.
    # Leaving the defaults in would make both Tier B cases below fail on the
    # row shape instead of on the thing they claim to assert — a drop that
    # "passes" because the fixture was rejected first is a false green.
    if row["kind"] == "tier-b":
        for key in ("encoded", "compiledBack", "reencoded", "declarationsKept"):
            if key not in over:
                row.pop(key)
        if "excluded" not in over:
            row.pop("excluded")
    return row


README_TEMPLATE = (
    "# Ball\n\nsome prose\n\n"
    "<!-- BEGIN GENERATED: coverage-study (tools/coverage-study/coverage_table.py) -->\n"
    "<!-- END GENERATED: coverage-study -->\n\n"
    "more prose\n"
)


class Case:
    """One hermetic scratch tree: artifacts, a baseline and a README."""

    def __init__(self, tmp: Path, name: str) -> None:
        self.dir = tmp / name
        self.artifacts = self.dir / "artifacts"
        self.artifacts.mkdir(parents=True)
        self.baseline = self.dir / "baseline.json"
        self.excluded_list = self.dir / "excluded.json"
        self.readme = self.dir / "README.md"
        self.readme.write_text(README_TEMPLATE, encoding="utf-8")

    def put_artifact(self, rel: str, payload: dict) -> None:
        path = self.artifacts / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload, indent=2), encoding="utf-8")

    def put_baseline(self, rows: list[dict]) -> None:
        self.baseline.write_text(
            json.dumps({"rows": rows}, indent=2) + "\n", encoding="utf-8"
        )

    def put_excluded(self, languages: dict[str, dict[str, list[str]]]) -> None:
        """The committed per-file excluded list this case is checked against."""
        self.excluded_list.write_text(
            json.dumps({"languages": languages}, indent=2) + "\n", encoding="utf-8"
        )

    def run(self, *extra: str) -> subprocess.CompletedProcess:
        # Every Tier A row must carry a key in the committed list — a row with
        # no entry would be guarded by nothing. Cases that do not care about the
        # list get an empty entry per Tier A language, so they assert what they
        # claim to assert rather than tripping over the list's own shape check.
        if not self.excluded_list.is_file():
            rows = json.loads(self.baseline.read_text(encoding="utf-8"))["rows"]
            self.put_excluded(
                {row["language"]: {} for row in rows if row.get("kind") == "tier-a"}
            )
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--artifacts",
                str(self.artifacts),
                "--baseline",
                str(self.baseline),
                "--excluded-list",
                str(self.excluded_list),
                "--readme",
                str(self.readme),
                *extra,
            ],
            capture_output=True,
            text=True,
        )


def main() -> int:
    if not SCRIPT.is_file():
        print(f"FAIL  the renderer/floor script exists at {SCRIPT}")
        print("Results: 0 passed, 1 failed, 1 total")
        return 1

    with tempfile.TemporaryDirectory() as raw:
        tmp = Path(raw)

        # ── 1. exactly at the baseline ──────────────────────────────────────
        at = Case(tmp, "at")
        at.put_artifact("coverage-study-tier-a-dart/tier_a.json", tier_a_artifact(clean=3, drift=1, encode_errors=0, skipped=2))
        at.put_baseline([baseline_row()])
        got = at.run()
        check(
            "a run exactly at the baseline passes",
            got.returncode == 0,
            f"exit={got.returncode}\n{got.stdout}\n{got.stderr}",
        )
        check(
            "a run at the baseline raises nothing",
            "raised" not in got.stdout.lower(),
            got.stdout,
        )

        # ── 2. below the baseline ───────────────────────────────────────────
        below = Case(tmp, "below")
        below.put_artifact("coverage-study-tier-a-dart/tier_a.json", tier_a_artifact(clean=2, drift=2, encode_errors=0))
        below.put_baseline([baseline_row()])
        got = below.run()
        message = got.stdout + got.stderr
        check(
            "a run below the baseline fails",
            got.returncode == 1,
            f"exit={got.returncode}\n{message}",
        )
        check(
            "the breach names the language and the tier",
            "Dart" in message and "Tier A" in message,
            message,
        )
        check(
            "the breach names BOTH the measured and the baseline number",
            "2/4" in message and "3/4" in message,
            message,
        )
        check(
            "a breach never rewrites the baseline it just failed on",
            json.loads(below.baseline.read_text(encoding="utf-8"))["rows"][0]["clean"] == 3,
            below.baseline.read_text(encoding="utf-8"),
        )

        # ── 3. above the baseline ───────────────────────────────────────────
        above = Case(tmp, "above")
        above.put_artifact("coverage-study-tier-a-dart/tier_a.json", tier_a_artifact(clean=4, drift=0, encode_errors=0))
        above.put_baseline([baseline_row()])
        got = above.run()
        message = got.stdout + got.stderr
        check(
            "a run above the baseline passes",
            got.returncode == 0,
            f"exit={got.returncode}\n{message}",
        )
        check(
            "a run above the baseline emits the raised baseline",
            "raise" in message.lower() and "4/4" in message,
            message,
        )
        check(
            "--write is required before the raised baseline is persisted",
            json.loads(above.baseline.read_text(encoding="utf-8"))["rows"][0]["clean"] == 3,
            above.baseline.read_text(encoding="utf-8"),
        )
        got = above.run("--write")
        raised = json.loads(above.baseline.read_text(encoding="utf-8"))["rows"][0]
        check(
            "--write persists the raised baseline",
            got.returncode == 0 and raised["clean"] == 4 and raised["scored"] == 4,
            f"exit={got.returncode} row={raised}",
        )

        # ── 4. a missing artifact ───────────────────────────────────────────
        missing = Case(tmp, "missing")
        missing.put_baseline([baseline_row()])
        got = missing.run()
        message = got.stdout + got.stderr
        check(
            "a missing artifact fails loud, never as a 0/0 pass",
            got.returncode == 1,
            f"exit={got.returncode}\n{message}",
        )
        check(
            "the missing-artifact error names the file it could not read",
            "coverage-study-tier-a-dart/tier_a.json" in message.replace("\\", "/"),
            message,
        )

        # ── 5. an artifact that scored nothing ──────────────────────────────
        empty = Case(tmp, "empty")
        empty.put_artifact("coverage-study-tier-a-dart/tier_a.json", tier_a_artifact(clean=0, drift=0, encode_errors=0, skipped=5))
        empty.put_baseline([baseline_row()])
        got = empty.run()
        check(
            "an artifact that scored zero files fails (the positive floor)",
            got.returncode == 1,
            f"exit={got.returncode}\n{got.stdout}\n{got.stderr}",
        )

        # ── 6. tallies that are not bare integers ───────────────────────────
        strcount = Case(tmp, "strcount")
        strcount.put_artifact("coverage-study-tier-a-dart/tier_a.json", tier_a_artifact(clean=3, drift=1, encode_errors=0))
        strcount.put_baseline([baseline_row(clean="3")])
        got = strcount.run()
        check(
            "a baseline count that is not a bare integer fails",
            got.returncode == 1,
            f"exit={got.returncode}\n{got.stdout}\n{got.stderr}",
        )

        strverdict = Case(tmp, "strverdict")
        payload = tier_a_artifact(clean=3, drift=1, encode_errors=0)
        payload["files"][0]["scored"] = "true"
        strverdict.put_artifact("coverage-study-tier-a-dart/tier_a.json", payload)
        strverdict.put_baseline([baseline_row()])
        got = strverdict.run()
        check(
            "an artifact verdict whose scored/clean is not a bool fails",
            got.returncode == 1,
            f"exit={got.returncode}\n{got.stdout}\n{got.stderr}",
        )

        # ── 7. a shrinking denominator, even with a better ratio ────────────
        shrunk = Case(tmp, "shrunk")
        shrunk.put_artifact("coverage-study-tier-a-dart/tier_a.json", tier_a_artifact(clean=2, drift=0, encode_errors=0))
        shrunk.put_baseline([baseline_row()])
        got = shrunk.run()
        message = got.stdout + got.stderr
        check(
            "a smaller scored corpus fails even though 2/2 beats 3/4",
            got.returncode == 1,
            f"exit={got.returncode}\n{message}",
        )
        check(
            "the corpus-shrink error names both denominators",
            "2" in message and "4" in message,
            message,
        )

        # ── 8. the funnel is floored (the live guard for the 0% rows) ───────
        funnel = Case(tmp, "funnel")
        funnel.put_artifact("coverage-study-tier-a-rust/tier_a.json", tier_a_artifact(clean=0, drift=0, encode_errors=4))
        funnel.put_baseline([
            baseline_row(
                language="Rust",
                artifact="coverage-study-tier-a-rust/tier_a.json",
                scored=4,
                clean=0,
                encoded=2,
                compiledBack=2,
                reencoded=2,
                declarationsKept=2,
            )
        ])
        got = funnel.run()
        message = got.stdout + got.stderr
        check(
            "a row at 0% clean still fails when its funnel regresses",
            got.returncode == 1,
            f"exit={got.returncode}\n{message}",
        )
        check(
            "the funnel breach names the stage and both numbers",
            "encoded" in message and "0/4" in message and "2/4" in message,
            message,
        )

        # ── 9. an artifact with no baseline row is unfloored ────────────────
        unfloored = Case(tmp, "unfloored")
        unfloored.put_artifact("coverage-study-tier-a-dart/tier_a.json", tier_a_artifact(clean=3, drift=1, encode_errors=0))
        unfloored.put_artifact("coverage-study-tier-a-go/tier_a.json", tier_a_artifact(clean=0, drift=0, encode_errors=4))
        unfloored.put_baseline([baseline_row()])
        got = unfloored.run()
        message = got.stdout + got.stderr
        check(
            "an artifact with no baseline row fails rather than publishing unfloored",
            got.returncode == 1,
            f"exit={got.returncode}\n{message}",
        )
        check(
            "the unfloored-row error names the artifact",
            "coverage-study-tier-a-go" in message,
            message,
        )

        # ── 10. C# PascalCase artifacts are read, not silently empty ────────
        pascal = Case(tmp, "pascal")
        pascal.put_artifact("coverage-study-tier-a-csharp/tier_a.json", tier_a_artifact(clean=3, drift=1, encode_errors=0, pascal_case=True))
        pascal.put_baseline([
            baseline_row(language="C#", artifact="coverage-study-tier-a-csharp/tier_a.json")
        ])
        got = pascal.run()
        check(
            "the C# harness's PascalCase JSON is read like every other artifact",
            got.returncode == 0,
            f"exit={got.returncode}\n{got.stdout}\n{got.stderr}",
        )

        # ── 11. an unrecognised taxonomy tag ────────────────────────────────
        unknown = Case(tmp, "unknown")
        payload = tier_a_artifact(clean=3, drift=1, encode_errors=0)
        payload["files"][3]["reason"] = "brand-new-tag: something else happened"
        unknown.put_artifact("coverage-study-tier-a-dart/tier_a.json", payload)
        unknown.put_baseline([baseline_row()])
        got = unknown.run()
        check(
            "an unrecognised taxonomy tag fails instead of defaulting into a funnel row",
            got.returncode == 1,
            f"exit={got.returncode}\n{got.stdout}\n{got.stderr}",
        )

        # ── 12. Tier B rows floor on clean and carry no funnel ──────────────
        tierb = Case(tmp, "tierb")
        tierb.put_artifact("coverage-study-tier-b-dart/tier_b.json", tier_b_artifact(clean=3, drift=1, not_compiled=2))
        tierb.put_baseline([
            baseline_row(
                tier="Tier B (per-file)",
                kind="tier-b",
                artifact="coverage-study-tier-b-dart/tier_b.json",
                scored=4,
                clean=3,
            )
        ])
        got = tierb.run("--write")
        check(
            "a Tier B row is scored from its nested packages",
            got.returncode == 0,
            f"exit={got.returncode}\n{got.stdout}\n{got.stderr}",
        )
        rendered = tierb.readme.read_text(encoding="utf-8")
        check(
            "the Tier B row is published with no funnel cells",
            "Tier B (per-file)" in rendered and "3 (75%)" in rendered,
            rendered,
        )

        tierb_below = Case(tmp, "tierb_below")
        tierb_below.put_artifact("coverage-study-tier-b-dart/tier_b.json", tier_b_artifact(clean=2, drift=2))
        tierb_below.put_baseline([
            baseline_row(
                tier="Tier B (per-file)",
                kind="tier-b",
                artifact="coverage-study-tier-b-dart/tier_b.json",
                scored=4,
                clean=3,
            )
        ])
        got = tierb_below.run()
        check(
            "a Tier B drop fails like a Tier A drop",
            got.returncode == 1,
            f"exit={got.returncode}\n{got.stdout}\n{got.stderr}",
        )

        # ── 13. the render is a pure, idempotent regeneration ───────────────
        idem = Case(tmp, "idem")
        idem.put_artifact("coverage-study-tier-a-dart/tier_a.json", tier_a_artifact(clean=3, drift=1, encode_errors=0))
        idem.put_baseline([baseline_row()])
        idem.run("--write")
        once_readme = idem.readme.read_text(encoding="utf-8")
        once_baseline = idem.baseline.read_text(encoding="utf-8")
        idem.run("--write")
        check(
            "regenerating twice leaves the README byte-identical",
            idem.readme.read_text(encoding="utf-8") == once_readme,
            "the weekly bot commit would churn on every run",
        )
        check(
            "regenerating twice leaves the baseline byte-identical",
            idem.baseline.read_text(encoding="utf-8") == once_baseline,
            "the weekly bot commit would churn on every run",
        )
        check(
            "the generated block stays between its markers",
            once_readme.startswith("# Ball\n\nsome prose\n")
            and once_readme.endswith("more prose\n")
            and once_readme.count("BEGIN GENERATED: coverage-study") == 1,
            once_readme,
        )
        check(
            "the published row carries the measured numbers",
            "| 4 | 3 (75%) |" in once_readme,
            once_readme,
        )

        # ── 13b. a CRLF checkout is not reflowed ────────────────────────────
        # A Windows checkout (or core.autocrlf=true) holds these files as CRLF.
        # Rewriting them as LF would show up as a whole-file diff that has
        # nothing to do with the numbers, and would make the bot commit
        # anything but a pure regeneration.
        crlf = Case(tmp, "crlf")
        crlf.readme.write_bytes(README_TEMPLATE.replace("\n", "\r\n").encode("utf-8"))
        crlf.put_artifact("coverage-study-tier-a-dart/tier_a.json", tier_a_artifact(clean=3, drift=1, encode_errors=0))
        crlf.put_baseline([baseline_row()])
        crlf.run("--write")
        written = crlf.readme.read_bytes()
        check(
            "a CRLF README stays CRLF, with no stray lone LFs",
            b"\n" in written and written.replace(b"\r\n", b"") .count(b"\n") == 0,
            repr(written[:120]),
        )

        # ── 14. a README with no markers ────────────────────────────────────
        nomarkers = Case(tmp, "nomarkers")
        nomarkers.readme.write_text("# Ball\n\nno markers here\n", encoding="utf-8")
        nomarkers.put_artifact("coverage-study-tier-a-dart/tier_a.json", tier_a_artifact(clean=3, drift=1, encode_errors=0))
        nomarkers.put_baseline([baseline_row()])
        got = nomarkers.run("--write")
        check(
            "a README missing the generated-block markers fails loud",
            got.returncode == 1,
            f"exit={got.returncode}\n{got.stdout}\n{got.stderr}",
        )

        # ── 14b. a baseline that floors nothing ─────────────────────────────
        # An empty rows list would check nothing, find no breach and exit 0 —
        # the same fake-green shape as an absent gate. It is a positive floor
        # on the floor itself.
        norows = Case(tmp, "norows")
        norows.put_artifact("coverage-study-tier-a-dart/tier_a.json", tier_a_artifact(clean=3, drift=1, encode_errors=0))
        norows.put_baseline([])
        got = norows.run()
        check(
            "a baseline declaring no rows fails instead of passing vacuously",
            got.returncode == 1,
            f"exit={got.returncode}\n{got.stdout}\n{got.stderr}",
        )

        # ── 14c. two rows claiming one artifact ─────────────────────────────
        # The second row would silently shadow the first, so one of the two
        # floors would stop being enforced without anything saying so.
        dupe = Case(tmp, "dupe")
        dupe.put_artifact("coverage-study-tier-a-dart/tier_a.json", tier_a_artifact(clean=3, drift=1, encode_errors=0))
        dupe.put_baseline([baseline_row(), baseline_row(language="Dart (again)")])
        got = dupe.run()
        check(
            "two baseline rows claiming the same artifact fail",
            got.returncode == 1,
            f"exit={got.returncode}\n{got.stdout}\n{got.stderr}",
        )

        # ── 14d. the test-only exclusion count is published and recorded ────
        # The owner's 2026-09-14 methodology decision on #491 takes a package's
        # own tests out of the Tier A denominator. That makes the denominator a
        # function of an exclusion RULE, so the count must be visible in the
        # published table and recorded in the baseline — otherwise a rule that
        # silently widened would move every ratio with nothing in the diff
        # saying why. It is RECORDED, NOT FLOORED: a legitimately larger test
        # suite in a pin moves it, which is not a regression.
        excl = Case(tmp, "excluded")
        excl.put_artifact(
            "coverage-study-tier-a-dart/tier_a.json",
            tier_a_artifact(clean=3, drift=1, encode_errors=0, excluded=7),
        )
        excl.put_baseline([baseline_row()])
        got = excl.run("--write")
        check(
            "a run whose exclusion count moved still passes — excluded is recorded, not floored",
            got.returncode == 0,
            f"exit={got.returncode}\n{got.stdout}\n{got.stderr}",
        )
        check(
            "the published table carries the excluded column and the measured count",
            "excluded (test-only)" in excl.readme.read_text(encoding="utf-8")
            and "| 7 |" in excl.readme.read_text(encoding="utf-8"),
            excl.readme.read_text(encoding="utf-8"),
        )
        check(
            "the recorded baseline picks up the new exclusion count",
            json.loads(excl.baseline.read_text(encoding="utf-8"))["rows"][0]["excluded"] == 7,
            excl.baseline.read_text(encoding="utf-8"),
        )

        # ── 14e. a Tier A report with no exclusion count fails loud ─────────
        # This is the shape a harness produces when its exclusion rule vanishes.
        # Reading it as "excluded 0" would publish a denominator nobody could
        # explain, which is exactly the silent-filter failure the decision was
        # written to end.
        noexcl = Case(tmp, "noexcl")
        noexcl.put_artifact(
            "coverage-study-tier-a-dart/tier_a.json",
            tier_a_artifact(clean=3, drift=1, encode_errors=0, omit_excluded=True),
        )
        noexcl.put_baseline([baseline_row()])
        got = noexcl.run()
        message = got.stdout + got.stderr
        check(
            "a Tier A artifact with no exclusion count fails instead of reading as zero",
            got.returncode == 1,
            f"exit={got.returncode}\n{message}",
        )
        check(
            "that failure names the missing key",
            "excludedTestOnly" in message,
            message,
        )

        # ── 14f. an exclusion rule that stopped firing is a BREACH ──────────
        # The #648 shape, and the one every other floor is blind to: the whole
        # excluded population re-enters the denominator (`excluded` 7 -> 0,
        # `scored` 4 -> 11) and nothing else gets worse. Every ratio here
        # IMPROVES, so `scored`, the clean ratio and the funnel ratio all pass —
        # this run would otherwise be a pure RAISE, silently re-flooring the row
        # on a population nobody chose. The measured cause of that in Rust is a
        # crate root that stopped resolving, which turns the `#[cfg(test)]`
        # reachability half off and leaves the 34 excluded files scored.
        vanished = Case(tmp, "vanished")
        vanished.put_artifact(
            "coverage-study-tier-a-dart/tier_a.json",
            tier_a_artifact(clean=10, drift=1, encode_errors=0, excluded=0),
        )
        vanished.put_baseline([baseline_row(excluded=7)])
        before = vanished.baseline.read_text(encoding="utf-8")
        got = vanished.run("--write")
        message = got.stdout + got.stderr
        check(
            "an excluded->0 jump that lands in `scored` is a breach, not a raise",
            got.returncode == 1,
            f"exit={got.returncode}\n{message}",
        )
        check(
            "that breach names the exclusion rule as the cause, not the ratio",
            "exclusion" in message and "7 -> 0" in message and "4 -> 11" in message,
            message,
        )
        check(
            "the baseline is NOT re-floored on that breach",
            vanished.baseline.read_text(encoding="utf-8") == before,
            vanished.baseline.read_text(encoding="utf-8"),
        )

        # ── 14g. …and the same drop with a STEADY denominator is not ────────
        # The negative control that keeps 14f from being a blanket "excluded may
        # never fall": a pin that legitimately dropped its own tests moves the
        # count to 0 with nothing re-entering the denominator. `scored` is
        # unchanged, so nothing was readmitted, so it is a raise like any other.
        dropped = Case(tmp, "dropped")
        dropped.put_artifact(
            "coverage-study-tier-a-dart/tier_a.json",
            tier_a_artifact(clean=3, drift=1, encode_errors=0, excluded=0),
        )
        dropped.put_baseline([baseline_row(excluded=7)])
        got = dropped.run("--write")
        check(
            "excluded -> 0 with an unchanged denominator stays a raise",
            got.returncode == 0,
            f"exit={got.returncode}\n{got.stdout}\n{got.stderr}",
        )
        check(
            "and that raise records the new exclusion count",
            json.loads(dropped.baseline.read_text(encoding="utf-8"))["rows"][0]["excluded"] == 0,
            dropped.baseline.read_text(encoding="utf-8"),
        )

        # ── 15. check mode reports a stale README without rewriting it ──────
        stale = Case(tmp, "stale")
        stale.put_artifact("coverage-study-tier-a-dart/tier_a.json", tier_a_artifact(clean=3, drift=1, encode_errors=0))
        stale.put_baseline([baseline_row()])
        got = stale.run()
        check(
            "check mode leaves the README untouched",
            stale.readme.read_text(encoding="utf-8") == README_TEMPLATE,
            stale.readme.read_text(encoding="utf-8"),
        )
        check(
            "check mode still exits 0 when only the published table is stale",
            got.returncode == 0,
            f"exit={got.returncode}\n{got.stdout}\n{got.stderr}",
        )

        # ── 16. the committed per-file excluded list (issue #676) ───────────
        # 14f catches a TOTAL exclusion collapse by arithmetic. A PARTIAL one
        # cannot be caught that way: "3 files stopped being excluded" and "the
        # pin's test suite shrank by 3 while its library grew by 3" produce the
        # SAME counts, so the fixtures below hold every total fixed — scored,
        # clean and the funnel are all identical to the baseline — and differ
        # only in WHICH paths are in the denominator. The list is the only
        # instrument that can tell them apart, and it names the files.
        #
        # Shaped after the real Rust row: 34 `bitflags` files excluded by the
        # `#[cfg(test)]` reachability half of the rule.
        bitflags = ["src/tests.rs"] + [f"src/tests/a{i:02d}.rs" for i in range(33)]
        readmitted = bitflags[:3]
        kept = [path for path in bitflags if path not in readmitted]
        rust_row = baseline_row(
            language="Rust",
            artifact="coverage-study-tier-a-rust/tier_a.json",
            scored=10,
            clean=2,
            encoded=4,
            compiledBack=4,
            reencoded=4,
            declarationsKept=4,
            excluded=34,
        )

        # ── 16a. three of thirty-four readmitted, every total unchanged ─────
        partial = Case(tmp, "partial")
        partial.put_artifact(
            "coverage-study-tier-a-rust/tier_a.json",
            tier_a_artifact(
                clean=2,
                drift=2,
                encode_errors=3,
                excluded_entries=[("bitflags", path) for path in kept],
                scored_entries=[("bitflags", path) for path in readmitted],
            ),
        )
        partial.put_baseline([rust_row])
        partial.put_excluded({"Rust": {"bitflags": bitflags}})
        before_excluded = partial.excluded_list.read_text(encoding="utf-8")
        before_baseline = partial.baseline.read_text(encoding="utf-8")
        got = partial.run("--write")
        message = got.stdout + got.stderr
        check(
            "a path the committed list excludes but the artifact SCORES is a breach",
            got.returncode == 1,
            f"exit={got.returncode}\n{message}",
        )
        check(
            "that breach names every readmitted file, not just the count",
            all(path in message for path in readmitted),
            message,
        )
        check(
            "that breach names the row it belongs to",
            "Rust" in message,
            message,
        )
        check(
            "the committed excluded list is NOT rewritten on that breach",
            partial.excluded_list.read_text(encoding="utf-8") == before_excluded,
            partial.excluded_list.read_text(encoding="utf-8"),
        )
        check(
            "the baseline is NOT re-floored on that breach either",
            partial.baseline.read_text(encoding="utf-8") == before_baseline,
            partial.baseline.read_text(encoding="utf-8"),
        )

        # ── 16b. the negative control: the same totals, the list unchanged ──
        # Without this, 16a would be satisfied by a check that fails any run
        # whose numbers match these — the list has to be what decides.
        steady = Case(tmp, "steady")
        steady.put_artifact(
            "coverage-study-tier-a-rust/tier_a.json",
            tier_a_artifact(
                clean=2,
                drift=2,
                encode_errors=6,
                excluded_entries=[("bitflags", path) for path in bitflags],
            ),
        )
        steady.put_baseline([rust_row])
        steady.put_excluded({"Rust": {"bitflags": bitflags}})
        got = steady.run("--write")
        message = got.stdout + got.stderr
        check(
            "an unchanged excluded list with the same totals is no breach",
            got.returncode == 0,
            f"exit={got.returncode}\n{message}",
        )
        check(
            "and it is reported as zero breaches, not as an unchecked row",
            "Rows checked: 1, breaches: 0" in got.stdout,
            got.stdout,
        )

        # ── 16c. a legitimate test-population change, declared in the PR ────
        # The documented workflow: a pin really did drop those three test files
        # from its own suite, so the committed list is updated in the SAME
        # commit. The identical artifact that breached in 16a now passes,
        # because the intent is recorded where a reviewer sees it.
        declared = Case(tmp, "declared")
        declared.put_artifact(
            "coverage-study-tier-a-rust/tier_a.json",
            tier_a_artifact(
                clean=2,
                drift=2,
                encode_errors=3,
                excluded_entries=[("bitflags", path) for path in kept],
                scored_entries=[("bitflags", path) for path in readmitted],
            ),
        )
        declared.put_baseline([rust_row])
        declared.put_excluded({"Rust": {"bitflags": kept}})
        got = declared.run("--write")
        message = got.stdout + got.stderr
        check(
            "the same artifact passes once the committed list records the change",
            got.returncode == 0,
            f"exit={got.returncode}\n{message}",
        )

        # ── 16d. a newly excluded path is reported and regenerated ──────────
        # The other direction is not a breach — a pin that ADDED a test file
        # takes it out of the denominator, which is the rule working. It is
        # still reported and committed, the same way `baseline.json` is, so the
        # movement lands in a reviewable diff.
        grew = Case(tmp, "grew")
        grew.put_artifact(
            "coverage-study-tier-a-rust/tier_a.json",
            tier_a_artifact(
                clean=2,
                drift=2,
                encode_errors=6,
                excluded_entries=[
                    ("bitflags", path) for path in bitflags + ["src/tests/new.rs"]
                ],
            ),
        )
        grew.put_baseline([rust_row])
        grew.put_excluded({"Rust": {"bitflags": bitflags}})
        got = grew.run("--write")
        message = got.stdout + got.stderr
        check(
            "a newly excluded path passes",
            got.returncode == 0,
            f"exit={got.returncode}\n{message}",
        )
        check(
            "a newly excluded path is reported by name",
            "src/tests/new.rs" in message,
            message,
        )
        check(
            "--write regenerates the committed list, sorted",
            json.loads(grew.excluded_list.read_text(encoding="utf-8"))["languages"]["Rust"]["bitflags"]
            == sorted(bitflags + ["src/tests/new.rs"]),
            grew.excluded_list.read_text(encoding="utf-8"),
        )

        # ── 16e. a count with no list behind it fails loud ──────────────────
        # A harness that reports `excludedTestOnly: 34` and no per-file list is
        # back to the state this whole check exists to leave: a number nothing
        # can diff. Reading that as "nothing was excluded" would disarm 16a
        # silently, which is the failure mode this project keeps getting bitten
        # by, so it is an error rather than a default.
        listless = Case(tmp, "listless")
        listless.put_artifact(
            "coverage-study-tier-a-rust/tier_a.json",
            tier_a_artifact(
                clean=2,
                drift=2,
                encode_errors=6,
                excluded_entries=[("bitflags", path) for path in bitflags],
                omit_excluded_list=True,
            ),
        )
        listless.put_baseline([rust_row])
        listless.put_excluded({"Rust": {"bitflags": bitflags}})
        got = listless.run()
        message = got.stdout + got.stderr
        check(
            "a Tier A artifact with a count but no per-file list fails loud",
            got.returncode == 1,
            f"exit={got.returncode}\n{message}",
        )
        check(
            "that failure names the missing list",
            "excluded" in message,
            message,
        )

        # ── 16f. the count and the list must agree ──────────────────────────
        # They are two views of one population written by one harness; a
        # disagreement means one of them is stale, and neither can be trusted to
        # stand for the other.
        mismatch = Case(tmp, "mismatch")
        mismatch.put_artifact(
            "coverage-study-tier-a-rust/tier_a.json",
            tier_a_artifact(
                clean=2,
                drift=2,
                encode_errors=6,
                excluded_entries=[("bitflags", path) for path in bitflags],
                excluded_count_override=30,
            ),
        )
        mismatch.put_baseline([rust_row])
        mismatch.put_excluded({"Rust": {"bitflags": bitflags}})
        got = mismatch.run()
        message = got.stdout + got.stderr
        check(
            "a count that disagrees with its own per-file list fails loud",
            got.returncode == 1,
            f"exit={got.returncode}\n{message}",
        )
        check(
            "that failure names both numbers",
            "30" in message and "34" in message,
            message,
        )

        # ── 16g. a Tier A row absent from the committed list fails loud ─────
        # An entry that quietly disappears would leave that row's exclusions
        # diffed against nothing — 16a's check would pass vacuously for it. An
        # empty object is how a row with no exclusions is declared; an ABSENT
        # key is not a way to say anything.
        unlisted = Case(tmp, "unlisted")
        unlisted.put_artifact(
            "coverage-study-tier-a-rust/tier_a.json",
            tier_a_artifact(
                clean=2,
                drift=2,
                encode_errors=6,
                excluded_entries=[("bitflags", path) for path in bitflags],
            ),
        )
        unlisted.put_baseline([rust_row])
        unlisted.put_excluded({})
        got = unlisted.run()
        message = got.stdout + got.stderr
        check(
            "a Tier A row with no entry in the committed excluded list fails loud",
            got.returncode == 1,
            f"exit={got.returncode}\n{message}",
        )
        check(
            "that failure names the row whose entry is missing",
            "Rust" in message,
            message,
        )

        # ── 17. every funnel stage is floored, not just stage 1 (#632) ─────
        #
        # Stage 3 is the only stage whose INPUT is this repository's own
        # output: it re-encodes what this project's compiler just emitted. A
        # construct the compiler emits that its own encoder refuses stops
        # exactly there and nowhere else — which is why #632's `panic!`
        # dispatcher arm was invisible to a baseline that floored stage 1
        # alone. The fixtures below hold `scored`, `clean` and stage 1 FIXED,
        # so each asserts the stage it names and nothing else.
        stage3 = Case(tmp, "stage3")
        stage3.put_artifact(
            "coverage-study-tier-a-rust/tier_a.json",
            # Stage 1 = 4/4 and clean = 0/4, exactly as the baseline demands;
            # two files now stop at stage 3 instead of reaching stage 4.
            tier_a_artifact(clean=0, drift=2, encode_errors=0, reencode_errors=2),
        )
        stage3.put_baseline([
            baseline_row(
                language="Rust",
                artifact="coverage-study-tier-a-rust/tier_a.json",
                scored=4,
                clean=0,
                encoded=4,
                compiledBack=4,
                reencoded=4,
                declarationsKept=2,
            )
        ])
        got = stage3.run()
        message = got.stdout + got.stderr
        check(
            "a stage-3 drop fails even with clean and stage 1 unchanged",
            got.returncode == 1,
            f"exit={got.returncode}\n{message}",
        )
        check(
            "the stage-3 breach names stage 3 and both numbers",
            "3 re-encoded" in message and "2/4" in message and "4/4" in message,
            message,
        )
        check(
            "a stage-3 breach never rewrites the baseline it just failed on",
            json.loads(stage3.baseline.read_text(encoding="utf-8"))["rows"][0]["reencoded"] == 4,
            stage3.baseline.read_text(encoding="utf-8"),
        )

        # ── 17b. …and a stage-3 gain raises that floor, naming the stage ────
        stage3_up = Case(tmp, "stage3_up")
        stage3_up.put_artifact(
            "coverage-study-tier-a-rust/tier_a.json",
            tier_a_artifact(clean=0, drift=2, encode_errors=0, reencode_errors=2),
        )
        stage3_up.put_baseline([
            baseline_row(
                language="Rust",
                artifact="coverage-study-tier-a-rust/tier_a.json",
                scored=4,
                clean=0,
                encoded=4,
                compiledBack=4,
                reencoded=0,
                declarationsKept=0,
            )
        ])
        got = stage3_up.run("--write")
        message = got.stdout + got.stderr
        raised = json.loads(stage3_up.baseline.read_text(encoding="utf-8"))["rows"][0]
        check(
            "a stage-3 gain passes and is persisted",
            got.returncode == 0 and raised["reencoded"] == 2,
            f"exit={got.returncode} row={raised}\n{message}",
        )
        check(
            "the raise names the funnel stage that moved",
            "3 re-encoded 0/4 -> 2/4" in message,
            message,
        )

        # ── 17c. a Tier A row missing a stage is rejected, never defaulted ──
        for missing_key in ("compiledBack", "reencoded", "declarationsKept"):
            partial_row = baseline_row()
            partial_row.pop(missing_key)
            short = Case(tmp, f"short_{missing_key}")
            short.put_artifact(
                "coverage-study-tier-a-dart/tier_a.json",
                tier_a_artifact(clean=3, drift=1, encode_errors=0),
            )
            short.put_baseline([partial_row])
            got = short.run()
            message = got.stdout + got.stderr
            check(
                f"a Tier A baseline row missing '{missing_key}' fails loud",
                got.returncode == 1 and missing_key in message,
                f"exit={got.returncode}\n{message}",
            )

        # ── 17d. a Tier B row carrying a funnel stage is rejected ───────────
        for stage_key in ("encoded", "compiledBack", "reencoded", "declarationsKept"):
            tierb_funnel = Case(tmp, f"tierb_{stage_key}")
            tierb_funnel.put_artifact(
                "coverage-study-tier-b-dart/tier_b.json",
                tier_b_artifact(clean=3, drift=1),
            )
            tierb_funnel.put_baseline([
                baseline_row(
                    tier="Tier B (per-file)",
                    kind="tier-b",
                    artifact="coverage-study-tier-b-dart/tier_b.json",
                    scored=4,
                    clean=3,
                    **{stage_key: 4},
                )
            ])
            got = tierb_funnel.run()
            message = got.stdout + got.stderr
            check(
                f"a Tier B row carrying '{stage_key}' fails loud",
                got.returncode == 1 and stage_key in message,
                f"exit={got.returncode}\n{message}",
            )

        # ── 17e. a funnel that rises down the stages cannot be measured ─────
        # The funnel is monotone by construction (a file that failed a stage
        # cannot pass the next), so a row claiming otherwise was hand-written,
        # and hand-written floors are how a ratchet gets quietly widened.
        impossible = Case(tmp, "impossible")
        impossible.put_artifact(
            "coverage-study-tier-a-dart/tier_a.json",
            tier_a_artifact(clean=3, drift=1, encode_errors=0),
        )
        impossible.put_baseline([baseline_row(compiledBack=5)])
        got = impossible.run()
        message = got.stdout + got.stderr
        check(
            "a non-monotone baseline funnel is rejected",
            got.returncode == 1 and "monotone" in message,
            f"exit={got.returncode}\n{message}",
        )

    total = _passed + _failed
    print(f"Results: {_passed} passed, {_failed} failed, {total} total")
    if total < 1:
        print("ERROR: the self-test asserted nothing.", file=sys.stderr)
        return 1
    return 1 if _failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
