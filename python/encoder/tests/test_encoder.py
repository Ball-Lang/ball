"""Structural encoder tests: Program shape, the one-input convention, base-module
accumulation, the universal-`std`-only invariant, and fail-loud behaviour.

These assert on the emitted Ball dict directly (the round-trip suite proves
behaviour); together they pin both *what* is emitted and *that it runs*.
"""

from __future__ import annotations

import pytest

from ball_encoder import EncodeError, encode


# ── helpers ──────────────────────────────────────────────────────────────────

def module(prog: dict, name: str) -> dict:
    return next(m for m in prog["modules"] if m["name"] == name)


def func(prog: dict, name: str) -> dict:
    return next(f for f in module(prog, "main")["functions"] if f["name"] == name)


def module_names(prog: dict) -> set[str]:
    return {m["name"] for m in prog["modules"]}


def walk_calls(expr, out: list[dict]):
    if not isinstance(expr, dict):
        return
    if "call" in expr:
        out.append(expr["call"])
        walk_calls(expr["call"].get("input"), out)
    elif "literal" in expr:
        lv = expr["literal"].get("listValue")
        if lv:
            for el in lv.get("elements", []):
                walk_calls(el, out)
    elif "fieldAccess" in expr:
        walk_calls(expr["fieldAccess"].get("object"), out)
    elif "messageCreation" in expr:
        for fv in expr["messageCreation"].get("fields", []):
            walk_calls(fv.get("value"), out)
    elif "block" in expr:
        for st in expr["block"].get("statements", []):
            walk_calls(st.get("let", {}).get("value") if "let" in st else st.get("expression"), out)
        if expr["block"].get("result") is not None:
            walk_calls(expr["block"]["result"], out)
    elif "lambda" in expr:
        walk_calls(expr["lambda"].get("body"), out)


def all_calls(prog: dict) -> list[dict]:
    out: list[dict] = []
    for m in prog["modules"]:
        for f in m.get("functions", []):
            walk_calls(f.get("body"), out)
    return out


# ── Program shape ────────────────────────────────────────────────────────────

def test_program_has_main_entry():
    prog = encode('print("hi")')
    assert prog["entryModule"] == "main"
    assert prog["entryFunction"] == "main"
    assert func(prog, "main")["metadata"]["kind"] == "function"


def test_synthesises_main_from_toplevel_statements():
    prog = encode("x = 1\nprint(x)")
    body = func(prog, "main")["body"]["block"]
    # `x` is hoisted (let x = null) then assigned; two ways to bind, one name.
    assert body["statements"][0]["let"]["name"] == "x"


def test_uses_explicit_main_def_when_present():
    prog = encode("def main():\n    print(1)")
    assert func(prog, "main")["metadata"]["kind"] == "function"


def test_std_is_a_base_module():
    prog = encode('print("hi")')
    std = module(prog, "std")
    assert std["functions"], "std must declare the used base functions"
    assert all(f["isBase"] for f in std["functions"])
    assert not any("body" in f for f in std["functions"])  # base functions have no body


def test_no_language_specific_std_module():
    # The core invariant: every construct routes through universal std — there is
    # never a python_std base module.
    prog = encode("def add(a, b):\n    return a + b\nprint(add(1, 2))")
    assert "python_std" not in module_names(prog)
    for c in all_calls(prog):
        assert c.get("module") in ("", "std", "std_collections"), c


# ── One input, one output (invariant #1) ─────────────────────────────────────

def test_zero_param_function_has_no_input_type():
    prog = encode("def greet():\n    print(1)\ngreet()")
    greet = func(prog, "greet")
    assert "inputType" not in greet
    assert "params" not in greet["metadata"]


def test_single_param_keeps_its_name():
    prog = encode("def square(x):\n    return x * x\nprint(square(4))")
    square = func(prog, "square")
    assert square["metadata"]["params"] == [{"name": "x"}]
    assert square.get("inputType")  # single-param carries a (cosmetic) input type


def test_two_param_call_packs_message_by_param_names():
    prog = encode("def add(a, b):\n    return a + b\nprint(add(2, 3))")
    add = func(prog, "add")
    assert add["metadata"]["params"] == [{"name": "a"}, {"name": "b"}]
    assert "inputType" not in add  # 2+ params take one packed message, not a typed input
    # The call site packs its arguments keyed by the callee's real parameter names.
    user_calls = [c for c in all_calls(prog) if c.get("module") == "" and c["function"] == "add"]
    assert len(user_calls) == 1
    fields = user_calls[0]["input"]["messageCreation"]["fields"]
    assert [f["name"] for f in fields] == ["a", "b"]


