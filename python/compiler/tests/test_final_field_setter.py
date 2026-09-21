"""A ``final`` field declared next to a user-written setter of the same name
(issue #706, fixture ``472_initializer_list_field_with_setter``).

That pair is legal Dart exactly because a plain ``final`` field contributes a
getter and NOTHING else — so the declared setter is the only setter for the
name, and the field itself is the only getter. Python has ONE namespace for
both: a bare ``@windowSize.setter`` has no property object to decorate
(``NameError``), which is why this compiler refused the shape loudly
("setter without matching getter: FixedSlice.windowSize").

That refusal was honest — never a silent wrong answer, unlike the Rust/Go/C#
mechanism the same issue covers — but a refusal is still a program this target
cannot run that every self-hosted engine runs fine, so it is a gap, not an end
state. The lowering is the C++ compiler's backing-member answer to the same
one-namespace collision (#695, closed by #680): the field moves to a private
backing attribute and a synthesized ``@property`` reads it, so the declared
setter has a property to attach to and every read still resolves to the field.

These run on EVERY PR (``python -m pytest`` in ci.yml's ``python`` job). The
whole-corpus ``python-compiler`` leg that would also have measured this lives
only in conformance-matrix.yml, which has no ``pull_request:`` trigger and is a
RATCHET on an aggregate count — it fails only on a DROP, so it was green with
this fixture failing and stays green now that it passes.
"""

from __future__ import annotations

import pytest

from ball_compiler import CompileError, compile_program, load_program

from conftest import run_source


def _print(msg_expr: dict) -> dict:
    return {"call": {"module": "std", "function": "print",
                     "input": {"messageCreation": {"typeName": "PrintInput",
                                                   "fields": [{"name": "message",
                                                               "value": msg_expr}]}}}}


def test_final_field_with_a_same_named_setter_keeps_its_read_path(conformance_dir):
    src = compile_program(
        load_program(conformance_dir / "472_initializer_list_field_with_setter.ball.json"))
    # The synthesized getter, its backing attribute, and the declared setter
    # attached to it.
    assert "@property" in src
    assert "def windowSize(self):" in src
    assert "return self._ball_backing_windowSize" in src
    assert "@windowSize.setter" in src
    # The constructor must seed the BACKING attribute: `self.windowSize = end`
    # would run the declared setter, which throws.
    assert "self._ball_backing_windowSize = end" in src
    assert "self.windowSize = end" not in src
    # The field READ pin: `print(slice.windowSize)` prints 3, never null.
    assert run_source(src) == "3\n20\n3\n"


def test_setter_without_a_getter_or_a_field_still_fails_loud():
    """The negative control: a setter whose name matches NEITHER a getter NOR a
    declared field of the class has nothing to attach to, and must still be
    refused — never emitted as broken Python."""
    program = {
        "name": "t", "version": "1", "entryModule": "main", "entryFunction": "main",
        "modules": [
            {"name": "std", "functions": [{"name": "print", "isBase": True}]},
            {"name": "main",
             "functions": [
                 {"name": "main", "body": _print({"literal": {"stringValue": "x"}}),
                  "metadata": {"kind": "function"}},
                 {"name": "main:Widget.width",
                  "body": _print({"literal": {"stringValue": "set"}}),
                  "metadata": {"kind": "method", "is_setter": True,
                               "params": [{"name": "value", "type": "int"}]}},
             ],
             "typeDefs": [{"name": "main:Widget",
                           "descriptor": {"name": "main:Widget", "field": []},
                           "metadata": {"kind": "class", "fields": []}}]},
        ],
    }
    with pytest.raises(CompileError, match="setter without matching getter"):
        compile_program(program)
