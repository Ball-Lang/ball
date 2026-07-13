"""Round-trip conformance: the encoder's proof of correctness.

For each authored Python source we (1) run it natively, asserting it matches a
fixed golden, then (2) encode Python → Ball, compile the Ball back to Python with
the Phase-2 compiler, run that, and assert the compiled-Ball output equals the
native output. This is Python → Ball → (compile + run) ≡ native Python, end to
end — a behavioural assertion, not "it produced a Program". The golden is the
third leg: native == golden == round-trip.
"""

from __future__ import annotations

import pytest

from conftest import read_source, run_ball, run_native

# (file, golden). The golden is the exact native stdout; run_native asserts the
# golden matches a real Python run, and run_ball asserts the compiled Ball run
# matches it too.
CASES = [
    ("hello_world.py", "Hello, World!\n"),
    ("arithmetic.py", "18\n"),
    ("control_flow.py", "12\n"),
    ("list_loop.py", "10\n20\n30\n60\n20\n"),
    ("fizzbuzz.py", "1\n2\nFizz\n4\nBuzz\nFizz\n7\n8\nFizz\nBuzz\n11\nFizz\n13\n14\nFizzBuzz\n"),
    ("recursion.py", "120\n1\n"),
    ("closures.py", "15\n30\n"),
    ("strings.py", "Hello, Ball!\n12\nHello, Ball! has 12 chars\n"),
    ("descending_range.py", "5\n4\n3\n2\n1\n"),
]


@pytest.mark.parametrize("file, golden", CASES)
def test_roundtrip(file, golden):
    source = read_source(file)

    # (1) Native Python — establishes the reference and confirms the golden.
    native = run_native(file)
    assert native == golden, f"native Python output {native!r} != golden {golden!r}"

    # (2) Python → Ball → (compile + run) must equal the native output.
    ball = run_ball(source)
    assert ball == native, f"round-trip mismatch: native {native!r} != ball {ball!r}"
