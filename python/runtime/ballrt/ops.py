"""Base-operation helpers with Dart-exact semantics.

The Ball reference implementation is Dart, so arithmetic, comparison and
string formatting must match Dart's observable behaviour rather than Python's
defaults. The quirks that differ from a naive Python translation and are
reproduced here:

* ``~/`` (``intdiv``) truncates toward zero; Python ``//`` floors.
* ``%`` (``modulo``) is always non-negative (``0 <= r < b.abs()``); Python's
  ``%`` follows the divisor's sign.
* ``int + int`` stays ``int`` while ``int + double`` promotes to ``double``.
* ``toString`` on an integral double keeps a trailing ``.0`` and renders
  non-finite values as ``Infinity`` / ``-Infinity`` / ``NaN``.
* ``==`` does not conflate ``bool`` with the ``1``/``0`` ints (Python treats
  ``bool`` as an ``int`` subclass; Dart does not).

Ball values map to native Python: ``int``/``float``/``str``/``bool``/``None``
and ``list``/``dict`` (both insertion-ordered). Sets are :class:`~ballrt.values.BallSet`
and user instances are ordinary Python objects.
"""

from __future__ import annotations

import math


def _is_num(v) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def _both_int(a, b):
    return isinstance(a, int) and not isinstance(a, bool) and isinstance(b, int) and not isinstance(b, bool)


def _as_float(v) -> float:
    if isinstance(v, bool):
        return 1.0 if v else 0.0
    if isinstance(v, (int, float)):
        return float(v)
    raise TypeError(f"ball: expected a number, got {type(v).__name__} {v!r}")


# ── Arithmetic ──────────────────────────────────────────────────────────────

def add(a, b):
    if isinstance(a, str) and isinstance(b, str):
        return a + b
    if isinstance(a, list) and isinstance(b, list):
        return a + b
    if _both_int(a, b):
        return _wrap64(a + b)
    return _as_float(a) + _as_float(b)


def subtract(a, b):
    if _both_int(a, b):
        return _wrap64(a - b)
    return _as_float(a) - _as_float(b)


def multiply(a, b):
    if _both_int(a, b):
        return _wrap64(a * b)
    return _as_float(a) * _as_float(b)


def intdiv(a, b):
    """Dart ``~/`` — truncating (toward zero) integer division."""
    if _both_int(a, b):
        if b == 0:
            from .flow import throw
            return throw("IntegerDivisionByZeroException")
        q = abs(a) // abs(b)
        return _wrap64(-q if (a < 0) != (b < 0) else q)
    bf = _as_float(b)
    if bf == 0.0:
        from .flow import throw
        return throw("Unsupported operation: Result of truncating division is Infinity")
    return int(_as_float(a) / bf)


def divide_double(a, b):
    """Dart ``/`` — always a double; division by zero yields Infinity/-Infinity/NaN."""
    af, bf = _as_float(a), _as_float(b)
    if bf == 0.0:
        if af == 0.0:
            return math.nan
        return math.copysign(math.inf, af) * math.copysign(1.0, bf)
    return af / bf


def modulo(a, b):
    """Dart ``%`` — result is always in ``[0, b.abs())``."""
    if _both_int(a, b):
        m = a - intdiv(a, b) * b
        if m < 0:
            m = m - b if b < 0 else m + b
        return m
    af, bf = _as_float(a), _as_float(b)
    if bf == 0.0:
        return math.nan
    m = math.fmod(af, bf)
    if m < 0:
        m += abs(bf)
    return m


def negate(v):
    if isinstance(v, int) and not isinstance(v, bool):
        return _wrap64(-v)
    return -_as_float(v)


# ── Bitwise (64-bit, Dart int) ──────────────────────────────────────────────

_MASK = (1 << 64) - 1
_INT64_MIN = -(1 << 63)
_INT64_MAX = (1 << 63) - 1


def _as_int(v) -> int:
    if isinstance(v, bool):
        return 1 if v else 0
    if isinstance(v, int):
        return v
    return int(_as_float(v))


def _wrap64(x: int) -> int:
    x &= _MASK
    return x - (1 << 64) if x & (1 << 63) else x


def bitwise_and(a, b):
    return _wrap64(_as_int(a) & _as_int(b))


def bitwise_or(a, b):
    return _wrap64(_as_int(a) | _as_int(b))


