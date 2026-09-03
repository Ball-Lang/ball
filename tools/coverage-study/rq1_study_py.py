#!/usr/bin/env python3
"""Tier A of the third-party coverage study — Python port (issue #493).

The Python sibling of ``tools/coverage-study/rq1_study.dart``. Same five
stages, same strictness, same output format::

    Python source -> ball_encoder -> ball_compiler.compile_library
                  -> Python source -> ball_encoder

A file is *clean* only when it encodes, compiles back, re-encodes, keeps every
declaration it started with, and reaches a **second-generation fixpoint**
(compiling the re-encoded program again yields the same source and the same
metadata-stripped Ball IR).

Two things this harness deliberately does NOT do:

1. **It does not delegate the declaration inventory to the encoder.** The
   inventory is walked with the standard library :mod:`ast` directly, so a bug
   in ``ball_encoder``'s own bookkeeping cannot hide a lost declaration from
   the harness. (The Dart harness uses ``analyzer`` for the same reason.)
2. **It does not skip entry-point-less files.** ``ball_compiler`` has a real
   library mode (:func:`ball_compiler.compiler.compile_library`), so a module
   that is only ``def``\\ s is compiled back, scored, and counted — the whole
   point of #493 is that real third-party code has no ``main``.

Usage (from the repo root)::

    python3 tools/coverage-study/rq1_study_py.py \\
        --pins tools/coverage-study/packages/python.json \\
        --checkouts <dir-with-one-clone-per-package> [--json <report.json>]

    python3 tools/coverage-study/rq1_study_py.py \\
        --package <name> --source-dir <dir> [--json <report.json>]

Report-only: see tests/conformance/COVERAGE_STUDY.md. The one thing that fails
here is a run that scored zero files — that is a harness/checkout failure, not
a 0% result.
"""

from __future__ import annotations

import argparse
import ast
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parents[2]

# The five Python packages are isolated (no workspace manager), exactly as each
# pytest suite's conftest.py bootstraps its siblings onto sys.path.
for _pkg in ("encoder", "compiler", "runtime"):
    _path = str(_REPO_ROOT / "python" / _pkg)
    if _path not in sys.path:
        sys.path.insert(0, _path)

from ball_compiler.compiler import compile_library  # noqa: E402
from ball_encoder import encode  # noqa: E402


@dataclass
class FileResult:
    """One file's verdict. Mirrors rq1_study.dart's ``FileResult``."""

    package: str
    file: str
    clean: bool
    reason: str
    scored: bool = True
    ir_stable: bool = False

    def to_json(self) -> dict:
        return {
            "package": self.package,
            "file": self.file,
            "scored": self.scored,
            "clean": self.clean,
            "irStable": self.ir_stable,
            "reason": self.reason,
        }


def strip_metadata(node):
    """Recursively drop every ``metadata`` map.

    Metadata is cosmetic (Ball invariant #2), so two programs that differ only
    there are semantically identical — the project's own definition of
    semantic equality, and the same one rq1_study.dart uses.
    """
    if isinstance(node, dict):
        return {k: strip_metadata(v) for k, v in node.items() if k != "metadata"}
    if isinstance(node, list):
        return [strip_metadata(v) for v in node]
    return node


def _canonical(program: dict) -> str:
    return json.dumps(strip_metadata(program), sort_keys=True)


def _member_names(owner: str, body: list[ast.stmt]) -> set[str]:
    names: set[str] = set()
    for stmt in body:
        if isinstance(stmt, (ast.FunctionDef, ast.AsyncFunctionDef)):
            names.add(f"{owner}.{stmt.name}")
        elif isinstance(stmt, ast.Assign):
            for target in stmt.targets:
                if isinstance(target, ast.Name):
                    names.add(f"{owner}.{target.id}")
        elif isinstance(stmt, ast.AnnAssign) and isinstance(stmt.target, ast.Name):
            names.add(f"{owner}.{stmt.target.id}")
    return names


def declaration_inventory(source: str) -> set[str]:
    """The declaration inventory of ``source``.

    One entry per top-level declaration, class members included, so a lost
    method is visible and mere reordering is not. Walked with the standard
    library :mod:`ast` — independent of ``ball_encoder``'s own walk.
    """
    tree = ast.parse(source)
    names: set[str] = set()
    for stmt in tree.body:
        if isinstance(stmt, (ast.FunctionDef, ast.AsyncFunctionDef)):
            names.add(f"function {stmt.name}")
        elif isinstance(stmt, ast.ClassDef):
            names.add(f"class {stmt.name}")
            names |= _member_names(f"class {stmt.name}", stmt.body)
        elif isinstance(stmt, ast.Assign):
            for target in stmt.targets:
                if isinstance(target, ast.Name):
                    names.add(f"var {target.id}")
        elif isinstance(stmt, ast.AnnAssign) and isinstance(stmt.target, ast.Name):
            names.add(f"var {stmt.target.id}")
    return names


