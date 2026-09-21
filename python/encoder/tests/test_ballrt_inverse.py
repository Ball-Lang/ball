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


# ── The compiler's four `try:` lowerings (issue #690) ────────────────────────
# `python/compiler` emits a Python `try:` for FOUR distinct reasons, and only
# one of them is a Ball `std.try`:
#
#   1. the loop-body break/continue trap (`_loop_body`, `run_forin`),
#   2. the `except ballrt.BallReturn` function-body wrapper (`emit_body`),
#   3. the same wrapper in its value-less constructor form,
#   4. a real `std.try` (`run_try`).
#
# `unsupported statement Try` was the single largest blocker on the
# `python-roundtrip` row — 142 occurrences, the SOLE blocker of 79 fixtures.
# Each test below pins one shape; every fixture here was an `encode-error`
# before this inverse landed.


def _run_bounded(source: str, timeout_s: float = 60.0) -> str:
    """:func:`_run_source` with a hard wall-clock bound.

    Mis-inverting the loop trap does not raise — it produces a program that
    NEVER TERMINATES. Inlining the trap's body into a `std.while` drops the
    C-style `for` update out of `continue`'s path, so `100_complex_control_flow`
    spins forever. A regression must fail this suite, not hang a 90-minute CI
    job, so the run happens on a daemon thread the test stops waiting for.
    """
    import threading

    out: list[str] = []
    err: list[BaseException] = []

    def target() -> None:
        try:
            out.append(_run_source(source))
        except BaseException as ex:  # noqa: BLE001 - re-raised on the main thread
            err.append(ex)

    thread = threading.Thread(target=target, daemon=True)
    thread.start()
    thread.join(timeout_s)
    assert not thread.is_alive(), (
        f"the round-tripped program did not terminate within {timeout_s:g}s — "
        "the classic symptom of a loop trap inlined into a `std.while`, which "
        "drops the C-style `for` update out of `continue`'s path"
    )
    if err:
        raise err[0]
    return out[0]


def _round_trip_bounded(name: str) -> str:
    return _run_bounded(compile_program(encode(_compile_fixture(name))))


# One fixture per `try:` shape, each named with the shape it is here to pin.
TRY_SHAPE_FIXTURES = [
    ("48_break_continue", "the loop-body trap + ballrt.brk()/ballrt.cont()"),
    ("291_enc_continue", "a bare continue inside a for-in loop's trap"),
    ("100_complex_control_flow", "a C-style for's update, which `continue` must still run"),
    ("47_do_while", "the do-while lowering: trap first, the exit guard last"),
    ("69_early_return", "the `except ballrt.BallReturn` wrapper + ballrt.ret()"),
    ("53_try_catch_finally", "a real std.try with one catch and a finally"),
    ("300_enc_catch_stack", "catch (e, st) — the stack_trace variable"),
    ("22_rethrow_preserves", "ballrt.rethrow() inside a catch"),
    ("245_exception_finally_order", "finally ordering across nested try"),
]


@pytest.mark.parametrize(
    "name,shape", TRY_SHAPE_FIXTURES, ids=[n for n, _ in TRY_SHAPE_FIXTURES]
)
def test_try_shape_fixture_round_trips(name: str, shape: str) -> None:
    assert _round_trip_bounded(name) == _golden(name), shape


_FOR_WITH_CONTINUE = '''import ballrt

def main(_input=None):
    i = 0
    total = 0
    while True:
        if not ballrt.truthy(ballrt.less_than(i, 5)):
            break
        try:
            if ballrt.truthy(ballrt.equals(i, 2)):
                ballrt.cont("")
            total = ballrt.add(total, i)
        except ballrt.BallBreak as _brk:
            if _brk.label: raise
            break
        except ballrt.BallContinue as _cnt:
            if _cnt.label: raise
        i = ballrt.add(i, 1)
    ballrt.print_(ballrt.to_str(total))


if __name__ == "__main__":
    ballrt.run_entry(main)
'''


