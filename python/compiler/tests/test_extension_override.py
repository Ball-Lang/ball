"""Extension-override dispatch (issue #670, fixture
``480_extension_override_selection``).

``Ext(receiver).member`` is encoded as a call NAMING the extension's own member
(``<module>:<Ext>.<member>``) with the receiver in ``self``, because the
selection is the whole meaning of the node: two extensions can declare the SAME
member on the SAME type, and the plain ``receiver.member`` emission resolves by
ordinary lookup — a DIFFERENT member.

Python has no extensions, so this compiler emits each extension as a class and
its members as methods. The call used to route through
``ballrt.call_method(receiver, "main:AlphaTag.tag")``, the Dart-SDK dispatcher,
which asks the RECEIVER — an ordinary ``list`` here, which knows no such method
and, even if it did, could not tell the two extensions apart. The member is
reached UNBOUND on its class instead, with the receiver passed as ``self``; a
getter is a ``property``, reached through ``.fget``.

These run on EVERY PR (``python -m pytest`` in ci.yml's ``python`` job). The
whole-corpus ``python-compiler`` leg lives only in conformance-matrix.yml,
which has no ``pull_request:`` trigger and RATCHETS an aggregate count — it
fails only on a DROP, so it was green with this fixture failing.
"""

from __future__ import annotations

from ball_compiler import compile_program, load_program

from conftest import run_source


def test_extension_override_calls_the_named_member(conformance_dir):
    src = compile_program(
        load_program(conformance_dir / "480_extension_override_selection.ball.json"))

    # Each of the six overrides must reach the extension's own member, unbound.
    for call in (
        "AlphaTag.tag(", "BetaTag.tag(",
        "AlphaTag.label.fget(", "BetaTag.label.fget(",
        "AlphaTag.scale(", "BetaTag.scale(",
    ):
        assert call in src, f"emitted Python never calls {call}\n---\n{src}"

    # ...and none of them may go through the receiver-asking dispatcher, which
    # cannot tell the two extensions apart.
    assert 'call_method(xs, "main:' not in src, (
        f"an extension override still dispatches dynamically\n---\n{src}")

    golden = (conformance_dir / "480_extension_override_selection.expected_output.txt")
    assert run_source(src) == golden.read_bytes().decode("utf-8").replace("\r\n", "\n")


def _getter_and_setter_override_program() -> dict:
    """``extension AlphaTag on List<int> { int get slot => …; set slot(int v)
    { … } }`` plus ``main() { print(AlphaTag([1, 2]).slot); }`` — hand-built IR,
    not a fixture: ``480_extension_override_selection`` deliberately carries no
    setter arm (#865), so this shape — valid Dart, just excluded from the
    cross-target corpus — is unreachable from the committed fixture set. The
    getter and setter share the qualified name ``main:AlphaTag.slot``, and the
    call site reaches them exactly as a parsed ``Ext(x).m`` read does: a call
    whose packed input carries an explicit ``self`` field."""
    getter = {
        "name": "main:AlphaTag.slot",
        "outputType": "String",
        "body": {"literal": {"stringValue": "GETTER"}},
        "metadata": {"kind": "method", "is_getter": True, "expression_body": True},
    }
    setter = {
        "name": "main:AlphaTag.slot",
        "inputType": "int",
        "outputType": "void",
        "body": {"literal": {"stringValue": "SETTER"}},
        "metadata": {"kind": "method", "is_setter": True, "expression_body": True},
    }
    override_call = {
        "call": {
            "module": "main",
            "function": "main:AlphaTag.slot",
            "input": {
                "messageCreation": {
                    "fields": [
                        {
                            "name": "self",
                            "value": {
                                "literal": {
                                    "listValue": {
                                        "elements": [
                                            {"literal": {"intValue": 1}},
                                            {"literal": {"intValue": 2}},
                                        ]
                                    }
                                }
                            },
                        }
                    ]
                }
            },
        }
    }
    main_fn = {
        "name": "main",
        "metadata": {"kind": "function"},
        "body": {
            "block": {
                "statements": [
                    {
                        "expression": {
                            "call": {
                                "module": "std",
                                "function": "print",
                                "input": {
                                    "messageCreation": {
                                        "fields": [{"name": "message", "value": override_call}]
                                    }
                                },
                            }
                        }
                    }
                ]
            }
        },
    }
    return {
        "name": "test",
        "version": "1.0.0",
        "entryModule": "main",
        "entryFunction": "main",
        "modules": [
            {"name": "std", "functions": [{"name": "print", "isBase": True}]},
            {
                "name": "main",
                "typeDefs": [
                    {"name": "main:AlphaTag", "metadata": {"kind": "extension", "on": "List<int>"}}
                ],
                "functions": [getter, setter, main_fn],
            },
        ],
    }


def test_extension_override_read_with_both_getter_and_setter_dispatches_the_getter():
    """A READ through an override of a member that has BOTH a getter and a
    setter must dispatch the GETTER (PR #829 review).

    Before the fix, ``extension_members`` was filled in one pass with no
    getter/setter precedence: the getter and setter share the Ball function
    name, so whichever member the loop visited LAST won the dict slot. The
    setter is collected after the getter in every real extension (``get``
    syntactically precedes ``set``), so a plain read emitted
    ``AlphaTag.slot(xs)`` — a direct call on the ``property`` object itself,
    which raises ``TypeError: 'property' object is not callable`` — instead of
    ``AlphaTag.slot.fget(xs)``."""
    src = compile_program(_getter_and_setter_override_program())

    assert run_source(src) == "GETTER\n"


def test_extension_override_read_with_both_getter_and_setter_still_emits_the_setter():
    """The getter winning the READ dispatch must not come at the cost of the
    setter vanishing from the compiled source — both halves of the property
    must still be defined."""
    src = compile_program(_getter_and_setter_override_program())

    assert "@property" in src
    assert "slot.setter" in src or "@slot.setter" in src
