#!/usr/bin/env python3
"""Prove the `Parity Matrix` summary gate bites (issue #666).

WHY THIS EXISTS. `conformance-matrix.yml`'s summary is ~200 lines of shell
embedded in a workflow, and it is the ONLY thing that turns 17 independent row
results into one verdict. Nothing could execute it outside a real Actions run,
so every claim about it — "a skipped row is benign", "a non-zero parsed failure
count fails even on a successful job", "a pull_request run that executed zero
rows fails" — was prose.

The zero-row case is why this file was written. Since the per-row conditions
landed, `skipped` is (correctly) benign, so a PR on which every row's condition
evaluated false would print a full table of SKIPs and exit 0: a green
Conformance Matrix that executed nothing. `tools/ci/check_matrix_paths.sh`
prevents the known cause statically (a filter path that maps onto no row
signal); this floors the OUTCOME, whatever the cause.

HOW. The step's `run:` block is read out of the workflow, its `${{ … }}`
expressions are rendered from a scenario, and the result is executed with bash.
That is the real shell, not a restatement of it — an edit that disables the gate
(a mistyped variable, a `[` that exits 2 and silently skips its branch, a
condition inverted) changes the exit code here.

Usage:  python3 tools/test/test_parity_matrix_floor.py
Needs:  python3 + PyYAML + bash. Runs in ci.yml's always-on `proto` job.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - the runner image ships PyYAML
    print("::error::PyYAML is required by tools/test/test_parity_matrix_floor.py")
    sys.exit(1)

# The workflow's messages are UTF-8 (em dashes, box drawing). A Windows console
# defaulting to cp1252 would raise on the first one and lose the whole report.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):  # pragma: no cover
        pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "conformance-matrix.yml")

ENGINE_ROWS = [
    "dart-engine",
    "ts-engine",
    "ts-compiled-engine",
    "ts-compiled-direct",
    "cpp-compiled",
    "rust-engine",
    "csharp-engine",
    "go-engine",
    "python-engine",
]
OTHER_ROWS = [
    "csharp-compiler",
    "rust-compiler",
    "go-compiler",
    "python-compiler",
    "csharp-roundtrip",
    "python-roundtrip",
    "go-roundtrip",
    "rust-roundtrip",
]
ALL_ROWS = ENGINE_ROWS + OTHER_ROWS

EXPR = re.compile(r"\$\{\{\s*(.*?)\s*\}\}")


def load_summary_script() -> str:
    with open(WORKFLOW, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
    job = doc["jobs"]["summary"]
    scripts = [s["run"] for s in job["steps"] if isinstance(s, dict) and "run" in s]
    if len(scripts) != 1:
        raise SystemExit(
            "::error::expected exactly one `run:` step in the `summary` job, found "
            f"{len(scripts)} — this harness renders that step and must not guess."
        )
    # A CRLF checkout (Windows) leaves the CRs inside the scalar, and bash reads
    # a trailing \r as part of the token. CI checks out LF; normalize so this
    # harness tests the same bytes on both.
    return scripts[0].replace("\r\n", "\n").replace("\r", "\n")


# A `run: |` block scalar arrives de-indented, so these anchors carry no
# workflow indentation.
FLOOR_START = "engine_rows_run=0\n"
FLOOR_NEEDLE = "executed ZERO engine rows"
FLOOR_END = "\nfi\n"

# The SIBLING-ROW floor (the #725 review): a language group runs whole or not
# at all. Its own anchors, so the two negative controls stay independent.
SIBLING_START = "# ── SIBLING-ROW FLOOR"
SIBLING_NEEDLE = "ran PARTIALLY"
SIBLING_END = 'group_check "Python" \\\n'


def strip_floor(script: str) -> str:
    """The summary step WITHOUT the zero-row floor — the negative control.

    Run against the all-rows-skipped scenario this must exit 0, which is the
    state the review found: a green Conformance Matrix that executed nothing.
    If the block can no longer be located the harness fails loud rather than
    quietly testing the unmodified script twice."""
    try:
        i = script.index(FLOOR_START)
        j = script.index(FLOOR_NEEDLE, i)
        k = script.index(FLOOR_END, j) + len(FLOOR_END)
    except ValueError:
        raise SystemExit(
            "::error::could not locate the zero-row floor in the summary step — "
            "the negative control cannot be built, so this harness would prove "
            "nothing about it. Re-anchor strip_floor() or restore the floor."
        )
    return script[:i] + script[k:]


def render(script: str, event: str, results: dict, failed_counts: dict) -> str:
    """Substitute every `${{ … }}` the summary step uses. An expression this
    harness does not know is a hard error: silently rendering it to the empty
    string is exactly how a simulated gate stops testing the real one."""

    def sub(match: re.Match) -> str:
        expr = match.group(1)
        if expr == "github.event_name":
            return event
        m = re.fullmatch(r"needs\.([A-Za-z0-9_-]+)\.result", expr)
        if m:
            return results[m.group(1)]
        m = re.fullmatch(r"needs\.([A-Za-z0-9_-]+)\.outputs\.([A-Za-z0-9_]+)", expr)
        if m:
            job, field = m.group(1), m.group(2)
            if field == "failed":
                return failed_counts.get(job, "0" if results.get(job) == "success" else "")
            if results.get(job) != "success":
                return ""
            return {"passed": "350", "total": "350", "floor": "350"}.get(field, "0")
        raise SystemExit(f"::error::unrendered expression in the summary step: {expr}")

    return EXPR.sub(sub, script)


def run_case(
    name: str,
    event: str,
    engine: dict,
    other: dict,
    changes: str = "success",
    failed_counts: dict | None = None,
    want_exit: int = 0,
    needle: str = "",
    without_floor: bool = False,
    without_sibling_floor: bool = False,
) -> bool:
    results = {"changes": changes}
    for row in ENGINE_ROWS:
        results[row] = engine.get(row, "skipped")
    for row in OTHER_ROWS:
        results[row] = other.get(row, "skipped")

    source = load_summary_script()
    if without_floor:
        source = strip_floor(source)
    if without_sibling_floor:
        source = strip_sibling_floor(source)
    script = render(source, event, results, failed_counts or {})
    # Fed on stdin rather than written to a temp file: a Windows temp PATH is
    # not a path the bash on PATH can open, and a harness that cannot start the
    # shell would report a uniform failure rather than testing anything.
    # BYTES, not text: subprocess's text mode translates "\n" to os.linesep on
    # write, and a bash reading `pipefail\r` rejects the whole script.
    proc = subprocess.run(
        ["bash", "-s"],
        input=("set -uo pipefail\n" + script).encode("utf-8"),
        capture_output=True,
    )

    out = (proc.stdout or b"").decode("utf-8", "replace") + (
        proc.stderr or b""
    ).decode("utf-8", "replace")
    ok = proc.returncode == want_exit and (not needle or needle in out)
    if ok:
        print(f"PASS {name}")
    else:
        print(f"FAIL {name} (exit {proc.returncode}, wanted {want_exit})")
        for line in out.splitlines():
            print(f"    | {line}")
    return ok


def strip_sibling_floor(script: str) -> str:
    """The summary step WITHOUT the sibling-row floor — its negative control.

    Run against a PARTIALLY executed language group this must exit 0, which is
    the state the #725 review found: rust-engine ran, rust-roundtrip was
    skipped, the ratcheted RUST_ROUNDTRIP_FLOOR was never evaluated, and the
    matrix was green. If the block can no longer be located the harness fails
    loud rather than quietly testing the unmodified script twice."""
    try:
        i = script.index(SIBLING_START)
        j = script.index(SIBLING_NEEDLE, i)
        k = script.index(SIBLING_END, j)
        # ...through the end of the final group_check invocation (a `\`
        # continuation run that ends at the first line not ending in `\`).
        lines = script[k:].split("\n")
        n = 0
        for n, line in enumerate(lines):  # noqa: B007 - n is the result
            if not line.rstrip().endswith("\\"):
                break
        k += sum(len(line) + 1 for line in lines[: n + 1])
    except ValueError:
        raise SystemExit(
            "::error::could not locate the sibling-row floor in the summary "
            "step — the negative control cannot be built, so this harness "
            "would prove nothing about it. Re-anchor strip_sibling_floor() or "
            "restore the floor."
        )
    return script[:i] + script[k:]


def check_group_table_covers_every_row() -> bool:
    """Every matrix row job must appear in the summary's group_check table.

    The closed set is read from the WORKFLOW ITSELF (`jobs:` minus the
    classifier and the summary), never from a second hand-kept list here: a row
    added to `needs:` but forgotten in the table would otherwise be exempt from
    the sibling floor forever, and an unchecked row is the shape this floor
    exists to catch.
    """
    with open(WORKFLOW, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
    rows = sorted(set(doc["jobs"]) - {"changes", "summary"})
    if not rows:
        print("FAIL group table coverage (the workflow declares no matrix rows)")
        return False
    script = load_summary_script()
    missing = [r for r in rows if f'"{r}=' not in script]
    if missing:
        print(
            "FAIL group table coverage — rows absent from the group_check "
            f"table: {', '.join(missing)}"
        )
        return False
    print(f"PASS group table coverage ({len(rows)} matrix rows, all grouped)")
    return True


def main() -> int:
    rust_only_engine = {"rust-engine": "success"}
    rust_only_other = {"rust-compiler": "success", "rust-roundtrip": "success"}

    cases = [
        # THE FLOOR. A PR that executed no engine row at all must fail, even
        # though nothing "failed" — this is the case the review found open.
        (
            "PR with every row skipped FAILS",
            dict(
                name="PR with every row skipped FAILS",
                event="pull_request",
                engine={},
                other={},
                want_exit=1,
                needle="executed ZERO engine rows",
            ),
        ),
        # NEGATIVE CONTROL: the SAME scenario with the floor block removed is
        # green. That is the state the review found, and it is what proves the
        # case above is the floor biting rather than some other assertion.
        (
            "without the floor the same run is GREEN",
            dict(
                name="without the floor the same run is GREEN",
                event="pull_request",
                engine={},
                other={},
                want_exit=0,
                needle="All engines this diff requires passed conformance",
                without_floor=True,
            ),
        ),
        # The narrowing this PR exists for must still pass: one language's rows.
        (
            "PR with one language's rows passes",
            dict(
                name="PR with one language's rows passes",
                event="pull_request",
                engine=rust_only_engine,
                other=rust_only_other,
                want_exit=0,
                needle="Engine rows executed for this diff: 1 of 9",
            ),
        ),
        (
            "PR with every row passing passes",
            dict(
                name="PR with every row passing passes",
                event="pull_request",
                engine={r: "success" for r in ENGINE_ROWS},
                other={r: "success" for r in OTHER_ROWS},
                want_exit=0,
                needle="Engine rows executed for this diff: 9 of 9",
            ),
        ),
        # Push/schedule/dispatch rows are unconditional, so the floor is not
        # theirs to enforce — and must not fire on them.
        (
            "push with every row skipped is exempt from the floor",
            dict(
                name="push with every row skipped is exempt from the floor",
                event="push",
                engine={},
                other={},
                want_exit=0,
            ),
        ),
        # Pre-existing gates must keep biting with the floor in place.
        (
            "a failed engine row still fails",
            dict(
                name="a failed engine row still fails",
                event="pull_request",
                engine=dict(rust_only_engine, **{"go-engine": "failure"}),
                other=rust_only_other,
                want_exit=1,
                needle="Go Self-Hosted Engine row did not succeed",
            ),
        ),
        (
            "a successful row reporting failures still fails",
            dict(
                name="a successful row reporting failures still fails",
                event="pull_request",
                engine=rust_only_engine,
                other=rust_only_other,
                failed_counts={"rust-engine": "3"},
                want_exit=1,
                needle="reported 3 conformance failure(s)",
            ),
        ),
        # THE SIBLING FLOOR (the #725 review). One language's engine row ran
        # and its round-trip sibling did not: `engine_rows_run` is 1, nothing
        # "failed", and before this floor the run was GREEN while the ratcheted
        # RUST_ROUNDTRIP_FLOOR was never evaluated at all.
        (
            "a PARTIALLY executed language group FAILS",
            dict(
                name="a PARTIALLY executed language group FAILS",
                event="pull_request",
                engine={"rust-engine": "success"},
                other={"rust-compiler": "success"},  # rust-roundtrip skipped
                want_exit=1,
                needle="ran PARTIALLY",
            ),
        ),
        # NEGATIVE CONTROL: the SAME scenario without the sibling block is
        # green — that is what proves the case above is this floor biting.
        (
            "without the sibling floor the partial group is GREEN",
            dict(
                name="without the sibling floor the partial group is GREEN",
                event="pull_request",
                engine={"rust-engine": "success"},
                other={"rust-compiler": "success"},
                want_exit=0,
                needle="All engines this diff requires passed conformance",
                without_sibling_floor=True,
            ),
        ),
        # The sibling floor is NOT pull_request-only: on push every condition is
        # unconditionally true, so a partial group there is a broken workflow,
        # not a narrowing, and must still fail.
        (
            "a PARTIAL group on push also FAILS",
            dict(
                name="a PARTIAL group on push also FAILS",
                event="push",
                engine={r: "success" for r in ENGINE_ROWS},
                other={r: "success" for r in OTHER_ROWS if r != "go-roundtrip"},
                want_exit=1,
                needle="ran PARTIALLY",
            ),
        ),
        (
            "a broken classifier still fails",
            dict(
                name="a broken classifier still fails",
                event="pull_request",
                engine={r: "success" for r in ENGINE_ROWS},
                other={r: "success" for r in OTHER_ROWS},
                changes="failure",
                want_exit=1,
                needle="did not succeed",
            ),
        ),
    ]

    passed = 0
    failed = 0
    for _, kwargs in cases:
        if run_case(**kwargs):
            passed += 1
        else:
            failed += 1

    # Structural, not scenario-driven: counted with the rest so the positive
    # floor below covers it too.
    if check_group_table_covers_every_row():
        passed += 1
    else:
        failed += 1

    print(f"Results: {passed} passed, {failed} failed, {passed + failed} total")
    if passed < len(cases) + 1:  # +1: the group-table coverage check
        print(
            f"executed fewer cases than expected ({passed} < {len(cases) + 1}) — "
            "a harness that ran nothing is not a passing harness."
        )
        return 1
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
