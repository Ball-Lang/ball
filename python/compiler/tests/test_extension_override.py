"""Extension-override dispatch (issue #670, fixture
``478_extension_override_selection``).

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
        load_program(conformance_dir / "478_extension_override_selection.ball.json"))

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

    golden = (conformance_dir / "478_extension_override_selection.expected_output.txt")
    assert run_source(src) == golden.read_bytes().decode("utf-8").replace("\r\n", "\n")
