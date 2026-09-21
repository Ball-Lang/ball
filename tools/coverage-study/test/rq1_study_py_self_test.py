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

TEST-ONLY EXCLUSION (the owner's 2026-09-14 methodology decision on #491).
Tier A scores the LIBRARY code a user would encode; a package's own test suite
is a different population and is out of the denominator. The rule must be
EXPLICIT, self-tested and COUNTED in the run summary — a silent filter is how a
denominator shrinks without anyone noticing. ``check_test_only_exclusion``
therefore pins both directions: every test-only shape is excluded *with the rule
that excluded it*, and every library file whose NAME merely contains "test"
(``latest.py``, ``contest.py``, ``attestation/``) is still scored. A sloppy
substring rule passes the first half and fails the second, which is the point.

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

# Declaration-less files (issue #721). `pyparsing/ai/__init__.py` and two of its
# siblings are ZERO-BYTE package markers: nothing to encode, nothing to measure.
# A re-export shim is the same shape with imports. Neither is evidence about a
# pipeline either way.
_SHIM_EMPTY = ""
_SHIM_REEXPORTS = '"""Re-exports."""\n\nfrom .core import thing\n'

# Declaration-less, with top-level code the encoder HANDLES.
_SCRIPT_SUPPORTED = 'print("hi")\n'
# Declaration-less, with top-level code the encoder REFUSES (`with` is outside
# its surface). Identical — empty — declaration inventory to the line above;
# only the pipeline outcome differs, so only a harness that decides from the
# SOURCE scores the two the same way.
_SCRIPT_UNSUPPORTED = 'with open("f") as handle:\n    pass\n'


# Library files whose NAME contains "test" as a substring ("la-test",
# "con-test", "at-test-ation"). These are the negative control: a rule that
# excluded any of them would be excluding LIBRARY code, so this self-test must
# go red on it rather than quietly shrink the denominator.
_LIBRARY_LOOKALIKES = ("latest.py", "contest.py", "attestation/verify.py")

# Python's own convention, per the owner decision on #491: `test_*.py`,
# `*_test.py`, `conftest.py`, and anything under a `test`/`tests` directory.
_TEST_ONLY = (
    "test_core.py",
    "core_test.py",
    "conftest.py",
    "tests/test_more.py",
    "tests/support.py",
)


def _write(root: Path, rel: str, text: str) -> None:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def check_test_only_exclusion() -> None:
    """Tier A scores library code; a package's own tests are excluded, counted
    and named — never silently dropped."""
    with tempfile.TemporaryDirectory(prefix="rq1_py_exclusion") as tmp:
        root = Path(tmp)
        library = ("core.py",) + _LIBRARY_LOOKALIKES
        for rel in library:
            _write(root, rel, "def value():\n    return 1\n")
        for rel in _TEST_ONLY:
            _write(root, rel, "def test_value():\n    assert True\n")

        studied, excluded = rq1.classify_python_files("synthetic", root)
        studied_rel = {p.relative_to(root).as_posix() for p in studied}
        excluded_rel = {e.file for e in excluded}

        check(
            "a library file whose name merely contains 'test' is still studied",
            studied_rel == set(library),
            f"studied {sorted(studied_rel)}, expected {sorted(library)}",
        )
        check(
            "every test-only file is excluded",
            excluded_rel == set(_TEST_ONLY),
            f"excluded {sorted(excluded_rel)}, expected {sorted(_TEST_ONLY)}",
        )
        check(
            "every exclusion names the rule that made it",
            bool(excluded) and all(e.rule for e in excluded),
            f"rules: {sorted({e.rule for e in excluded})}",
        )
        studied_results = rq1.study_directory("synthetic", root)
        check(
            "an excluded file never reaches the scored results",
            not ({r.file for r in studied_results} & set(_TEST_ONLY)),
            f"results: {sorted(r.file for r in studied_results)}",
        )

        out: list[str] = []
        rq1.render_report(out, studied_results, excluded, [])
        text = "".join(out)
        check(
            "the summary prints the exclusion count, so nothing disappears silently",
            f"  excluded (test-only): {len(_TEST_ONLY)}\n" in text,
            f"summary was:\n{text}",
        )

    # A run that excluded nothing still prints the line: a MISSING line is
    # indistinguishable from a rule that vanished, and summarize.sh fails on it.
    zero: list[str] = []
    rq1.render_report(zero, [rq1.study_file("synthetic", "plain.py", _HELPER)], [], [])
    check(
        "the exclusion count is printed even when it is zero",
        "  excluded (test-only): 0\n" in "".join(zero),
        f"summary was:\n{''.join(zero)}",
    )


def check_declaration_less_files() -> None:
    """The denominator is a property of the CORPUS, not of the encoder (#721).

    A file with no declarations used to leave the denominator at stage 4 —
    *after* encode, compile-back and re-encode — so whether it was scored
    depended on how far the pipeline happened to get. Issue #646 changed the
    encoder, three ZERO-BYTE ``__init__.py`` package markers stopped failing at
    stage 3, and the Python row's ``scored`` fell 73 -> 70 with not one file
    changed: every ratio moved for a reason no floor could attribute. The skip
    must therefore be decided from the SOURCE, before stage 1.

    ``__main__.py`` next to those markers is declaration-less too, but it is a
    real script body — top-level code an encoder either handles or does not, so
    it IS evidence and must stay scored.
    """
    shims = {
        "empty __init__.py": rq1.study_file("synthetic", "ai/__init__.py", _SHIM_EMPTY),
        "re-export shim": rq1.study_file(
            "synthetic", "pkg/__init__.py", _SHIM_REEXPORTS
        ),
    }
    for label, result in shims.items():
        check(
            f"a {label} is not scored — there is nothing in it to measure",
            not result.scored and result.reason.startswith("skipped:"),
            f'scored={result.scored} reason="{result.reason}"',
        )

    supported = rq1.study_file("synthetic", "run_ok.py", _SCRIPT_SUPPORTED)
    unsupported = rq1.study_file("synthetic", "run_bad.py", _SCRIPT_UNSUPPORTED)
    check(
        "a declaration-less file with top-level CODE is scored, not skipped",
        supported.scored and unsupported.scored,
        f"supported scored={supported.scored} ({supported.reason}); "
        f"unsupported scored={unsupported.scored} ({unsupported.reason})",
    )
    check(
        "two files with the same (empty) inventory are scored the same way, "
        "however far the pipeline gets",
        supported.scored == unsupported.scored
        and safe_stage(supported.reason) != safe_stage(unsupported.reason),
        f"stages {safe_stage(supported.reason)} vs {safe_stage(unsupported.reason)}",
    )

    # The outcome #721 names directly: a file that DOES declare things and comes
    # back declaring none of them is a failure, never a skip. That branch is
    # otherwise unreachable — `compile_library` always emits its header — and an
    # unreachable fail-open is exactly what has to be pinned, so the compiler is
    # stubbed out for this one call.
    real_compile = rq1.compile_library
    try:
        rq1.compile_library = lambda program: ""
        emptied = rq1.study_file("synthetic", "vanished.py", _HELPER)
    finally:
        rq1.compile_library = real_compile
    check(
        "a file whose declarations all vanish is a scored failure, not a skip",
        emptied.scored and not emptied.clean and safe_stage(emptied.reason) >= 0,
        f'scored={emptied.scored} reason="{emptied.reason}"',
    )

    # Provenance: the count is printed even at zero, for the same reason the
    # test-only exclusion count is — a missing line is indistinguishable from a
    # rule that silently vanished.
    for label, results, expected in (
        ("with a shim", [shims["empty __init__.py"], supported], 1),
        ("with none", [supported], 0),
    ):
        out: list[str] = []
        rq1.render_report(out, results, [], [])
        check(
            f"the summary prints the not-scorable count ({label})",
            f"  skipped (nothing to measure, not scored): {expected}\n" in "".join(out),
            f"summary was:\n{''.join(out)}",
        )


def main() -> int:
    check_test_only_exclusion()
    check_declaration_less_files()

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