def _main_body(program: dict) -> dict:
    main = next(f for m in program["modules"] for f in m.get("functions", [])
                if f.get("name") == "main")
    return main["body"]


def _call_fields(call: dict) -> dict:
    return {f["name"]: f["value"]
            for f in call.get("input", {}).get("messageCreation", {}).get("fields", [])}


def _only_loop(body: dict) -> dict:
    return next(st["expression"]["call"] for st in _statements(body)
                if "expression" in st and "call" in st["expression"]
                and st["expression"]["call"].get("function") in ("for", "while", "do_while"))


def test_a_c_style_for_keeps_its_update_in_std_for_not_in_the_body() -> None:
    """The compiler's `while True:` + trap + trailing update is a C-style
    `std.for`, NOT a `std.while` whose body ends with the update.

    The two differ exactly on `continue`: `std.for` runs the update on every
    iteration including a continued one (which is what the compiled `except
    ballrt.BallContinue: pass` does — it falls through to the update), while a
    `std.while` skips it and the loop never advances. This is the structural
    guard that keeps that regression from HANGING the suite instead of failing
    it; `test_a_continued_c_style_for_still_advances` is the behavioural half.
    """
    loop = _only_loop(_main_body(encode(_FOR_WITH_CONTINUE)))
    assert (loop["module"], loop["function"]) == ("std", "for"), loop
    fields = _call_fields(loop)
    assert "update" in fields, f"std.for lost its update: {sorted(fields)}"
    update = fields["update"]["call"]
    assert (update["module"], update["function"]) == ("std", "assign"), update


def test_a_continued_c_style_for_still_advances() -> None:
    """0+1+3+4 = 8. An inlined trap makes this loop spin forever."""
    assert _run_bounded(compile_program(encode(_FOR_WITH_CONTINUE))) == "8\n"


def test_catch_binds_its_variable_and_stack_trace_as_catch_fields() -> None:
    """`e = _ex.value` / `st = ballrt.stack_trace_of(_ex)` are the compiler's
    spelling of the catch clause's OWN bindings — they must come back as the
    `variable`/`stack_trace` fields, never as assignments from a `_ex` that has
    no Ball existence at all."""
    body = _main_body(encode(_compile_fixture("300_enc_catch_stack")))
    try_call = next(st["expression"]["call"] for st in _statements(body)
                    if "expression" in st and "call" in st["expression"]
                    and st["expression"]["call"].get("function") == "try")
    catches = _call_fields(try_call)["catches"]["literal"]["listValue"]["elements"]
    assert len(catches) == 1, catches
    clause = {f["name"]: f["value"] for f in catches[0]["messageCreation"]["fields"]}
    assert clause["variable"]["literal"]["stringValue"] == "e", clause
    assert clause["stack_trace"]["literal"]["stringValue"] == "stack", clause
    assert "_ex" not in json.dumps(clause), "the compiler's `_ex` leaked into Ball"


def test_break_and_continue_carry_their_label() -> None:
    """`ballrt.brk(label)` / `ballrt.cont(label)` are `std.break` / `std.continue`;
    the compiler always passes a label string, EMPTY for an unlabelled jump —
    which must encode to no input at all, the shape `dart/encoder` produces."""
    for helper, fn in (("brk", "break"), ("cont", "continue")):
        unlabelled = _encode_body(f'    ballrt.{helper}("")\n')
        call = _statements(unlabelled)[-1]["expression"]["call"]
        assert (call["module"], call["function"]) == ("std", fn), call
        assert "input" not in call, f"an unlabelled {fn} must carry no label: {call}"

        labelled = _encode_body(f'    ballrt.{helper}("outer")\n')
        call = _statements(labelled)[-1]["expression"]["call"]
        assert (call["module"], call["function"]) == ("std", fn), call
        label = _call_fields(call)["label"]
        assert label["literal"]["stringValue"] == "outer", label