def bitwise_xor(a, b):
    return _wrap64(_as_int(a) ^ _as_int(b))


def bitwise_not(v):
    return _wrap64(~_as_int(v))


def left_shift(a, b):
    return _wrap64(_as_int(a) << (_as_int(b) & 63))


def right_shift(a, b):
    return _as_int(a) >> (_as_int(b) & 63)


def unsigned_right_shift(a, b):
    return _wrap64((_as_int(a) & _MASK) >> (_as_int(b) & 63))


# ── Comparison ──────────────────────────────────────────────────────────────

def _cmp(a, b) -> int:
    if isinstance(a, str) and isinstance(b, str):
        return -1 if a < b else (1 if a > b else 0)
    af, bf = _as_float(a), _as_float(b)
    return -1 if af < bf else (1 if af > bf else 0)


def less_than(a, b):
    return _cmp(a, b) < 0


def greater_than(a, b):
    return _cmp(a, b) > 0


def lte(a, b):
    return _cmp(a, b) <= 0


def gte(a, b):
    return _cmp(a, b) >= 0


def equals(a, b):
    if a is None or b is None:
        return a is None and b is None
    if isinstance(a, bool) or isinstance(b, bool):
        return isinstance(a, bool) and isinstance(b, bool) and a == b
    if _is_num(a) and _is_num(b):
        return float(a) == float(b)
    if isinstance(a, str) and isinstance(b, str):
        return a == b
    return a is b


def not_equals(a, b):
    return not equals(a, b)


def compare_to(a, b):
    return _cmp(a, b)


# ── Logic ───────────────────────────────────────────────────────────────────

def truthy(v) -> bool:
    if isinstance(v, bool):
        return v
    if v is None:
        return False
    return True


def and_(a, b):
    return truthy(a) and truthy(b)


def or_(a, b):
    return truthy(a) or truthy(b)


def not_(v):
    return not truthy(v)


def null_coalesce(a, b):
    return b if a is None else a


def null_check(v):
    if v is None:
        from .flow import throw
        throw("Null check operator used on a null value")
    return v


# ── Strings & conversion ────────────────────────────────────────────────────

def _format_double(x: float) -> str:
    if math.isnan(x):
        return "NaN"
    if math.isinf(x):
        return "Infinity" if x > 0 else "-Infinity"
    if x == int(x) and abs(x) < 1e21:
        return "%.1f" % x
    return repr(x)


def to_str(v) -> str:
    if v is None:
        return "null"
    if isinstance(v, str):
        return v
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return _format_double(v)
    if isinstance(v, list):
        return "[" + ", ".join(to_str(x) for x in v) + "]"
    if isinstance(v, dict):
        return "{" + ", ".join(f"{to_str(k)}: {to_str(val)}" for k, val in v.items()) + "}"
    # BallSet, instances, functions — delegate to their __str__.
    return str(v)


def concat(a, b):
    return to_str(a) + to_str(b)


def utf16_length(s: str) -> int:
    """Dart's ``String.length`` — the count of UTF-16 code units, not code
    points, so a non-BMP char (emoji) counts as its surrogate pair (2)."""
    return len(s.encode("utf-16-le")) // 2


def length(v):
    if isinstance(v, str):
        return utf16_length(v)
    if isinstance(v, (list, dict)):
        return len(v)
    from .values import BallSet
    if isinstance(v, BallSet):
        return len(v)
    raise TypeError(f"ball: length: unsupported operand {type(v).__name__}")


def string_length(v):
    return utf16_length(v)


def string_concat(a, b):
    return to_str(a) + to_str(b)


def string_to_upper(v):
    return v.upper()


def string_to_lower(v):
    return v.lower()


def string_trim(v):
    return v.strip()


def string_trim_start(v):
    return v.lstrip()


def string_trim_end(v):
    return v.rstrip()


def string_contains(v, search):
    return search in v


def string_starts_with(v, prefix):
    return v.startswith(prefix)


def string_ends_with(v, suffix):
    return v.endswith(suffix)


def string_index_of(v, search):
    return v.find(search)


def string_last_index_of(v, search):
    return v.rfind(search)


def string_split(v, sep):
    return list(v.split(sep)) if sep != "" else list(v)


def string_replace_all(v, frm, to):
    return v.replace(frm, to)


