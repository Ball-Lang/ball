"""Module-level variables are DECLARATIONS, not locals of the synthesised main.

Issue #721. A Python module's top-level ``__version__ = "1.0"`` is part of the
module's public surface. The encoder used to fold every loose top-level
statement into the synthesised ``main``, which turns that declaration into a
function local: the compiled-back module no longer declares it at all, and the
encoder reported success. That is the silent-degradation shape ``CLAUDE.md``
forbids, and it is what the third-party coverage study measured on two real
files — ``packaging/__init__.py`` lost all eight of its ``__dunder__``
declarations, ``boltons/__init__.py`` its ``__version__``.

Lifting a module-level assignment is only sound when it cannot reorder an
observable effect: a Ball top-level variable is emitted by every compiler after
the functions and before any entry point. The four conditions
(``encoder._lifted_top_level_vars``) are pinned below, each with its negative
control, and the behavioural half (native Python == encode -> compile -> run)
is pinned by :func:`test_lifting_preserves_output`.
"""

from __future__ import annotations

import ast

from ball_compiler.compiler import compile_library
from ball_encoder import encode

from conftest import run_ball


# ── helpers ──────────────────────────────────────────────────────────────────


def top_level_vars(program: dict) -> dict[str, dict]:
    """Every function of the ``main`` module tagged ``top_level_variable``."""
    main = next(m for m in program["modules"] if m["name"] == "main")
    return {
        f["name"]: f
        for f in main["functions"]
        if (f.get("metadata") or {}).get("kind") == "top_level_variable"
    }


def module_declarations(source: str) -> set[str]:
    """The top-level declaration inventory of ``source``.

    The same walk ``tools/coverage-study/rq1_study_py.py`` performs for Tier A
    stage 4, restated here so this suite asserts the property in its own terms
    rather than importing the study harness.
    """
    names: set[str] = set()
    for stmt in ast.parse(source).body:
        if isinstance(stmt, (ast.FunctionDef, ast.AsyncFunctionDef)):
            names.add(f"function {stmt.name}")
        elif isinstance(stmt, ast.ClassDef):
            names.add(f"class {stmt.name}")
        elif isinstance(stmt, ast.Assign):
            for target in stmt.targets:
                if isinstance(target, ast.Name):
                    names.add(f"var {target.id}")
        elif isinstance(stmt, ast.AnnAssign) and isinstance(stmt.target, ast.Name):
            names.add(f"var {stmt.target.id}")
    return names


def run_compiled_library(source: str) -> dict:
    """Encode, compile back in library mode, execute, return the namespace."""
    compiled = compile_library(encode(source))
    namespace: dict = {}
    exec(compile(compiled, "<compiled>", "exec"), namespace)
    return namespace


# ── the declaration itself ───────────────────────────────────────────────────


def test_module_level_variable_is_encoded_as_a_declaration():
    program = encode('__version__ = "1.0.0"\n')

    lifted = top_level_vars(program)
    assert "__version__" in lifted, (
        "a module-level variable must be encoded as a top-level variable "
        f"declaration, not as a statement of main — got {sorted(lifted)}"
    )
    assert lifted["__version__"]["body"] == {"literal": {"stringValue": "1.0.0"}}


def test_annotated_module_level_variable_keeps_its_declared_type():
    program = encode("LIMIT: int = 7\n")

    lifted = top_level_vars(program)
    assert "LIMIT" in lifted
    assert lifted["LIMIT"]["outputType"] == "int"


def test_module_level_variables_survive_compile_back():
    """Tier A stage 4, stated directly: no declaration may be lost."""
    source = (
        '__title__ = "packaging"\n'
        '__author__ = "Donald Stufft and individual contributors"\n'
        '__copyright__ = f"2014 {__author__}"\n'
        "\n"
        "\n"
        "def described():\n"
        "    return __title__\n"
    )

    compiled = compile_library(encode(source))

    lost = module_declarations(source) - module_declarations(compiled)
    assert not lost, f"compiling back lost {sorted(lost)}"


def test_a_lifted_variable_is_readable_from_a_function():
    namespace = run_compiled_library(
        "SIZE = 4\n\n\ndef doubled():\n    return SIZE * 2\n"
    )

    assert namespace["SIZE"] == 4
    assert namespace["doubled"]() == 8


def test_a_lifted_initializer_may_read_an_earlier_lifted_variable():
    namespace = run_compiled_library('FIRST = "a"\nSECOND = FIRST + "b"\n')

    assert namespace["SECOND"] == "ab"


# ── the four conditions, each with its negative control ──────────────────────


def test_a_reassigned_name_is_not_lifted():
    """Condition 2 — a name bound twice at module scope is not one declaration
    with one initializer, so it keeps the old encoding (a local of main)."""
    program = encode('count = 1\ncount = 2\nprint(count)\n')

    assert top_level_vars(program) == {}


def test_an_augmented_name_is_not_lifted():
    """Condition 2 — ``+=`` is a second binding of the same name."""
    program = encode("count = 1\ncount += 1\nprint(count)\n")

    assert top_level_vars(program) == {}


def test_a_name_rebound_inside_a_main_guard_is_not_lifted():
    """Condition 2 — the guard body runs at module scope too."""
    program = encode(
        'label = "a"\n'
        'if __name__ == "__main__":\n'
        '    label = "b"\n'
        "    print(label)\n"
    )

    assert top_level_vars(program) == {}


def test_an_assignment_after_an_effectful_statement_is_not_lifted():
    """Condition 3 — lifting would step the initializer over that ``print``,
    swapping the two observable effects."""
    program = encode('print("first")\nlabel = "second"\nprint(label)\n')

    assert top_level_vars(program) == {}


def test_an_initializer_reading_a_main_local_is_not_lifted():
    """Condition 4 — ``doubled`` reads ``count``, which stayed a local of main;
    lifting it would emit a module-level read of a name that is not there."""
    program = encode("count = 1\ncount = 2\ndoubled = count\n")

    assert top_level_vars(program) == {}


# ── behaviour ────────────────────────────────────────────────────────────────


def test_lifting_preserves_output():
    """The behavioural half: encode -> compile -> run still prints the same."""
    source = (
        'GREETING = "Hello"\n'
        'TARGET = "Ball"\n'
        "\n"
        "\n"
        "def main():\n"
        '    print(GREETING + ", " + TARGET)\n'
    )

    assert run_ball(source) == "Hello, Ball\n"


def test_an_unliftable_assignment_still_runs_in_order():
    """The negative control's behavioural half: the statements a condition
    refuses to lift keep running exactly where they were."""
    source = 'print("first")\nlabel = "second"\nprint(label)\n'

    assert run_ball(source) == "first\nsecond\n"
