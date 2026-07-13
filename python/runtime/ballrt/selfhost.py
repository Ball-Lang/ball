"""Runtime support specific to the self-hosted engine program.

The reference engine (``dart/self_host/engine.ball.json``) compiled through the
Ball -> Python compiler reaches a few constructs a plain user program does not:
Dart ``is`` / ``as`` type tests, the proto oneof "which"-case enums, and a
handful of ``dart.math`` transcendentals. Their runtime backing lives here.
"""

from __future__ import annotations

import math as _math
import re as _re

from .flow import throw
from .values import BallSet, make_ball_map


# ── Type tests (std.is / std.is_not / std.as) ────────────────────────────────

def _base_type_name(typename: str) -> str:
    """The bare type name of a Dart type string: strip a trailing ``?`` and any
    ``<...>`` generic arguments (``List<int>?`` -> ``List``)."""
    t = typename.strip()
    lt = t.find("<")
    if lt >= 0:
        t = t[:lt]
    t = t.strip()
    if t.endswith("?"):
        t = t[:-1].strip()
    return t


def _is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


_BUILTIN = {
    "int": _is_int,
    "double": lambda v: isinstance(v, float),
    "num": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
    "String": lambda v: isinstance(v, str),
    "bool": lambda v: isinstance(v, bool),
    "List": lambda v: isinstance(v, list),
    "Iterable": lambda v: isinstance(v, (list, BallSet)),
    "Map": lambda v: isinstance(v, dict),
    "Set": lambda v: isinstance(v, BallSet),
    "Function": callable,
    "Object": lambda v: v is not None,
    "Null": lambda v: v is None,
    "dynamic": lambda v: True,
}


def is_type(value, typename: str) -> bool:
    """Dart ``value is Type``. Builtin types map to Python checks; a user type
    matches by class name walked over the MRO (so subclasses match their base,
    e.g. a StdModuleHandler ``is BallModuleHandler``)."""
    t = _base_type_name(typename)
    checker = _BUILTIN.get(t)
    if checker is not None:
        return checker(value)
    for cls in type(value).__mro__:
        if getattr(cls, "__name__", None) == t:
            return True
    return False


def as_type(value, typename: str):
    """Dart ``value as Type``. Python is dynamically typed, so a cast is an
    identity — the value flows through unchanged (the engine relies on the
    cast only to satisfy the Dart type checker, never to convert)."""
    return value


# ── Proto oneof "which"-case enums ───────────────────────────────────────────

class _Arm:
    """A stand-in for every protoc-dart oneof-case enum (``Expression_Expr`` …).
    Their enum values are the camelCase arm names the ``ball_proto``
    discriminators return, so attribute access simply yields the attribute name
    (``arm.call`` -> ``"call"``, ``arm.notSet`` -> ``"notSet"``)."""

    __slots__ = ()

    def __getattr__(self, name):
        return name


arm = _Arm()


# ── dart.math transcendentals ────────────────────────────────────────────────

class _DartMath:
    """The ``dart.math`` top-level functions the engine's ``_math*`` wrappers
    call. Ball ints promote to float for the C-library math like Dart's."""

    @staticmethod
    def sqrt(x):
        return _math.sqrt(float(x))

    @staticmethod
    def pow(x, y):
        return _math.pow(float(x), float(y))

    @staticmethod
    def log(x):
        return _math.log(float(x))

    @staticmethod
    def exp(x):
        return _math.exp(float(x))

    @staticmethod
    def sin(x):
        return _math.sin(float(x))

    @staticmethod
    def cos(x):
        return _math.cos(float(x))

    @staticmethod
    def tan(x):
        return _math.tan(float(x))

    @staticmethod
    def asin(x):
        return _math.asin(float(x))

    @staticmethod
    def acos(x):
        return _math.acos(float(x))

    @staticmethod
    def atan(x):
        return _math.atan(float(x))

    @staticmethod
    def atan2(y, x):
        return _math.atan2(float(y), float(x))


dm = _DartMath()


# ── Builtin type tokens (bare `int`/`num`/… as first-class values) ───────────

class _TypeToken:
    __slots__ = ("name",)

    def __init__(self, name):
        self.name = name

    def __repr__(self):
        return self.name


ty_int = _TypeToken("int")
ty_num = _TypeToken("num")
ty_double = _TypeToken("double")
ty_String = _TypeToken("String")
ty_List = _TypeToken("List")
ty_Map = _TypeToken("Map")
ty_Set = _TypeToken("Set")
ty_Function = _TypeToken("Function")
ty_DateTime = _TypeToken("DateTime")
ty_Future = _TypeToken("Future")