def string_replace(v, frm, to):
    return v.replace(frm, to, 1)


def string_is_empty(v):
    return len(v) == 0


def string_substring(v, start, end):
    s = int(start)
    if end is None:
        return v[s:]
    return v[s:int(end)]


def string_code_unit_at(v, i):
    return ord(v[int(i)])


def string_to_int(v):
    try:
        return int(v)
    except (ValueError, TypeError):
        from .flow import throw
        return throw(f"FormatException: {v!r}")


def string_to_double(v):
    try:
        return float(v)
    except (ValueError, TypeError):
        from .flow import throw
        return throw(f"FormatException: {v!r}")


def string_pad_left(v, width, padding):
    w = int(width)
    pad = padding if padding else " "
    while len(v) < w:
        v = pad + v
    return v[len(v) - max(w, len(v)):] if len(v) > w else v


def string_pad_right(v, width, padding):
    w = int(width)
    pad = padding if padding else " "
    while len(v) < w:
        v = v + pad
    return v


# ── Numeric conversion ──────────────────────────────────────────────────────

def to_int(v):
    if isinstance(v, bool):
        return 1 if v else 0
    if isinstance(v, int):
        return v
    if isinstance(v, float):
        # Dart's double.toInt() truncates toward zero then clamps to the int64
        # range (a double >= 2^63 saturates to MAX_INT64, not the unbounded
        # Python bignum). NaN / Infinity are unrepresentable.
        if math.isnan(v) or math.isinf(v):
            from .flow import throw
            throw("Infinity or NaN toInt")
        t = math.trunc(v)
        if t > _INT64_MAX:
            return _INT64_MAX
        if t < _INT64_MIN:
            return _INT64_MIN
        return int(t)
    if isinstance(v, str):
        return int(v)
    raise TypeError(f"ball: to_int: unsupported operand {type(v).__name__}")


def to_double(v):
    return _as_float(v)


def _round_sig(ax: float, k: int):
    """Round ax (finite, > 0) to k significant digits, half away from zero.

    Returns ``(digits, exp)`` where the value is ``D[0].D[1:] * 10**exp``.
    Mirrors the Go/Rust runtimes: format with an over-long fraction so the
    discarded tail is the exact decimal expansion and a tie reduces to
    ``D[k] >= '5'``.
    """
    s = "%.*e" % (1080, ax)
    mantissa, _, exp_s = s.partition("e")
    exp = int(exp_s)
    digits = mantissa.replace(".", "")
    if len(digits) <= k:
        return digits + "0" * (k - len(digits)), exp
    round_up = digits[k] >= "5"
    kept = list(digits[:k])
    if round_up:
        carried = True
        for i in range(len(kept) - 1, -1, -1):
            if kept[i] != "9":
                kept[i] = chr(ord(kept[i]) + 1)
                carried = False
                break
            kept[i] = "0"
        if carried:
            trim_to = max(k - 1, 0)
            kept = ["1"] + kept[:trim_to]
            exp += 1
    return "".join(kept), exp


def _dart_exponent(e: int) -> str:
    return "e" + ("-" if e < 0 else "+") + str(abs(e))


def to_string_as_fixed(v, digits):
    n = _as_float(v)
    d = int(_as_float(digits))
    if math.isnan(n):
        return "NaN"
    if math.isinf(n):
        return "-Infinity" if n < 0 else "Infinity"
    neg = math.copysign(1.0, n) < 0
    ax = abs(n)
    if ax == 0.0:
        out = "0" + ("." + "0" * d if d > 0 else "")
    else:
        s = "%.*e" % (1080, ax)
        mantissa, _, exp_s = s.partition("e")
        exp = int(exp_s)
        k = exp + 1 + d
        if k <= 0:
            if k == 0 and mantissa[0] >= "5":
                m, e2 = "1", exp + 1
            elif d > 0:
                m, e2 = None, None
                out = "0." + "0" * d
            else:
                m, e2 = None, None
                out = "0"
        else:
            m, e2 = _round_sig(ax, k)
        if k > 0 or (k == 0 and mantissa[0] >= "5"):
            intd = e2 + 1
            if intd <= 0:
                int_part = "0"
                frac = "0" * (-intd) + m
            elif len(m) >= intd:
                int_part = m[:intd]
                frac = m[intd:]
            else:
                int_part = m + "0" * (intd - len(m))
                frac = ""
            frac = (frac + "0" * d)[:d]
            out = int_part + ("." + frac if d > 0 else "")
    # Dart keeps the minus sign for a negative receiver even when the formatted
    # magnitude rounds to all zeros (negative-zero parity, issue #101).
    if neg:
        out = "-" + out
    return out