# How far a scored file got, derived from its taxonomy tag. The clean
# percentage alone cannot distinguish "the encoder rejected the file outright"
# from "everything worked but the third generation drifted", and on a pipeline
# that is not yet round-trip-closed the whole signal lives in that difference.
_STAGES = (
    (1, "1 encoded"),
    (2, "2 compiled back"),
    (3, "3 re-encoded"),
    (4, "4 declarations kept"),
    (5, "5 fixpoint (clean)"),
)

_STAGE_REACHED = {
    "read-error": 0,
    "encode-error": 0,
    "compile-error": 1,
    "reencode-error": 2,
    "parse-error": 3,
    "declaration-drift": 3,
    "fixpoint-error": 4,
    "fixpoint-drift": 4,
    "clean": 5,
}


def stage_reached(reason: str) -> int:
    """The last stage a scored file survived, from its taxonomy tag."""
    tag = reason.split(":", 1)[0]
    if tag not in _STAGE_REACHED:
        raise ValueError(f"unknown taxonomy tag {tag!r} — the funnel would silently lie")
    return _STAGE_REACHED[tag]


def _first_line(error: BaseException) -> str:
    text = str(error).replace("\r", "")
    line = text.split("\n", 1)[0]
    return line[:160] + "…" if len(line) > 160 else line


def study_file(package: str, file: str, source: str) -> FileResult:
    """Run Tier A over one file's ``source`` and return its verdict."""
    # Stage 1 — encode.
    try:
        program = encode(source)
        first_ir = _canonical(program)
    except Exception as ex:  # noqa: BLE001 — every encoder failure is a datum
        return FileResult(package, file, False, f"encode-error: {_first_line(ex)}")

    # Stage 2 — compile back in LIBRARY mode. Real library files have no entry
    # point, so `compile_program` is not an option; `compile_library` emits every
    # class/function without the `if __name__ == "__main__"` driver.
    try:
        compiled = compile_library(program)
    except Exception as ex:  # noqa: BLE001
        return FileResult(package, file, False, f"compile-error: {_first_line(ex)}")
    if not compiled.strip():
        return FileResult(
            package, file, False,
            "skipped: the file compiles to nothing (no user module)", scored=False,
        )

    # Stage 3 — re-encode the compiled Python.
    try:
        program2 = encode(compiled)
        second_ir = _canonical(program2)
    except Exception as ex:  # noqa: BLE001
        return FileResult(package, file, False, f"reencode-error: {_first_line(ex)}")

    # Stage 4 — declaration inventory preserved?
    try:
        before = declaration_inventory(source)
        after = declaration_inventory(compiled)
    except SyntaxError as ex:
        return FileResult(package, file, False, f"parse-error: {_first_line(ex)}")
    if not before:
        return FileResult(
            package, file, False,
            "skipped: no top-level declarations to compile", scored=False,
        )
    ir_stable = first_ir == second_ir
    lost = before - after
    if lost:
        shown = ", ".join(sorted(lost)[:3])
        return FileResult(
            package, file, False,
            f"declaration-drift: lost {len(lost)} declaration(s) — {shown}",
            ir_stable=ir_stable,
        )

    # Stage 5 — SECOND-GENERATION FIXPOINT. Generation 1 vs. 2 is not a usable
    # signal (the compiler faithfully lowers Ball's single `input` parameter back
    # to a named local, so almost nothing is stable across the FIRST pass). From
    # generation 2 on that lowering is already applied, so a pipeline that
    # neither loses nor invents meaning must reach a fixpoint.
    try:
        compiled2 = compile_library(program2)
        third_ir = _canonical(encode(compiled2))
    except Exception as ex:  # noqa: BLE001
        return FileResult(
            package, file, False,
            f"fixpoint-error: generation 2 failed to compile — {_first_line(ex)}",
            ir_stable=ir_stable,
        )
    if compiled != compiled2 or second_ir != third_ir:
        return FileResult(
            package, file, False,
            "fixpoint-drift: recompiling the re-encoded program changed it again",
            ir_stable=ir_stable,
        )

    return FileResult(package, file, True, "clean", ir_stable=ir_stable)