# ── Builtin static methods (int.tryParse, List.filled, …) ────────────────────

def int_parse(s):
    try:
        return int(str(s).strip())
    except (ValueError, TypeError):
        from .dart_errors import FormatException
        return throw(FormatException(repr(s)))


def int_try_parse(s):
    try:
        return int(str(s).strip())
    except (ValueError, TypeError):
        return None


def num_parse(s):
    t = str(s).strip()
    try:
        return int(t)
    except ValueError:
        return float(t)


def num_try_parse(s):
    try:
        return num_parse(s)
    except (ValueError, TypeError):
        return None


def double_parse(s):
    try:
        return float(str(s).strip())
    except (ValueError, TypeError):
        from .dart_errors import FormatException
        return throw(FormatException(repr(s)))


def double_try_parse(s):
    try:
        return float(str(s).strip())
    except (ValueError, TypeError):
        return None


def string_from_char_code(code):
    return chr(int(code))


def string_from_char_codes(codes):
    # Dart String.fromCharCodes takes UTF-16 code units; decode as such so
    # surrogate pairs recombine into a single astral code point.
    data = b"".join(int(c).to_bytes(2, "little") for c in codes)
    return data.decode("utf-16-le")


def list_filled(length, fill):
    return [fill] * int(length)


def list_generate(length, gen):
    from .values import invoke
    return [invoke(gen, i) for i in range(int(length))]


def map_unmodifiable(m):
    return dict(m) if isinstance(m, dict) else dict(m or {})


def set_unmodifiable(s):
    from .values import BallSet, iterate
    return BallSet(iterate(s))


def function_apply(fn, positional, named=None):
    """Dart Function.apply. A Ball function takes one input (invariant #1): a
    single positional maps to it directly; several pack into an ``arg0/arg1``
    message (optionally merged with named arguments)."""
    from .values import invoke
    pos = list(positional or [])
    if named:
        packed = {f"arg{i}": v for i, v in enumerate(pos)}
        packed.update(named)
        return invoke(fn, packed)
    if len(pos) == 1:
        return invoke(fn, pos[0])
    if not pos:
        return invoke(fn, None)
    return invoke(fn, {f"arg{i}": v for i, v in enumerate(pos)})


# DateTime — the engine's cooperative execution-timeout guard reads
# DateTime.now().millisecondsSinceEpoch, so `now` must work even though most
# other time paths are non-deterministic golden-less carve-outs.
import datetime as _datetime
import time as _time


