"""End-to-end conformance: compile each fixture and run it, byte-for-byte
comparing stdout against its committed golden output.

The curated list is the Phase-2 proof set — arithmetic, control flow, loops
(including ``break``/``continue`` with C-``for`` update semantics), recursion,
closures, and classes — every one proven golden-exact. This is the gate: if the
compiler or runtime regresses on any of these, the suite fails.
"""

from __future__ import annotations

import pytest

from ball_compiler import compile_program, load_program

from conftest import run_source

# Fixtures proven golden-exact by the Ball -> Python compiler (Phase 2). The
# first four are the task's required set; the rest broaden coverage across every
# supported construct.
PROVEN = [
    "31_arithmetic_basic",
    "32_arithmetic_negative",
    "33_comparison_chain",
    "34_boolean_logic",
    "35_short_circuit",
    "37_string_concat",
    "39_compound_assign",
    "40_increment_decrement",
    "41_for_sum",
    "43_countdown",
    "44_for_loop_basic",
    "45_for_in_loop",
    "46_while_loop",
    "47_do_while",
    "48_break_continue",
    "49_nested_loops",
    "50_if_else_chain",
    "51_nested_if",
    "52_max_of_three",
    "54_abs_value",
    "57_recursion_factorial",
    "58_mutual_recursion",
    "62_ternary",
    "71_fizzbuzz",
    "80_bubble_sort",
    "101_simple_class",
    "103_abstract_class",
]


@pytest.mark.parametrize("name", PROVEN)
def test_fixture_golden_exact(conformance_dir, name):
    program = load_program(conformance_dir / f"{name}.ball.json")
    golden = (conformance_dir / f"{name}.expected_output.txt").read_text(encoding="utf-8")
    source = compile_program(program)
    out = run_source(source)
    assert out.rstrip("\n") == golden.rstrip("\n"), f"{name}: got {out!r}, want {golden!r}"
