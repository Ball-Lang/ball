"""Typed `on T catch` clause dispatch (issue #724).

Three properties, each pinned on BOTH the emitted shape and the observable
behaviour of the running program:

1. the FIRST typed clause matching the thrown value's type runs,
2. a typed clause that MISSES falls through to the next clause (typed or the
   untyped fallback), and
3. a clause list where EVERY clause is typed and none matches re-raises the
   ORIGINAL value, so an enclosing `try` catches it.

Before the fix `run_try` compiled `catches[0]` alone, as an unconditional
catch-all, and dropped every later clause: each case below printed the FIRST
clause's body regardless of what was thrown, and case 3 caught instead of
propagating. That is silently-wrong output, never an error.

The matching rule itself is the reference engine's (`_evalLazyTry` in
`dart/engine/lib/engine_control_flow.dart`): a thrown value's type tag may be
module-qualified (`main:StateError`) while the clause names the bare type, so
BOTH spellings match — the same rule `ballrt.CatchMatches` (Go) and
`ball_catch_matches` (Rust) implement for #615.
"""

from __future__ import annotations

import pytest

import ballrt
from ball_compiler import compile_program

from conftest import run_source


# ── program builders ─────────────────────────────────────────────────────────

def _lit(s: str) -> dict:
    return {"literal": {"stringValue": s}}


def _print(msg_expr: dict) -> dict:
    return {"call": {"module": "std", "function": "print",
                     "input": {"messageCreation": {"typeName": "PrintInput", "fields": [
                         {"name": "message", "value": msg_expr}]}}}}


def _throw(type_name: str, message: str) -> dict:
    """`throw <TypeName>('<message>')` — the encoder's shape for a literal throw
    of a built-in Dart error: a `messageCreation` with no `TypeDefinition`,
    whose single positional constructor argument is keyed `arg0`."""
    return {"call": {"module": "std", "function": "throw",
                     "input": {"messageCreation": {"typeName": "", "fields": [
                         {"name": "value", "value": {"messageCreation": {
                             "typeName": type_name,
                             "fields": [{"name": "arg0", "value": _lit(message)}]}}}]}}}}


def _catch(body: dict, *, type_name: str | None = None, variable: str | None = None) -> dict:
    fields = []
    if type_name is not None:
        fields.append({"name": "type", "value": _lit(type_name)})
    if variable is not None:
        fields.append({"name": "variable", "value": _lit(variable)})
    fields.append({"name": "body", "value": body})
    return {"messageCreation": {"fields": fields}}


def _try(body: dict, catches: list) -> dict:
    return {"call": {"module": "std", "function": "try",
                     "input": {"messageCreation": {"typeName": "", "fields": [
                         {"name": "body", "value": body},
                         {"name": "catches", "value": {"literal": {"listValue": {
                             "elements": catches}}}}]}}}}


def _program(body: dict) -> dict:
    return {"name": "t", "version": "1", "entryModule": "main", "entryFunction": "main",
            "modules": [
                {"name": "std", "functions": [{"name": "print", "isBase": True},
                                              {"name": "throw", "isBase": True},
                                              {"name": "concat", "isBase": True},
                                              {"name": "try", "isBase": True}]},
                {"name": "main", "functions": [
                    {"name": "main", "body": body, "metadata": {"kind": "function"}}]}]}


# ── the runtime's matching rule ──────────────────────────────────────────────

def test_catch_matches_is_the_reference_engines_rule():
    thrown = ballrt.make_format_exception("bad")
    assert ballrt.catch_matches(thrown, "FormatException")
    assert not ballrt.catch_matches(thrown, "StateError")

    # A `__type__`-tagged map is the self-hosted engine's object shape; the tag
    # may be module-qualified while the clause names the bare type.
    tagged = {"__type__": "main:StateError", "message": "boom"}
    assert ballrt.catch_matches(tagged, "StateError")
    assert ballrt.catch_matches(tagged, "main:StateError")
    assert not ballrt.catch_matches(tagged, "other:StateError")
    assert not ballrt.catch_matches(tagged, "ArgumentError")

    # An untagged payload (a thrown string / number / list / bare map) reports
    # std.throw's own default type, `Exception` — engine_std.dart's `throw`.
    for untagged in ("oops", 7, [1, 2], {"message": "x"}, None):
        assert ballrt.catch_matches(untagged, "Exception")
        assert not ballrt.catch_matches(untagged, "StateError")


# ── the three dispatch cases ─────────────────────────────────────────────────

def test_first_typed_clause_matches():
    prog = _program(_try(
        _throw("main:StateError", "boom"),
        [_catch(_print(_lit("first")), type_name="StateError"),
         _catch(_print(_lit("second")), type_name="FormatException"),
         _catch(_print(_lit("fallback")))]))
    src = compile_program(prog)
    assert 'ballrt.catch_matches(_ex.value, "StateError")' in src
    assert 'ballrt.catch_matches(_ex.value, "FormatException")' in src
    assert run_source(src) == "first\n"


def test_first_typed_clause_misses_and_a_later_one_matches():
    prog = _program(_try(
        _throw("main:FormatException", "bad"),
        [_catch(_print(_lit("first")), type_name="StateError"),
         _catch(_print(_lit("second")), type_name="FormatException"),
         _catch(_print(_lit("fallback")))]))
    assert run_source(compile_program(prog)) == "second\n"


def test_no_typed_clause_matches_falls_through_to_the_untyped_catch():
    prog = _program(_try(
        _throw("main:ArgumentError", "nope"),
        [_catch(_print(_lit("first")), type_name="StateError"),
         _catch(_print(_lit("second")), type_name="FormatException"),
         _catch(_print(_lit("fallback")))]))
    assert run_source(compile_program(prog)) == "fallback\n"


def test_every_typed_clause_missing_reraises_the_original_value():
    """No untyped clause: the throw propagates to the ENCLOSING try, which must
    see the ORIGINAL value (the inner clause bodies must not have run)."""
    inner = _try(
        _throw("main:FormatException", "unmatched"),
        [_catch(_print(_lit("inner-wrong-state")), type_name="StateError"),
         _catch(_print(_lit("inner-wrong-argument")), type_name="ArgumentError")])
    outer = _try(inner, [_catch(_print({"call": {
        "module": "std", "function": "concat",
        "input": {"messageCreation": {"typeName": "", "fields": [
            {"name": "left", "value": _lit("outer: ")},
            {"name": "right", "value": {"reference": {"name": "e"}}}]}}}}),
        variable="e")])
    src = compile_program(_program(outer))
    assert run_source(src) == "outer: FormatException: unmatched\n"


def test_an_unmatched_typed_clause_list_leaves_the_throw_uncaught():
    """Nothing catches it: the BallThrow escapes the program rather than being
    swallowed by a clause whose type does not match."""
    prog = _program(_try(
        _throw("main:FormatException", "unmatched"),
        [_catch(_print(_lit("wrong")), type_name="StateError")]))
    with pytest.raises(ballrt.BallThrow):
        run_source(compile_program(prog))
