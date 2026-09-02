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
