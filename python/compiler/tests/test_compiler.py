"""Compiler unit tests: emitted-code shape, lazy control flow, and fail-loud."""

from __future__ import annotations

import pytest

from ball_compiler import CompileError, compile_program, load_program

from conftest import run_source


def _program(body: dict, extra_functions=None, modules_extra=None) -> dict:
    """A minimal single-function program (module ``main``, entry ``main``)."""
    main_fns = [{"name": "main", "body": body, "metadata": {"kind": "function"}}]
    main_fns += extra_functions or []
    modules = [
        {"name": "std", "functions": [{"name": "print", "isBase": True},
                                      {"name": "add", "isBase": True}]},
        {"name": "main", "functions": main_fns},
    ]
    modules += modules_extra or []
    return {"name": "t", "version": "1", "entryModule": "main",
            "entryFunction": "main", "modules": modules}


def _print(msg_expr: dict) -> dict:
    return {"call": {"module": "std", "function": "print",
                     "input": {"messageCreation": {"typeName": "PrintInput",
                                                   "fields": [{"name": "message", "value": msg_expr}]}}}}


def _lit_str(s):
    return {"literal": {"stringValue": s}}


# ── Emitted-shape checks ─────────────────────────────────────────────────────

def test_while_lowers_to_native_python_loop(conformance_dir):
    src = compile_program(load_program(conformance_dir / "46_while_loop.ball.json"))
    assert "while True:" in src
    assert "ballrt.print_" in src


def test_class_emits_real_python_class(conformance_dir):
    src = compile_program(load_program(conformance_dir / "101_simple_class.ball.json"))
    assert "class Point:" in src
    assert "def __init__(self, x, y):" in src
    assert "def describe(self, _input=None):" in src
    assert 'ballrt.setfield(p2, "x", 5)' in src


def test_short_circuit_and_is_native(conformance_dir):
    src = compile_program(load_program(conformance_dir / "52_max_of_three.ball.json"))
    # && must be Python `and` (short-circuit), not a runtime call over both sides.
    assert " and " in src


def test_break_continue_use_flow_signals(conformance_dir):
    src = compile_program(load_program(conformance_dir / "48_break_continue.ball.json"))
    assert "BallBreak" in src and "BallContinue" in src


def test_simple_program_runs():
    prog = _program({"block": {"statements": [
        {"expression": _print(_lit_str("hi"))},
    ]}})
    assert run_source(compile_program(prog)) == "hi\n"


# ── switch_expr null arms (issue #470) ───────────────────────────────────────

def _switch_case(value_expr: dict, body: dict) -> dict:
    return {"messageCreation": {"typeName": "SwitchCase", "fields": [
        {"name": "value", "value": value_expr},
        {"name": "is_default", "value": {"literal": {"boolValue": False}}},
        {"name": "body", "value": body},
    ]}}


def _switch_default(body: dict) -> dict:
    return {"messageCreation": {"typeName": "SwitchCase", "fields": [
        {"name": "is_default", "value": {"literal": {"boolValue": True}}},
        {"name": "body", "value": body},
    ]}}


def _switch_expr(subject: dict, cases: list[dict]) -> dict:
    return {"call": {"module": "std", "function": "switch_expr", "input": {
        "messageCreation": {"fields": [
            {"name": "subject", "value": subject},
            {"name": "cases", "value": {"literal": {"listValue": {"elements": cases}}}},
        ]}}}}


def test_switch_expr_null_arm_is_not_dropped():
    """A ``switch_expr`` arm whose whole body is the bare ``null`` literal is a
    real arm carrying ``None`` — never a body-less fall-through label.

    Ball encodes ``null`` as a value-less ``Literal`` (``{"literal": {}}``),
    exactly the shape ``is_empty_switch_body`` reads as "empty". Applied in
    expression mode (where nothing falls through) the heuristic deletes the arm
    and leaks its condition into the next one, so subject ``2`` answers with the
    DEFAULT arm's value instead of its own ``null`` (issue #470; Go gates the
    same heuristic on statement mode)."""
    body = {"block": {"statements": [
        {"expression": _print(_switch_expr({"literal": {"intValue": 2}}, [
            _switch_case({"literal": {"intValue": 1}}, _lit_str("one")),
            _switch_case({"literal": {"intValue": 2}}, {"literal": {}}),
            _switch_default(_lit_str("other")),
        ]))},
    ]}}
    assert run_source(compile_program(_program(body))) == "null\n"