class DateTime:
    __slots__ = ("_dt",)

    def __init__(self, dt):
        self._dt = dt

    @property
    def millisecondsSinceEpoch(self):
        return int(self._dt.timestamp() * 1000)

    @property
    def microsecondsSinceEpoch(self):
        return int(self._dt.timestamp() * 1_000_000)

    @property
    def year(self):
        return self._dt.year

    @property
    def month(self):
        return self._dt.month

    @property
    def day(self):
        return self._dt.day

    @property
    def hour(self):
        return self._dt.hour

    @property
    def minute(self):
        return self._dt.minute

    @property
    def second(self):
        return self._dt.second

    @property
    def millisecond(self):
        return self._dt.microsecond // 1000

    @property
    def weekday(self):
        return self._dt.isoweekday()

    def toUtc(self):
        return DateTime(self._dt.astimezone(_datetime.timezone.utc))

    def toIso8601String(self):
        # Dart's format: always millisecond precision (microsecond if non-zero),
        # and a `Z` suffix for UTC (no numeric offset).
        dt = self._dt
        base = dt.strftime("%Y-%m-%dT%H:%M:%S")
        us = dt.microsecond
        frac = ".%03d" % (us // 1000) if us % 1000 == 0 else ".%06d" % us
        is_utc = dt.tzinfo is not None and dt.utcoffset() == _datetime.timedelta(0)
        return base + frac + ("Z" if is_utc else "")

    def isBefore(self, other):
        return self._dt < other._dt

    def isAfter(self, other):
        return self._dt > other._dt

    def toString(self):
        return self._dt.isoformat(sep=" ")

    def __str__(self):
        return self.toString()


def datetime_now(*_a):
    return DateTime(_datetime.datetime.now(_datetime.timezone.utc))


def datetime_parse(s):
    return DateTime(_datetime.datetime.fromisoformat(str(s)))


def datetime_from_ms(ms, *_):
    return DateTime(_datetime.datetime.fromtimestamp(int(ms) / 1000, _datetime.timezone.utc))


# ── Builtin static constants ─────────────────────────────────────────────────

double_infinity = _math.inf
double_negative_infinity = -_math.inf
double_nan = _math.nan
double_max_finite = 1.7976931348623157e308
double_min_positive = 5e-324


# ── Runtime/stub type constructors (ball_value wrappers, RegExp, …) ──────────

def make_ball_list(items=None):
    return list(items) if items is not None else []


def make_ball_double(v=0.0):
    return float(v) if v is not None else 0.0


def make_ball_int(v=0):
    return int(v) if v is not None else 0


def make_ball_string(v=""):
    return str(v) if v is not None else ""


def make_ball_bool(v=False):
    return bool(v)


class _Match:
    """A RegExp match — Dart RegExpMatch.group(i)."""

    __slots__ = ("_m",)

    def __init__(self, m):
        self._m = m

    def group(self, i=0):
        try:
            return self._m.group(int(i))
        except (IndexError, KeyError):
            return None

    def groupCount(self, *_):
        return self._m.re.groups


def _dart_to_py_regex(pattern):
    # Dart named groups use (?<name>…); Python uses (?P<name>…).
    return _re.sub(r"\(\?<([A-Za-z_][A-Za-z0-9_]*)>", r"(?P<\1>", pattern)


class RegExp:
    __slots__ = ("_re",)

    def __init__(self, fields):
        pattern = fields.get("pattern", fields.get("source", fields.get("arg0", "")))
        flags = 0
        if fields.get("multiLine"):
            flags |= _re.MULTILINE
        if fields.get("caseSensitive") is False:
            flags |= _re.IGNORECASE
        if fields.get("dotAll"):
            flags |= _re.DOTALL
        if fields.get("unicode"):
            flags |= _re.UNICODE
        self._re = _re.compile(_dart_to_py_regex(pattern), flags)

    def firstMatch(self, s):
        m = self._re.search(s)
        return _Match(m) if m else None

    def hasMatch(self, s):
        return self._re.search(s) is not None

    def allMatches(self, s, *_):
        return [_Match(m) for m in self._re.finditer(s)]

    def stringMatch(self, s):
        m = self._re.search(s)
        return m.group(0) if m else None


def make_regexp(fields):
    return RegExp(fields if isinstance(fields, dict) else {"pattern": fields})


class StringBuffer:
    __slots__ = ("_parts",)

    def __init__(self, initial=""):
        self._parts = [str(initial)] if initial else []

    def write(self, obj):
        from .ops import to_str
        self._parts.append(to_str(obj))
        return None

    def writeln(self, obj=""):
        from .ops import to_str
        self._parts.append(to_str(obj) + "\n")
        return None

    def writeCharCode(self, code):
        self._parts.append(chr(int(code)))
        return None

    def clear(self):
        self._parts.clear()
        return None

    def toString(self):
        return "".join(self._parts)

    def __str__(self):
        return "".join(self._parts)

    @property
    def length(self):
        return sum(len(p) for p in self._parts)

    @property
    def isEmpty(self):
        return self.length == 0

    @property
    def isNotEmpty(self):
        return self.length != 0


def make_string_buffer(initial=""):
    return StringBuffer(initial if initial is not None else "")


class StateError(Exception):
    def __init__(self, message=""):
        super().__init__(message)
        self.message = message

    def toString(self):
        return f"Bad state: {self.message}"

    def __str__(self):
        return self.toString()


def make_state_error(message=""):
    return StateError(message)


def make_duration(fields):
    # Only the field bag is retained; the engine's Duration use is limited and
    # non-deterministic time paths are golden-less carve-outs.
    return dict(fields) if isinstance(fields, dict) else {}


class _JsonCodec:
    def convert(self, value):
        from . import convert as _c
        return self._op(value, _c)


class _JsonEncoderRt(_JsonCodec):
    def _op(self, value, c):
        return c.json_encode(value)


class _JsonDecoderRt(_JsonCodec):
    def _op(self, value, c):
        return c.json_decode(value)


def make_json_encoder():
    return _JsonEncoderRt()


def make_json_decoder():
    return _JsonDecoderRt()


def stack_trace_of(_exc):
    """A caught error's stack trace. A fixed non-empty placeholder keeps golden
    output deterministic while satisfying programs that assert the trace is
    present (`stackTrace.toString().isNotEmpty`)."""
    return "#0      <ball> (ball:1:1)"


# ── dart.io (deferred) ───────────────────────────────────────────────────────

def io_stub(fn, args):
    """File/Directory operations are not needed by the conformance corpus (the
    filesystem fixtures are golden-less carve-outs). Reaching one is a loud
    runtime error, never a silent-wrong result (issue #55)."""
    return throw(f"unsupported dart.io.{fn}")
