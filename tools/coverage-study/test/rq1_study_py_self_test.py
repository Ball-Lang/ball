#!/usr/bin/env python3
"""Self-test for the Python Tier A coverage-study harness (issue #493).

A new measuring instrument must not inherit the blind spot it exists to close.
The gap #493 documents is that every existing gate is scoped to the project's
own single-file, entry-point-shaped conformance fixtures, so real library code
— no ``main``, declarations split across files — was never looked at. The
cheapest way for this harness to inherit that blind spot would be to SKIP such
files and then report a flattering number over whatever is left.

WHAT THIS DOES AND DOES NOT PROVE. These assertions validate the HARNESS. They
are not regression tests for any encoder/compiler defect: the Tier A run itself
is report-only (``coverage-study.yml`` has no ``pull_request:`` trigger), and a
Python-pipeline regression it measures would not redden this or any other PR.

The Dart original (``rq1_study_self_test.dart``) can assert "a plain file is
reported clean" because the Dart round trip is closed — the Dart compiler emits
idiomatic Dart the Dart encoder can read back. The Python round trip is NOT
closed today: ``ball_compiler`` emits ``ballrt.*`` runtime calls wrapped in
``try/except``, and ``ball_encoder`` supports neither, so stage 3 (re-encode)
fails on every file that reaches it. There is therefore no Python source that
this harness can honestly call clean, and asserting one would mean weakening
the harness until something passed. Assertion 2 below asserts the *funnel*
instead — the strongest statement that is true today — and it strengthens by
itself the moment the round trip closes.

Run from the repo root:
    python3 tools/coverage-study/test/rq1_study_py_self_test.py
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import rq1_study_py as rq1  # noqa: E402

_passed = 0
_failed = 0


def safe_stage(reason: str) -> int:
    """``stage_reached`` with an unknown tag reported as -1 rather than raised,
    so one broken verdict fails its own assertion instead of aborting the run."""
    try:
        return rq1.stage_reached(reason)
    except ValueError:
        return -1


def check(name: str, ok: bool, detail: str = "") -> None:
    global _passed, _failed
    if ok:
        _passed += 1
        print(f"PASS  {name}")
    else:
        _failed += 1
        print(f"FAIL  {name}{'' if not detail else ' — ' + detail}")


# `helper.py` — a plain helper library. No `main`, no `if __name__` guard,
# nothing exotic: exactly the shape every gate before #493 never looked at.
_HELPER = '''\
def twice(value):
    return value * 2
'''

# `consumer.py` — calls into the sibling file, so it cannot be understood in
# isolation, and still has no entry point.
_CONSUMER = '''\
from helper import twice


def doubled(value):
    return twice(value)


def combine(a, b):
    return a + b
'''

# A construct the encoder explicitly rejects (`async functions are not
# supported`). Used as the negative control: it must be REPORTED with its own
# taxonomy tag and must stop strictly earlier in the funnel than the plain
# file, so the harness cannot pass by painting every file with one reason.
_UNSUPPORTED = '''\
async def fetch(value):
    return value
'''


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="rq1_py_self_test") as tmp:
        root = Path(tmp)
        (root / "helper.py").write_text(_HELPER, encoding="utf-8")
        (root / "consumer.py").write_text(_CONSUMER, encoding="utf-8")

        results = rq1.study_directory("synthetic", root)

        # 1 — the whole point of #493: entry-point-less files are SCORED.
        check(
            "both files of an entry-point-less package are scored, none skipped",
            len(results) == 2 and all(r.scored for r in results),
            "got " + ", ".join(f"{r.file}(scored={r.scored})" for r in results),
        )

        # 5 — the harness's own positive floor: a run that scores nothing
        # proves nothing, so the synthetic package must produce a denominator.
        check(
            "the scored denominator is >= 1",
            sum(1 for r in results if r.scored) >= 1,
        )

        helper = [r for r in results if r.file == "helper.py"]
        check(
            "the plain library file gets a real verdict, not a skip",
            len(helper) == 1 and helper[0].scored and bool(helper[0].reason),
        )

        # 3 — every verdict carries a taxonomy tag the funnel knows. An unknown
        # tag makes `stage_reached` raise, so this also proves the funnel cannot
        # silently mis-attribute a new failure mode.
        stages = {r.file: safe_stage(r.reason) for r in results}
        check(
            "every verdict carries a known taxonomy tag",
            all(":" in r.reason for r in results)
            and all(v >= 0 for v in stages.values())
            and len(stages) == 2,
            f"reasons: {[r.reason for r in results]}",
        )

        plain_stage = stages.get("helper.py", -1)
        # 2 — the funnel is real: a plain library file gets PAST encode and
        # compile-back. If the harness were failing everything at stage 1 and
        # calling that a measurement, this would be 0.
        check(
            "a plain library file survives encode and compile-back (funnel >= 2)",
            plain_stage >= 2,
            f"stage reached was {plain_stage} "
            f"(reason: {helper[0].reason if helper else 'n/a'})",
        )

    # 4 (negative control) — a construct the encoder rejects must be scored,
    # not clean, tagged `encode-error`, and must stop STRICTLY EARLIER than the
    # plain file. Same-tag-for-everything is the failure mode this catches.
    unsupported = rq1.study_file("synthetic", "unsupported.py", _UNSUPPORTED)
    check(
        "an unsupported construct is scored, not clean, and tagged encode-error",
        unsupported.scored
        and not unsupported.clean
        and unsupported.reason.startswith("encode-error:"),
        f"scored={unsupported.scored} clean={unsupported.clean} "
        f'reason="{unsupported.reason}"',
    )
    check(
        "the harness discriminates: the rejected file stops earlier than the plain one",
        safe_stage(unsupported.reason) < plain_stage,
        f"unsupported stage={safe_stage(unsupported.reason)} "
        f"plain stage={plain_stage}",
    )

    # The declaration-inventory walker is the harness's own eyes for stage 4.
    # Prove it is a real AST walk — it must see class members, and it must
    # actually MISS a declaration that was removed, or stage 4 is a rubber stamp.
    full = rq1.declaration_inventory(
        "class Box:\n"
        "    size = 1\n"
        "\n"
        "    def area(self):\n"
        "        return self.size\n"
        "\n"
        "\n"
        "def free(value):\n"
        "    return value\n"
    )
    pruned = rq1.declaration_inventory("class Box:\n    size = 1\n")
    check(
        "the declaration inventory sees classes, members and free functions",
        full
        == {"class Box", "class Box.size", "class Box.area", "function free"},
        f"got {sorted(full)}",
    )
    check(
        "the declaration inventory detects a lost declaration",
        full - pruned == {"class Box.area", "function free"},
        f"got {sorted(full - pruned)}",
    )

    total = _passed + _failed
    print(f"Results: {_passed} passed, {_failed} failed, {total} total")
    if total < 1:
        print("ERROR: the self-test asserted nothing.", file=sys.stderr)
        return 1
    return 1 if _failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