# ── Fail-loud (issue #55) ────────────────────────────────────────────────────

def test_unsupported_base_function_fails_loud():
    body = {"block": {"statements": [{"expression": {"call": {
        "module": "std", "function": "frobnicate",
        "input": {"messageCreation": {"fields": [{"name": "value", "value": _lit_str("x")}]}}}}}]}}
    with pytest.raises(CompileError):
        compile_program(_program(body))


def test_unresolved_reference_fails_loud():
    body = {"block": {"statements": [{"expression": _print({"reference": {"name": "nope"}})}]}}
    with pytest.raises(CompileError):
        compile_program(_program(body))


def test_unknown_call_target_fails_loud():
    body = {"block": {"statements": [{"expression": {"call": {
        "function": "doesNotExist", "input": _lit_str("x")}}}]}}
    with pytest.raises(CompileError):
        compile_program(_program(body))


def test_missing_entry_fails_loud():
    prog = _program({"block": {}})
    prog["entryFunction"] = "ghost"
    with pytest.raises(CompileError):
        compile_program(prog)


# ── Named-constructor call resolution (issue #527) ───────────────────────────

def _class_program(type_defs, members, body):
    """A program with `main`'s body plus a class (typeDefs + member functions)."""
    prog = _program(body)
    prog["modules"][1]["typeDefs"] = type_defs
    prog["modules"][1]["functions"].extend(members)
    return prog


def test_named_ctor_call_on_class_reference_resolves(conformance_dir):
    """``Class.name(args)`` — a call whose packed ``self`` field is a bare
    reference to a ``TypeDefinition`` short name — resolves to the class's named
    constructor and records NO compiler error.

    Before the fix ``value_call`` eagerly evaluated the raw ``self`` field
    through ``reference()``, whose fail-loud path appended ``unresolved
    reference 'Countdown'`` for every such call site and failed the whole
    compile — even though the class-static branch that actually fires never uses
    that value."""
    src = compile_program(load_program(conformance_dir / "436_recursive_ctor_named.ball.json"))
    assert "Countdown.b_from(" in src
    assert "Countdown.pair(" in src


def test_named_ctor_dispatch_does_not_beat_a_shadowing_local():
    """A local binding whose name matches a class short name still wins — the
    call is a dispatch on that local's *value*, never a class-static call.

    (A regression guard for the lazy-``self_expr`` refactor rather than a
    red-before-fix case: Python's ``sr in self.type_defs and not
    self.lookup(sr)`` guard is the reference the other three compilers copy.)"""
    type_defs = [{
        "descriptor": {"name": "main:Countdown",
                       "field": [{"name": "value", "number": 1, "type": "TYPE_INT64"}]},
        "metadata": {"kind": "class", "fields": [{"name": "value"}]},
    }]
    body = {"block": {"statements": [
        {"let": {"name": "Countdown", "value": _lit_str("ab")}},
        {"expression": _print({"call": {"function": "contains", "input": {"messageCreation": {
            "fields": [{"name": "self", "value": {"reference": {"name": "Countdown"}}},
                       {"name": "arg0", "value": _lit_str("a")}]}}}})},
    ]}}
    src = compile_program(_class_program(type_defs, [], body))
    # The shadowing local's value is dispatched on; no `Countdown.contains`
    # class-static call is emitted (there is no such classmethod).
    assert 'ballrt.call_method(Countdown, "contains", "a")' in src
    assert run_source(src) == "true\n"


def test_ctor_initializer_list_is_applied_when_the_ctor_has_a_body(conformance_dir):
    """A constructor's ``metadata.initializers`` must run before its body, on the
    unnamed (``messageCreation``) path AND on every named-constructor path."""
    src = compile_program(
        load_program(conformance_dir / "438_ctor_initializer_list_with_body.ball.json"))
    assert 'self.label = "pt"' in src        # unnamed ctor
    assert 'self.label = "origin"' in src    # named ctor, no params
    assert 'self.label = "axis"' in src      # named ctor with a `this.` param
    assert 'self.label = "constants"' in src
    assert "self.on = True" in src
    assert "self.ratio = 0.5" in src
    assert "self.y = -3" in src