# ── Base-function accumulation ───────────────────────────────────────────────

def test_only_used_base_functions_are_declared():
    prog = encode("print(1 + 2)")
    declared = {f["name"] for f in module(prog, "std")["functions"]}
    assert "add" in declared and "print" in declared
    assert "subtract" not in declared  # never referenced


def test_collections_module_only_when_used():
    prog = encode("print(1 + 2)")
    assert "std_collections" not in module_names(prog)


# ── Operator / control-flow encodings ────────────────────────────────────────

def test_binary_operator_routes_through_std():
    prog = encode("print(1 + 2)")
    fns = {c["function"] for c in all_calls(prog) if c.get("module") == "std"}
    assert "add" in fns


def test_division_is_double_and_floordiv_is_truncating():
    prog = encode("print(7 / 2)\nprint(7 // 2)")
    fns = {c["function"] for c in all_calls(prog) if c.get("module") == "std"}
    assert "divide_double" in fns  # Python `/` is always float
    assert "divide" in fns          # Python `//` maps to truncating divide


def test_if_encodes_as_std_if_with_branches():
    prog = encode("x = 1\nif x > 0:\n    print(1)\nelse:\n    print(2)")
    ifs = [c for c in all_calls(prog) if c.get("module") == "std" and c["function"] == "if"]
    assert ifs, "an if statement encodes to std.if"
    names = {f["name"] for f in ifs[0]["input"]["messageCreation"]["fields"]}
    assert {"condition", "then", "else"} <= names


def test_for_range_encodes_as_std_for():
    prog = encode("for i in range(3):\n    print(i)")
    assert any(c.get("module") == "std" and c["function"] == "for" for c in all_calls(prog))


def test_for_in_list_encodes_as_std_for_in():
    prog = encode("for n in [1, 2]:\n    print(n)")
    assert any(c.get("module") == "std" and c["function"] == "for_in" for c in all_calls(prog))


def test_short_circuit_and_or_stay_std_calls():
    prog = encode("x = 1\ny = 2\nprint(x > 0 and y > 0)")
    fns = {c["function"] for c in all_calls(prog) if c.get("module") == "std"}
    assert "and" in fns


def test_compound_assignment_desugars_to_op_then_assign():
    prog = encode("x = 0\nx += 5\nprint(x)")
    fns = {c["function"] for c in all_calls(prog) if c.get("module") == "std"}
    assert "assign" in fns and "add" in fns


def test_fstring_folds_into_concat():
    prog = encode("x = 5\nprint(f'v={x}')")
    fns = {c["function"] for c in all_calls(prog) if c.get("module") == "std"}
    assert "concat" in fns


def test_nested_def_becomes_lambda_assignment():
    prog = encode(
        "def outer():\n    def inner(x):\n        return x + 1\n    return inner(2)\nprint(outer())")
    calls: list[dict] = []
    walk_calls(func(prog, "outer")["body"], calls)
    # The nested def is assigned (std.assign) a lambda value.
    assert any(c.get("module") == "std" and c["function"] == "assign" for c in calls)


# ── Fail-loud (issue #55) ────────────────────────────────────────────────────

@pytest.mark.parametrize("source", [
    "class C:\n    pass",
    "s = 'x'\nprint(s.upper())",
    "a, b = 1, 2",
    "xs = [i for i in range(3)]",
    "print(3 in [1, 2, 3])",
    "xs = [1, 2, 3]\nprint(xs[0:2])",
    "async def f():\n    pass",
    "try:\n    pass\nexcept Exception:\n    pass",
    "import math\nprint(math.sqrt(4))",
])
def test_unsupported_construct_fails_loud(source):
    with pytest.raises(EncodeError):
        encode(source)


def test_error_accumulates_every_site():
    with pytest.raises(EncodeError) as ei:
        encode("class A:\n    pass\nclass B:\n    pass")
    assert "2 unsupported construct(s)" in str(ei.value)


def test_syntax_error_fails_loud():
    with pytest.raises(EncodeError):
        encode("def f(:\n    pass")