def python_files_under(directory: Path) -> list[Path]:
    """Every ``.py`` file under ``directory``, sorted, tests excluded."""
    return sorted(
        p for p in directory.rglob("*.py")
        if not any(part in {"test", "tests", "__pycache__"} for part in p.parts)
    )


def study_directory(package: str, directory: Path) -> list[FileResult]:
    results: list[FileResult] = []
    for path in python_files_under(directory):
        rel = path.relative_to(directory).as_posix()
        # Read as BYTES and decode explicitly: text mode would apply
        # universal-newline translation, which collapses a semantic lone \r.
        try:
            source = path.read_bytes().decode("utf-8")
        except (OSError, UnicodeDecodeError) as ex:
            results.append(FileResult(package, rel, False, f"read-error: {_first_line(ex)}"))
            continue
        results.append(study_file(package, rel, source))
    return results


@dataclass
class Run:
    results: list[FileResult] = field(default_factory=list)
    missing_pins: list[str] = field(default_factory=list)


def run_pins(pins_path: Path, checkouts: Path) -> Run:
    run = Run()
    pins = json.loads(pins_path.read_bytes().decode("utf-8"))["packages"]
    for pin in pins:
        name = pin["name"]
        directory = checkouts / name / pin.get("lib", "src")
        if not directory.is_dir():
            # An unreachable pin is NOT an encoder regression — report it as a
            # distinct outcome instead of scoring it as a failure.
            run.missing_pins.append(name)
            continue
        run.results.extend(study_directory(name, directory))
    return run


def report(run: Run, json_out: str | None) -> int:
    if json_out:
        Path(json_out).write_text(
            json.dumps(
                {
                    "missingPins": run.missing_pins,
                    "files": [r.to_json() for r in run.results],
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

    scored = [r for r in run.results if r.scored]
    total = len(scored)
    clean = sum(1 for r in scored if r.clean)
    ir_stable = sum(1 for r in scored if r.ir_stable)
    skipped = len(run.results) - total

    by_reason: dict[str, int] = {}
    for r in scored:
        tag = r.reason.split(":", 1)[0]
        by_reason[tag] = by_reason.get(tag, 0) + 1
    for tag, count in sorted(by_reason.items(), key=lambda kv: (-kv[1], kv[0])):
        print(f"  {tag}: {count}")
    if skipped:
        print(f"  skipped (no declarations, not scored): {skipped}")
    if run.missing_pins:
        print(f"  unreachable pins (not scored): {', '.join(run.missing_pins)}")

    if scored:
        print("Funnel (scored files that survived each stage):")
        for threshold, label in _STAGES:
            reached = sum(1 for r in scored if stage_reached(r.reason) >= threshold)
            print(f"  {label}: {reached}/{total}")

    pct = 0 if total == 0 else round(clean * 100 / total)
    print(f"Tier A: {clean}/{total} clean ({pct}%)")
    print(f"Tier A (IR fixpoint, informational): {ir_stable}/{total} stable")
    print(f"Results: {clean} passed, {total - clean} failed, {total} total")

    # Positive floor: a run that scored nothing is a harness/checkout failure,
    # not a 0% result.
    if total < 1:
        print(
            "ERROR: Tier A scored 0 files — no package checkout was readable.",
            file=sys.stderr,
        )
        return 1
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Tier A coverage study (Python)")
    parser.add_argument("--pins")
    parser.add_argument("--checkouts")
    parser.add_argument("--package")
    parser.add_argument("--source-dir", dest="source_dir")
    parser.add_argument("--json")
    args = parser.parse_args(argv)

    if args.pins:
        if not args.checkouts:
            parser.error("--pins requires --checkouts <dir>")
        run = run_pins(Path(args.pins), Path(args.checkouts))
    elif args.package and args.source_dir:
        directory = Path(args.source_dir)
        if not directory.is_dir():
            print(f"--source-dir does not exist: {args.source_dir}", file=sys.stderr)
            return 2
        run = Run(results=study_directory(args.package, directory))
    else:
        parser.error("either --pins/--checkouts or --package/--source-dir is required")

    return report(run, args.json)


if __name__ == "__main__":
    # Python's recursion limit is well below what a deeply-nested third-party
    # expression tree needs when it is walked three times over.
    sys.setrecursionlimit(max(sys.getrecursionlimit(), 20000))
    raise SystemExit(main(sys.argv[1:]))
