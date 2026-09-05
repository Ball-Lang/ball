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
   regeneration and a week with no change produces no commit at all.

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
    skipped: int = 0,
    pascal_case: bool = False,
) -> dict:
    """A synthetic Tier A report in the shape every harness writes.

    ``pascal_case`` reproduces the C# harness's System.Text.Json output, whose
    keys are ``Package``/``Scored``/``Clean``/``Reason`` while the other five
    harnesses emit camelCase. A renderer that only understood one casing would
    read the C# artifact as an empty report — i.e. as a pass.
    """
    files = []
    for i in range(clean):
        files.append({"package": "p", "file": f"clean{i}.x", "scored": True, "clean": True, "irStable": True, "reason": "clean"})
    for i in range(drift):
        files.append({"package": "p", "file": f"drift{i}.x", "scored": True, "clean": False, "irStable": False, "reason": "fixpoint-drift: generation 3 differed"})
    for i in range(encode_errors):
        files.append({"package": "p", "file": f"enc{i}.x", "scored": True, "clean": False, "irStable": False, "reason": "encode-error: unsupported construct"})
    for i in range(skipped):
        files.append({"package": "p", "file": f"skip{i}.x", "scored": False, "clean": False, "irStable": False, "reason": "skipped: no declarations"})
    if pascal_case:
        files = [{k[0].upper() + k[1:]: v for k, v in f.items()} for f in files]
        return {"MissingPins": [], "Files": files}
    return {"missingPins": [], "files": files}


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
        "encoded": 4,
    }
    row.update(over)
    # A Tier B row has no funnel, so it carries no `encoded`. Leaving the
    # default in would make both Tier B cases below fail on the row shape
    # instead of on the thing they claim to assert — a drop that "passes"
    # because the fixture was rejected first is a false green.
    if row["kind"] == "tier-b" and "encoded" not in over:
        row.pop("encoded")
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

    def run(self, *extra: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--artifacts",
                str(self.artifacts),
                "--baseline",
                str(self.baseline),
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

    total = _passed + _failed
    print(f"Results: {_passed} passed, {_failed} failed, {total} total")
    if total < 1:
        print("ERROR: the self-test asserted nothing.", file=sys.stderr)
        return 1
    return 1 if _failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