def to_string_as_exponential(v, digits):
    x = _as_float(v)
    if math.isnan(x):
        return "NaN"
    if math.isinf(x):
        return "-Infinity" if x < 0 else "Infinity"
    neg = math.copysign(1.0, x) < 0
    ax = abs(x)
    if digits is None:
        s = repr(ax)
        if "e" in s or "E" in s:
            mant, _, exp_s = s.lower().partition("e")
            out = mant + _dart_exponent(int(exp_s))
        else:
            se = "%e" % ax
            mant, _, exp_s = se.partition("e")
            mant = mant.rstrip("0").rstrip(".")
            out = mant + _dart_exponent(int(exp_s))
    else:
        d = int(_as_float(digits))
        if ax == 0.0:
            out = "0" + ("." + "0" * d if d > 0 else "") + "e+0"
        else:
            m, e = _round_sig(ax, d + 1)
            out = m[:1] + ("." + m[1:] if d > 0 else "") + _dart_exponent(e)
    return "-" + out if neg else out


def to_string_as_precision(v, precision):
    x = _as_float(v)
    if math.isnan(x):
        return "NaN"
    if math.isinf(x):
        return "-Infinity" if x < 0 else "Infinity"
    p = max(int(_as_float(precision)), 1)
    neg = math.copysign(1.0, x) < 0
    ax = abs(x)
    if ax == 0.0:
        out = "0" + ("." + "0" * (p - 1) if p > 1 else "")
    else:
        m, e = _round_sig(ax, p)
        if e < -6 or e >= p:
            out = m[:1] + ("." + m[1:] if p > 1 else "") + _dart_exponent(e)
        elif e >= 0:
            intd = e + 1
            out = m[:intd] + ("." + m[intd:] if p > intd else "")
        else:
            out = "0." + "0" * (-e - 1) + m
    return "-" + out if neg else out


# ── Math ────────────────────────────────────────────────────────────────────

def math_abs(v):
    # abs(MIN_INT64) overflows back to MIN_INT64 under Dart's 64-bit wrap.
    if isinstance(v, int) and not isinstance(v, bool):
        return _wrap64(abs(v))
    return abs(v)


def math_floor(v):
    return math.floor(v)


def math_ceil(v):
    return math.ceil(v)


def math_round(v):
    # Dart rounds half away from zero; Python's round() is banker's rounding.
    return math.floor(v + 0.5) if v >= 0 else math.ceil(v - 0.5)


def math_sqrt(v):
    return math.sqrt(_as_float(v))


def math_pow(base, exp):
    r = math.pow(_as_float(base), _as_float(exp))
    if _both_int(base, exp) and _as_float(exp) >= 0:
        return int(r)
    return r


def math_min(a, b):
    return a if _cmp(a, b) <= 0 else b


def math_max(a, b):
    return a if _cmp(a, b) >= 0 else b


def math_trunc(v):
    return math.trunc(v)


def math_sign(v):
    n = _as_float(v)
    return 0 if n == 0 else (1 if n > 0 else -1)


def math_clamp(v, lo, hi):
    """Dart ``num.clamp(lo, hi)`` — clamp v to [lo, hi], preserving int/double."""
    if _cmp(v, lo) < 0:
        return lo
    if _cmp(v, hi) > 0:
        return hi
    return v


def math_is_finite(v):
    return math.isfinite(_as_float(v))


def math_is_infinite(v):
    return math.isinf(_as_float(v))


def math_gcd(a, b):
    return math.gcd(int(a), int(b))


def round_to_double(v):
    return float(math_round(v))


def floor_to_double(v):
    return float(math.floor(v))


def ceil_to_double(v):
    return float(math.ceil(v))


def truncate_to_double(v):
    return float(math.trunc(v))


def string_runes(v):
    """Dart ``String.runes`` — the Unicode code points (not UTF-16 units)."""
    return [ord(ch) for ch in v]
