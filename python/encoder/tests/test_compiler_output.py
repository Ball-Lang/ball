"""The encoder must read back what ``python/compiler`` EMITS (issue #642).

Before this, the compiler's own output tripped two refusals at once — the
unconditional ``try``/``except ballrt.BallReturn`` wrapper around every function
body, and every ``ballrt.*`` base-call helper — so not one of the conformance
fixtures could survive Ball → Python → Ball, and the ``python-roundtrip`` matrix
row measured a flat 0 while reporting the harness healthy.

The whole-corpus proof is that row (``python/engine/conformance/roundtrip.py``,
floored and ratcheted in ``conformance-matrix.yml``). These are the fast,
in-package guards on the SHAPE, so a regression is a failing ``pytest`` rather
than a matrix row nobody ran.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from ball_compiler.compiler import compile_program
from ball_encoder.encoder import EncodeError, encode

ROOT = Path(__file__).resolve().parents[3]
FIXTURES = ROOT / "tests" / "conformance"


def _compile_fixture(name: str) -> str:
    path = FIXTURES / f"{name}.ball.json"
    program = json.loads(path.read_text(encoding="utf-8"))
    program.pop("@type", None)
    return compile_program(program)


def test_compiler_emits_no_dead_return_wrapper() -> None:
    """A body that cannot raise ``BallReturn`` gets no ``try``/``except``.

    The wrapper used to be emitted around EVERY function, and ``try`` is exactly
    what the syntactic ``ast`` encoder refuses.
    """
    source = _compile_fixture("265_enc_hello")
    assert "try:" not in source, source
    assert "BallReturn" not in source, source


def test_compiler_keeps_the_wrapper_when_the_body_can_return() -> None:
    """The elision is conservative: a body that DOES raise keeps its handler.

    Dropping it would turn a `std.return` into an uncaught exception — the
    failure mode the conditional emission must never introduce.
    """
    source = _compile_fixture("45_for_in_loop")
    if "ballrt.ret(" in source:
        assert "except ballrt.BallReturn" in source, source


def test_encode_compiler_output() -> None:
    """The compiler's own hello-world re-encodes into a runnable Program."""
    source = _compile_fixture("265_enc_hello")
    program = encode(source)

    assert program["entryFunction"] == "main"
    std = next(m for m in program["modules"] if m["name"] == "std")
    assert any(f["name"] == "print" for f in std["functions"]), (
        "ballrt.print_ was not recognised as std.print"
    )


def test_unknown_runtime_helper_fails_loud() -> None:
    """A ``ballrt.*`` helper with no universal std inverse is an error.

    Never a silently dropped or guessed-at call (issue #55 doctrine).
    """
    with pytest.raises(EncodeError) as excinfo:
        encode("import ballrt\n\ndef main(_input=None):\n    return ballrt.no_such_helper(1)\n")
    assert "unsupported runtime helper" in str(excinfo.value)


def test_runtime_helper_arity_is_checked() -> None:
    """A mapped helper called with the wrong arity is an error, not a base call
    with missing input fields."""
    with pytest.raises(EncodeError) as excinfo:
        encode("import ballrt\n\ndef main(_input=None):\n    return ballrt.add(1)\n")
    assert "expects 2 argument(s)" in str(excinfo.value)
