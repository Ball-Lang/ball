"""The Ball -> Python -> Ball round trip, per `ballrt.*` shape (issue #690).

``test_compiler_output.py`` guards the two things #642 fixed (the dead
``try``/``except`` wrapper, and that SOME ``ballrt.*`` helper is recognised at
all). This module guards the INVENTORY: every helper shape the compiler emits
that has an exact Ball inverse must actually be read back, and a conformance
fixture whose only blocker was that shape must survive the whole loop.

Two kinds of assertion, deliberately:

* **A closed-set drift guard**, derived from the two sources of truth rather
  than from a hand-kept list — ``dart/shared/std.json`` (the canonical
  base-function inventory) crossed with ``python/runtime``'s public helpers. A
  new same-spelled unary base function fails this test on the day it lands,
  instead of silently becoming another ``unsupported runtime helper`` on a
  measurement row nobody reads.
* **Whole-fixture round trips**: Ball fixture -> Python (``python/compiler``) ->
  Ball (``python/encoder``) -> Python -> run, byte-compared against the
  fixture's own golden. One fixture per shape this PR adds; each was an
  ``encode-error`` before it.

The whole-corpus number lives in the ``python-roundtrip`` row of
``conformance-matrix.yml`` (floored + ratcheted). These are the fast, in-package
guards, so a regression is a failing ``pytest`` and not just a moved floor.
"""

from __future__ import annotations

import ast
import importlib.util
import io
import json
import re
import sys
from contextlib import redirect_stdout
from pathlib import Path

import ballrt
import pytest
from ball_compiler.compiler import compile_program
from ball_encoder import ballrt_calls as rt
from ball_encoder.encoder import encode

ROOT = Path(__file__).resolve().parents[3]
FIXTURES = ROOT / "tests" / "conformance"
STD_JSON = ROOT / "dart" / "shared" / "std.json"


def _unary_std_base_functions() -> set[str]:
    """Every ``std`` base function declared with a ``UnaryInput`` — i.e. whose
    single argument is the input field ``value``.

    Read from ``dart/shared/std.json``, the canonical inventory, never from a
    list kept here."""
    std = json.loads(STD_JSON.read_text(encoding="utf-8"))
    return {f["name"] for f in std["functions"] if f.get("inputType") == "UnaryInput"}


def _runtime_helpers() -> set[str]:
    """Every public callable ``python/runtime`` exposes as ``ballrt.<name>``."""
    return {n for n in dir(ballrt) if not n.startswith("_") and callable(getattr(ballrt, n))}


def test_same_spelled_unary_helpers_all_have_an_inverse() -> None:
    """A closed set: `std.<f>` takes a `UnaryInput` and `ballrt` spells the
    helper the same way => `HELPERS` must map it to `(<f>, ("value",))`.

    This is the whole `math_*` family and the unary string family. Derived from
    std.json + the runtime module, so it closes over what the compiler CAN emit
    rather than over what today's fixtures happen to use.
    """
    same_spelled = sorted(_unary_std_base_functions() & _runtime_helpers())
    assert len(same_spelled) >= 30, (
        f"only {len(same_spelled)} same-spelled unary helpers found — the "
        "derivation broke, it is not that the runtime shrank"
    )
    missing = [n for n in same_spelled if n not in rt.HELPERS]
    assert not missing, (
        "these unary std base functions have an identically named ballrt helper "
        f"but no inverse in ball_encoder/ballrt_calls.py: {missing}"
    )
    wrong = {n: rt.HELPERS[n] for n in same_spelled if rt.HELPERS[n] != (n, ("value",))}
    assert not wrong, (
        f"a same-spelled unary helper must map to itself over the `value` field: {wrong}"
    )


def _compile_fixture(name: str) -> str:
    path = FIXTURES / f"{name}.ball.json"
    program = json.loads(path.read_text(encoding="utf-8"))
    program.pop("@type", None)
    return compile_program(program)


def _golden(name: str) -> str:
    """The fixture's expected stdout, read as BYTES with only CRLF normalised —
    text mode would collapse a semantic lone ``\\r`` on both sides."""
    raw = (FIXTURES / f"{name}.expected_output.txt").read_bytes()
    return raw.decode("utf-8").replace("\r\n", "\n")


def _run_source(source: str) -> str:
    """Execute compiled Python in-process, returning its stdout."""
    module = importlib.util.module_from_spec(
        importlib.util.spec_from_loader("<ball_roundtrip>", loader=None)
    )
    exec(compile(source, "<ball_roundtrip>", "exec"), module.__dict__)
    match = re.search(r"ballrt\.run_entry\((\w+)\)", source)
    entry = module.__dict__.get(match.group(1)) if match else module.__dict__.get("main")
    assert entry is not None, "compiled program declares no entry function"
    buf = io.StringIO()
    try:
        with redirect_stdout(buf):
            ballrt.run_entry(entry)
    except SystemExit:
        pass
    return buf.getvalue()


