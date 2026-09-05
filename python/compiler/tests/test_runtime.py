"""Unit tests for the ballrt runtime's Dart-exact semantics."""

from __future__ import annotations

import math

import ballrt


def test_intdiv_truncates_toward_zero():
    assert ballrt.intdiv(20, 3) == 6
    assert ballrt.intdiv(-15, 4) == -3   # Dart ~/ truncates; Python // would floor to -4
    assert ballrt.intdiv(15, -4) == -3


def test_modulo_is_non_negative():
    assert ballrt.modulo(17, 5) == 2
    assert ballrt.modulo(-7, 3) == 2     # Dart % is always in [0, |b|)
    assert ballrt.modulo(7, -3) == 1
    assert ballrt.modulo(-7.0, 3.0) == 2.0


def test_add_preserves_int_and_promotes_double():
    assert ballrt.add(2, 3) == 5 and isinstance(ballrt.add(2, 3), int)
    assert ballrt.add(2, 3.0) == 5.0 and isinstance(ballrt.add(2, 3.0), float)
    assert ballrt.add("Hello", "World") == "HelloWorld"
    assert ballrt.add([1], [2]) == [1, 2]


def test_to_str_matches_dart():
    assert ballrt.to_str(True) == "true"
    assert ballrt.to_str(False) == "false"
    assert ballrt.to_str(None) == "null"
    assert ballrt.to_str(10.0) == "10.0"       # integral double keeps .0
    assert ballrt.to_str(42) == "42"
    assert ballrt.to_str([1, 2, 3]) == "[1, 2, 3]"


def test_equals_does_not_conflate_bool_and_int():
    assert ballrt.equals(1, 1.0) is True       # numeric cross-promotion
    assert ballrt.equals(True, 1) is False      # bool is a distinct Dart type
    assert ballrt.equals(True, True) is True


def test_string_length_is_utf16_code_units():
    assert ballrt.length("hello") == 5
    assert ballrt.length("\U0001F600\U0001F680") == 4   # two non-BMP -> 2 surrogate pairs


def test_to_string_as_fixed_rounds_half_away_and_keeps_negative_zero():
    assert ballrt.to_string_as_fixed(2.5, 0) == "3"
    assert ballrt.to_string_as_fixed(-2.5, 0) == "-3"
    assert ballrt.to_string_as_fixed(3.14159, 2) == "3.14"
    assert ballrt.to_string_as_fixed(-0.0, 1) == "-0.0"


def test_flow_signals_raise():
    import pytest

    with pytest.raises(ballrt.BallReturn):
        ballrt.ret(5)
    with pytest.raises(ballrt.BallBreak):
        ballrt.brk("")
    with pytest.raises(ballrt.BallContinue):
        ballrt.cont("")
    with pytest.raises(ballrt.BallThrow):
        ballrt.throw("boom")


def test_math_round_is_half_away_from_zero():
    assert ballrt.math_round(2.5) == 3
    assert ballrt.math_round(-2.5) == -3
    assert math.isclose(ballrt.math_sqrt(9), 3.0)


def test_call_method_prefers_a_real_method_over_the_has_prefix_presence_path():
    """``regexp.hasMatch(s)`` is a REAL method, not a ``has<Field>`` presence check.

    ``call_method`` used to test the ``has`` + uppercase-letter prefix first, so
    every ``hasMatch`` call was rewritten into a protobuf presence probe for a
    field named ``match`` and silently answered False — the self-hosted engine's
    regex paths (``std.string_matches``, the ``^arg\\d+$`` constructor-argument
    test) were dead in Python while every other target ran them.
    """
    from ballrt.selfhost import make_regexp

    rx = make_regexp({"arg0": r"^arg\d+$"})
    assert ballrt.call_method(rx, "hasMatch", "arg0") is True
    assert ballrt.call_method(rx, "hasMatch", "arg12") is True
    assert ballrt.call_method(rx, "hasMatch", "argCount") is False
    assert ballrt.call_method(rx, "hasMatch", "depth") is False


def test_call_method_still_answers_protobuf_presence_for_plain_maps():
    """The presence path itself must keep working for the map-shaped receivers
    it exists for (``binding.hasBody()`` on a decoded Ball message)."""
    assert ballrt.call_method({"body": {"literal": 1}}, "hasBody") is True
    assert ballrt.call_method({}, "hasBody") is False


def test_ball_proto_serves_every_presence_check_not_just_the_engine_twelve():
    """``ballrt.proto`` must answer ANY ``has<Field>`` the compiler emits (#570).

    ``python/compiler`` emits ``ballrt.proto.<fn>(obj)`` verbatim for whatever
    ``ball_proto`` function a program calls, but ``proto.py`` only defined the
    twelve presence checks the self-hosted ENGINE reaches. The first program to
    need a thirteenth — ``cli_core``'s ``treeReport``, which discriminates a
    ``ModuleImport`` source with ``hasHttp``/``hasFile``/``hasGit``/
    ``hasRegistry``/``hasInline`` — died with ``AttributeError: module
    'ballrt.proto' has no attribute 'hasHttp'``. Go never had the bug: its
    compiler emits a generic ``ballrt.HasField(obj, "http")``.
    """
    import pytest

    from ballrt import proto

    # The five ModuleImport source arms cli_core reaches, none of which were
    # defined before #570.
    checked = 0
    for field in ("http", "file", "git", "registry", "inline"):
        fn = getattr(proto, f"has{field[0].upper()}{field[1:]}")
        assert fn({field: {"url": "x"}}) is True
        assert fn({}) is False
        assert fn(None) is False
        checked += 1
    assert checked == 5

    # camelCase jsonNames survive the name -> field derivation.
    assert proto.hasFieldAccess({"fieldAccess": {"field": "x"}}) is True
    # An empty message reads as absent (the proto3 rule _has implements).
    assert proto.hasMessageCreation({"messageCreation": {}}) is False

    # The twelve explicit definitions are unchanged.
    assert proto.hasBody({"body": {"literal": {}}}) is True
    assert proto.hasBody({}) is False

    # Anything that is not a has<Field> still fails LOUD, naming what is missing.
    with pytest.raises(AttributeError, match="not implemented in python/runtime"):
        proto.getStructField  # noqa: B018 - attribute access is the assertion