def test_ret_and_rethrow_encode_to_their_own_base_functions() -> None:
    ret = _statements(_encode_body("    ballrt.ret(1)\n"))[-1]["expression"]["call"]
    assert (ret["module"], ret["function"]) == ("std", "return"), ret
    assert _call_fields(ret)["value"]["literal"]["intValue"] == "1"

    rethrow = _statements(_encode_body("    ballrt.rethrow()\n"))[-1]["expression"]["call"]
    assert (rethrow["module"], rethrow["function"]) == ("std", "rethrow"), rethrow
    assert "input" not in rethrow, "std.rethrow takes no input"


def test_locals_assigned_inside_a_try_are_hoisted() -> None:
    """A name first assigned inside a `try:` is still a function local.

    The hoist scan drives every `std.assign`; a name it misses is assigned
    without ever being declared, which the engine rejects at run time rather
    than at encode time. Every loop body the compiler emits lives inside a trap,
    so missing this would mis-encode nearly the whole corpus."""
    body = _encode_body(
        "    try:\n"
        "        seen = 1\n"
        "    except ballrt.BallReturn as _r:\n"
        "        return _r.value\n"
    )
    hoisted = [st["let"]["name"] for st in _statements(body) if "let" in st]
    assert "seen" in hoisted, hoisted


def test_an_unrecognised_try_fails_loud() -> None:
    """A `try:` that is none of the compiler's four lowerings has no Ball
    spelling this encoder can produce — it must fail loud, never be dropped or
    silently treated as a bare block (issue #55 doctrine)."""
    from ball_encoder.encoder import EncodeError

    with pytest.raises(EncodeError) as excinfo:
        encode("import ballrt\n\ndef main(_input=None):\n"
               "    try:\n"
               "        ballrt.print_('x')\n"
               "    except ValueError:\n"
               "        ballrt.print_('y')\n")
    assert "try" in str(excinfo.value).lower(), excinfo.value


def test_a_loop_trap_that_is_not_the_last_statement_fails_loud() -> None:
    """Outside the recognised `while True:` lowering, a trap followed by more
    statements cannot be inlined: those statements are a C-style `for`'s update,
    and only `std.for` runs an update on `continue`. Guessing would produce a
    program that silently never terminates, so it fails loud instead."""
    from ball_encoder.encoder import EncodeError

    with pytest.raises(EncodeError) as excinfo:
        encode("import ballrt\n\ndef main(_input=None):\n"
               "    for _t0 in ballrt.iterate(_input):\n"
               "        try:\n"
               "            ballrt.print_(_t0)\n"
               "        except ballrt.BallBreak as _brk:\n"
               "            if _brk.label: raise\n"
               "            break\n"
               "        except ballrt.BallContinue as _cnt:\n"
               "            if _cnt.label: raise\n"
               "        ballrt.print_('after')\n")
    assert "trap" in str(excinfo.value), excinfo.value


def test_the_flow_class_names_are_real_runtime_classes() -> None:
    """A closed-set drift guard over the OTHER source of truth: every exception
    class the recogniser matches on must actually exist in `python/runtime`. A
    rename there turns every recogniser into a silent no-match — every `try:`
    back to `unsupported statement Try` — which only a whole-corpus measurement
    row would otherwise notice."""
    for attr in (rt.FLOW_BREAK, rt.FLOW_CONTINUE, rt.FLOW_RETURN, rt.FLOW_THROW):
        assert isinstance(getattr(ballrt, attr, None), type), (
            f"ballrt.{attr} is not a class — ball_encoder/ballrt_calls.py names "
            "a flow exception python/runtime no longer exports"
        )
    assert callable(getattr(ballrt, rt.STACK_TRACE_OF, None)), rt.STACK_TRACE_OF
    caught = getattr(getattr(ballrt, rt.FLOW_MODULE, None), rt.CAUGHT_STACK, None)
    assert isinstance(caught, list), (
        f"ballrt.{rt.FLOW_MODULE}.{rt.CAUGHT_STACK} is not the rethrow stack the "
        "compiled catch pushes onto"
    )

if __name__ == "__main__":  # pragma: no cover - convenience
    sys.exit(pytest.main([__file__]))