def _round_trip(name: str) -> str:
    """Ball fixture -> Python -> Ball -> Python -> stdout."""
    return _run_source(compile_program(encode(_compile_fixture(name))))


# One fixture per `ballrt.*` shape this inverse covers. Each was an
# `encode-error` on the `python-roundtrip` row before it; the assertion is the
# fixture's own golden, so a mapping onto the WRONG base function fails here
# rather than passing on shape alone.
ROUND_TRIP_FIXTURES = [
    # ballrt.math_floor / math_ceil / math_round / math_trunc / math_abs
    "259_math_functions",
    # ballrt.round_to_double / floor_to_double / ceil_to_double / truncate_to_double
    "351_num_to_double",
    # ballrt.string_to_upper / string_to_lower / string_trim + ballrt.getfield
    "26_string_ops",
    # ballrt.is_type, via `is` and `is!`
    "380_is_not_type_check",
    # ballrt.getfield on a user object's field
    "262_getter_properties",
]


@pytest.mark.parametrize("name", ROUND_TRIP_FIXTURES)
def test_fixture_round_trips_through_the_python_encoder(name: str) -> None:
    assert _round_trip(name) == _golden(name)


# ── The shapes that are not one std call over expression arguments ───────────
# Each is asserted on its own, because no single fixture isolates it.

def _encode_body(body: str) -> dict:
    """Encode a one-function program and return its `main` body."""
    program = encode(f"import ballrt\n\ndef main(_input=None):\n{body}")
    main = next(f for m in program["modules"] for f in m.get("functions", [])
                if f.get("name") == "main")
    return main["body"]


def _statements(body: dict) -> list[dict]:
    return body["block"]["statements"]


def test_getfield_encodes_to_a_field_access_not_a_call() -> None:
    """`ballrt.getfield(o, "x")` is the emission of a fieldAccess EXPRESSION —
    Ball has a node for it, so encoding it as a `std` call would be a different
    program."""
    body = _encode_body('    ballrt.print_(ballrt.getfield(_input, "x"))\n')
    printed = _statements(body)[-1]["expression"]["call"]["input"]
    fields = printed["messageCreation"]["fields"]
    message = next(f for f in fields if f["name"] == "message")["value"]
    assert "fieldAccess" in message, message
    assert message["fieldAccess"]["field"] == "x"


def test_setfield_encodes_to_an_assign_onto_a_field_access() -> None:
    body = _encode_body('    ballrt.setfield(_input, "x", 1)\n')
    call = _statements(body)[-1]["expression"]["call"]
    assert (call["module"], call["function"]) == ("std", "assign")
    fields = call["input"]["messageCreation"]["fields"]
    target = next(f for f in fields if f["name"] == "target")["value"]
    assert target["fieldAccess"]["field"] == "x"


def test_index_set_encodes_to_an_assign_onto_an_index_call() -> None:
    body = _encode_body('    ballrt.index_set(_input, "k", 1)\n')
    call = _statements(body)[-1]["expression"]["call"]
    assert (call["module"], call["function"]) == ("std", "assign")
    fields = call["input"]["messageCreation"]["fields"]
    target = next(f for f in fields if f["name"] == "target")["value"]
    assert (target["call"]["module"], target["call"]["function"]) == ("std", "index")


def test_type_ops_carry_the_type_name_as_a_string_field() -> None:
    for helper, fn in (("is_type", "is"), ("as_type", "as")):
        body = _encode_body(f'    ballrt.print_(ballrt.{helper}(_input, "int"))\n')
        printed = _statements(body)[-1]["expression"]["call"]["input"]
        message = next(f for f in printed["messageCreation"]["fields"]
                       if f["name"] == "message")["value"]
        call = message["call"]
        assert (call["module"], call["function"]) == ("std", fn)
        type_field = next(f for f in call["input"]["messageCreation"]["fields"]
                          if f["name"] == "type")["value"]
        assert type_field["literal"]["stringValue"] == "int"


def test_iterate_is_the_for_in_iterable_itself() -> None:
    """`for x in ballrt.iterate(xs)` is the compiler's `std.for_in` lowering —
    the adapter has no Ball spelling, so the loop's iterable is `xs`."""
    body = _encode_body(
        "    for item in ballrt.iterate(_input):\n        ballrt.print_(item)\n"
    )
    call = _statements(body)[-1]["expression"]["call"]
    assert (call["module"], call["function"]) == ("std", "for_in")
    iterable = next(f for f in call["input"]["messageCreation"]["fields"]
                    if f["name"] == "iterable")["value"]
    assert iterable["reference"]["name"] == "_input", iterable


