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


def test_set_add_remove_return_bool_and_mutate_in_place():
    """The ONE portable contract for std_collections.set_add / set_remove (#545).

    Both mutate the receiver set IN PLACE and return a bool -- True only when
    the element was newly inserted / was actually present -- exactly like Dart's
    own ``Set.add`` / ``Set.remove``. Before #545 both returned the set itself,
    so a compiled Python program that put the result in a value position
    (``if s.add(x): ...``) computed something different from every other target.
    Conformance fixture ``459_set_add_remove_bool`` is the cross-target half of
    this guard; this is the Python half, because no CI leg compiles a
    conformance fixture to Python.
    """
    s = ballrt.col.set_create([1, 2])

    assert ballrt.col.set_add(s, 3) is True     # fresh insert
    assert ballrt.col.set_add(s, 3) is False    # duplicate
    # The insert landed on the SHARED set, exactly once -- a functional
    # (copying) implementation would leave this at 2.
    assert ballrt.col.set_length(s) == 3
    assert ballrt.col.set_contains(s, 3) is True

    assert ballrt.col.set_remove(s, 2) is True   # was present
    assert ballrt.col.set_remove(s, 2) is False  # already gone
    assert ballrt.col.set_length(s) == 2
    assert ballrt.col.set_contains(s, 2) is False


def test_ball_set_add_returns_bool_like_dart():
    """``BallSet.add`` is the method form the self-hosted engine calls; Dart's
    ``Set.add`` returns bool, so ours must too (#545)."""
    s = ballrt.BallSet([1])
    assert s.add(2) is True
    assert s.add(2) is False
    assert s.remove(2) is True
    assert s.remove(2) is False
