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