def test_a_computed_field_name_fails_loud() -> None:
    """A non-literal name operand is a shape this encoder cannot represent —
    never a guessed-at field (issue #55 doctrine)."""
    from ball_encoder.encoder import EncodeError

    with pytest.raises(EncodeError) as excinfo:
        encode('import ballrt\n\ndef main(_input=None):\n'
               '    return ballrt.getfield(_input, _input)\n')
    assert "needs a literal field name" in str(excinfo.value)


def _unary_call_of(helper: str) -> dict:
    """Encode `ballrt.print_(ballrt.<helper>(_input))` and return the printed
    argument's `call`, so the assertion is on the Ball node the encoder REALLY
    produced rather than on the lookup table it was supposed to consult."""
    body = _encode_body(f"    ballrt.print_(ballrt.{helper}(_input))\n")
    printed = _statements(body)[-1]["expression"]["call"]["input"]
    message = next(f for f in printed["messageCreation"]["fields"]
                   if f["name"] == "message")["value"]
    return message["call"]


def test_every_same_spelled_unary_helper_encodes_to_its_own_base_function() -> None:
    """The behavioural half of the closed set: for EVERY same-spelled unary
    helper, `encode()` must emit `std.<helper>` with the operand under `value`.

    `test_same_spelled_unary_helpers_all_have_an_inverse` reads the HELPERS
    dict; this runs the encoder. The two differ exactly where a future
    "simplification" would land — an explicit arm ahead of the generic one that
    rewrites a helper into an equivalent-looking composition (the `isNotEmpty`
    -> `not isEmpty` shape of issue #674) leaves the dict untouched and is
    invisible to the table test, and agrees with every golden whose program
    only observes the boolean. Derived from std.json x the runtime module, so a
    unary base function added tomorrow is covered the day it lands.
    """
    same_spelled = sorted(_unary_std_base_functions() & _runtime_helpers())
    assert len(same_spelled) >= 30, (
        f"only {len(same_spelled)} same-spelled unary helpers found - the "
        "derivation broke, it is not that the runtime shrank"
    )
    wrong: dict[str, object] = {}
    for helper in same_spelled:
        call = _unary_call_of(helper)
        if (call["module"], call["function"]) != ("std", helper):
            wrong[helper] = f'{call["module"]}.{call["function"]}'
            continue
        operand = next((f for f in call["input"]["messageCreation"]["fields"]
                        if f["name"] == "value"), None)
        if operand is None or operand["value"].get("reference", {}).get("name") != "_input":
            wrong[helper] = f"operand is not the bare argument under `value`: {operand}"
    assert not wrong, (
        "these helpers did not encode to their own std base function over "
        f"`value`: {wrong}"
    )


def test_string_is_not_empty_is_its_own_base_function() -> None:
    """`ballrt.string_is_not_empty(v)` reads back as `std.string_is_not_empty`,
    never as `std.not` over `std.string_is_empty`.

    The two are distinct base functions on purpose (issue #674): a delegating
    receiver sees WHICH member it was asked for, so re-encoding the negation
    would be a different program that happens to agree on `String`. The closed
    set in `test_same_spelled_unary_helpers_all_have_an_inverse` proves the
    mapping EXISTS; this proves it lands on the right function.
    """
    body = _encode_body('    ballrt.print_(ballrt.string_is_not_empty(_input))\n')
    printed = _statements(body)[-1]["expression"]["call"]["input"]
    message = next(f for f in printed["messageCreation"]["fields"]
                   if f["name"] == "message")["value"]
    call = message["call"]
    assert (call["module"], call["function"]) == ("std", "string_is_not_empty"), call
    operand = next(f for f in call["input"]["messageCreation"]["fields"]
                   if f["name"] == "value")["value"]
    assert operand["reference"]["name"] == "_input", operand


def test_the_non_table_shapes_are_not_also_in_helpers() -> None:
    """One shape, one home: a helper handled explicitly must not also sit in
    HELPERS, where the generic arm would encode it as a plain std call."""
    explicit = set(rt.PASSTHROUGH) | {rt.FIELD_GET, rt.FIELD_SET, rt.INDEX_SET} | set(rt.TYPE_OPS)
    overlap = sorted(explicit & set(rt.HELPERS))
    assert not overlap, overlap


def test_unparse_of_the_compiler_output_is_what_we_claim() -> None:
    """Sanity: the fixtures above really do go through these helpers, so a test
    passing for some other reason is visible."""
    source = _compile_fixture("259_math_functions")
    helpers = {node.func.attr for node in ast.walk(ast.parse(source))
               if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
               and isinstance(node.func.value, ast.Name) and node.func.value.id == "ballrt"}
    assert {"math_floor", "math_ceil", "math_round", "math_trunc", "math_abs"} <= helpers


if __name__ == "__main__":  # pragma: no cover - convenience
    sys.exit(pytest.main([__file__]))
