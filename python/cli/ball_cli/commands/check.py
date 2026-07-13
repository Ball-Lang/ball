"""``ball check <program.ball.json> [--compile]`` — validate without running.

Runs a battery of structural checks over the raw proto3-JSON view. Mirrors the
Go/Rust CLIs' ``check`` and Dart's ``_validate``:

* ``entry_module`` / ``entry_function`` are set and resolve to a real module +
  function;
* every module has a non-empty, unique name;
* every non-base function carries a body or metadata (only base functions may omit
  both — the per-platform extensibility mechanism, CLAUDE.md invariant 3;
  constructors, abstract methods, and getters have no body but a metadata bag).

With ``--compile``, and only when the structural checks passed, it additionally
attempts a dry-run ``python/compiler`` compile (output discarded) — a stronger,
Python-target-specific check that catches shapes the structural checks don't, at
the cost of false positives for a program that is valid Ball but hits a
documented ``python/compiler`` scope gap; hence opt-in.

Any finding is reported as a single invalid-program error (exit 2) listing every
problem; success prints a one-line summary to stdout (exit 0).
"""

from __future__ import annotations

from typing import TextIO

from ..argparse_util import StreamParser
from ..errors import parse_error
from ..loader import load_program_dict


def command(args: list[str], stdout: TextIO, stderr: TextIO) -> int:
    parser = StreamParser(
        prog="ball check",
        description="Parse and validate a Ball program (.ball.json) without running it.",
        out=stdout,
        err=stderr,
    )
    parser.add_argument("input", metavar="<program.ball.json>", help="path to a .ball.json program")
    parser.add_argument(
        "--compile", dest="also_compile", action="store_true",
        help="additionally attempt a dry-run compile to Python (stronger, Python-specific check)",
    )
    ns = parser.parse_args(args)

    program = load_program_dict(ns.input)
    problems = validate_structure(program)

    if ns.also_compile and not problems:
        from ball_compiler import CompileError, compile_program

        try:
            compile_program(program)
        except CompileError as ex:
            problems.append(f"does not compile to Python: {ex}")

    if problems:
        msg = f"invalid program: {len(problems)} error(s) found"
        for p in problems:
            msg += f"\n  - {p}"
        raise parse_error(msg)

    modules = program.get("modules", []) or []
    fn_count = sum(len(m.get("functions", []) or []) for m in modules)
    name = program.get("name", "")
    version = program.get("version", "")
    stdout.write(f'Valid: "{name}" v{version}\n')
    stdout.write(f"  {len(modules)} module(s), {fn_count} function(s)\n")
    return 0


def validate_structure(program: dict) -> list[str]:
    """Return a list of human-readable findings, empty when the program is
    structurally sound. Split out from :func:`command` so it stays trivially
    unit-testable without a filesystem round trip."""
    problems: list[str] = []

    modules = program.get("modules", []) or []
    entry_mod = program.get("entryModule", "")
    entry_fn = program.get("entryFunction", "")

    if not entry_mod:
        problems.append("missing entry_module")
    if not entry_fn:
        problems.append("missing entry_function")

    if entry_mod and entry_fn:
        found = next((m for m in modules if m.get("name", "") == entry_mod), None)
        if found is None:
            problems.append(f"entry module {entry_mod!r} not found in modules")
        else:
            names = {f.get("name", "") for f in (found.get("functions", []) or [])}
            if entry_fn not in names:
                problems.append(f"entry function {entry_fn!r} not found in module {entry_mod!r}")

    seen: set[str] = set()
    for i, m in enumerate(modules):
        name = m.get("name", "")
        if not name:
            problems.append(f"module at index {i} has no name")
            continue
        if name in seen:
            problems.append(f"duplicate module name: {name!r}")
        seen.add(name)

    for m in modules:
        mod_name = m.get("name", "")
        for f in m.get("functions", []) or []:
            # Only base functions may omit a body (CLAUDE.md invariant 3). A
            # non-base function is well-formed if it carries a body OR metadata —
            # constructors, abstract methods, and getters/setters have no body
            # expression but a metadata bag (`kind: constructor`, `params`, …)
            # that drives them. Mirrors go/cli's rule (body || metadata).
            if not f.get("isBase", False) and f.get("body") is None and f.get("metadata") is None:
                problems.append(
                    f"{mod_name}.{f.get('name', '')}: non-base function with no body or metadata")

    return problems
