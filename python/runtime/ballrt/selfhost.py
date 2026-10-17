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
    # The self-hosted engine's own name for the RAW string-keyed map its
    # portable ordered-set value is BUILT OUT OF (``BallRawMap``, a typedef in
    # dart/engine/lib/engine_types.dart -- issue #557). Python models a Set as a
    # distinct ``BallSet``, so ``Map`` never had to exclude one and this arm
    # answers exactly like ``Map`` does. The targets that model a set AS a
    # tagged map (Rust/C#/C++) are the ones where the two answers differ: there
    # ``is Map`` excludes a set, so only this name can reach the engine's own
    # representation. Without an arm the engine falls back to ``is Map``, which
    # is why Python was never affected.
    "BallRawMap": lambda v: isinstance(v, dict),
    "Set": lambda v: isinstance(v, BallSet),
    "Function": callable,
    "Object": lambda v: v is not None,
    "Null": lambda v: v is None,
    "dynamic": lambda v: True,
}


_GENERIC_TYPE_RE = _re.compile(r"^(\w+)<(.+)>$")

# A Dart FUNCTION TYPE (`int Function(int)`, `Function()`, `Function<T>(T)`)
# is not a generic (no top-level `<...>` wrapping the whole string) and is not
# a bare identifier either, so neither `_GENERIC_TYPE_RE` nor a `_BUILTIN`
# lookup by exact name ever recognizes it -- see `is_type`'s handling below.
_FUNCTION_TYPE_RE = _re.compile(r"(^|\s)Function\s*[(<]")


def _is_function_type_signature(typename: str) -> bool:
    """Whether ``typename`` is a Dart function-type signature rather than a
    plain (possibly generic) type name."""
    return bool(_FUNCTION_TYPE_RE.search(typename))


def _split_type_args(s: str) -> list:
    """Top-level comma split of a generic argument list, respecting nested
    ``<...>`` (``Map<String, List<int>>`` -> ``["String", "List<int>"]``)."""
    parts = []
    depth = 0
    start = 0
    for i, ch in enumerate(s):
        if ch == "<":
            depth += 1
        elif ch == ">":
            depth -= 1
        elif ch == "," and depth == 0:
            parts.append(s[start:i].strip())
            start = i + 1
    parts.append(s[start:].strip())
    return parts


def _reified_type_args(value):
    """The ``__type_args__`` tag a constructed instance carries, parsed into a
    list of type-argument strings — the Python analog of the Dart reference
    engine's ``objMap['__type_args__']`` handling (`engine_std.dart`), which
    accepts either a bracketed string (``"<int>"``) or a list
    (``["int"]``). Returns ``None`` when the value carries no tag at all."""
    if isinstance(value, dict):
        raw = value.get("__type_args__")
    else:
        raw = getattr(value, "__type_args__", None)
    if raw is None:
        return None
    if isinstance(raw, list):
        return [str(x) for x in raw]
    s = str(raw).strip()
    if s.startswith("<") and s.endswith(">"):
        s = s[1:-1]
    return [p.strip() for p in s.split(",")] if s else []


def _class_name_matches(value, base_type: str) -> bool:
    """Whether ``value``'s own declared type (its Python class name, walked
    over the MRO so a subclass matches its base — or a ``__type__`` tag for a
    dict-shaped self-hosted-engine object) equals ``base_type``."""
    if isinstance(value, dict):
        tag = value.get("__type__")
        if isinstance(tag, str) and tag:
            return tag.rsplit(":", 1)[-1] == base_type
        return False
    for cls in type(value).__mro__:
        if getattr(cls, "__name__", None) == base_type:
            return True
    return False


# The bare runtime shapes `_BUILTIN` already maps BY NAME -- a value of one of
# these types carries no Ball-level declared identity of its OWN beyond that
# (a plain `int`/`str`/`list`/... is never also an instance of some OTHER,
# differently-named compiled Ball class), so a class-name mismatch against one
# of these is never unambiguous evidence for a name this function does not
# otherwise recognize. See `_has_declared_identity` / `is_type`.
_PRIMITIVE_RUNTIME_TYPES = (int, float, str, bool, list, dict, BallSet)


def _has_declared_identity(value) -> bool:
    """Whether ``value`` carries its OWN Ball-level type identity that a
    class-name MISMATCH against it would be unambiguous evidence of -- a
    ``__type__``-tagged engine-shape dict, or an instance of a genuine
    compiled Ball class (anything that is not a bare runtime primitive:
    ``int``/``float``/``str``/``bool``/``list``/``dict``/``BallSet``, or a
    plain callable). See ``is_type``'s final fallback."""
    if isinstance(value, dict):
        tag = value.get("__type__")
        return isinstance(tag, str) and bool(tag)
    if callable(value):
        return False
    return not isinstance(value, _PRIMITIVE_RUNTIME_TYPES)


def is_type(value, typename: str) -> bool:
    """Dart ``value is Type``.

    A GENERIC type (``List<T>``/``Map<K, V>``/``Set<T>``/``Iterable<T>``)
    checks every element/entry against the type argument(s), and a generic
    USER type compares its own reified ``__type_args__`` tag — exactly like
    the reference engine's ``_typeMatches`` (``engine_std.dart``), issue
    #824: `std.is`/`std.is_not` used to strip the generic argument entirely
    (`_base_type_name`) and match on the bare base type alone, so
    `[1, 2, 3] is List<String>` and `Box<int>(...) is Box<String>` both
    silently answered `true`. A non-generic type maps builtins to Python
    checks and matches a user type by class name walked over the MRO (so
    subclasses match their base, e.g. a StdModuleHandler
    ``is BallModuleHandler``).

    Two things #824's own rewrite got wrong, both regressions against real
    `dart run` on THIS target specifically (the Python compiler leg is
    graded against it) and not merely a difference from the pre-#824
    base-type-only answer:

    * ``Iterable<T>`` is a generic base too, and `dart run` agrees that a
      `List`/`Set` satisfies it element-wise exactly like `List<T>`/`Set<T>`
      do (`[1,2,3] is Iterable<int>` is `true`) — the rewrite only ever
      special-cased the three EXACT names `List`/`Map`/`Set`, so any other
      generic base (starting with `Iterable`) fell to the user-object branch
      below and answered `false` for every list/set, a NEW silent wrong
      answer this base type never had before #824.
    * A user instance with NO reified ``__type_args__`` tag at all — built
      from a constructor call that carried no explicit type argument, such
      as a bare `Box(42)` whose `Box<int>` is Dart's own STATIC inference,
      never captured by this encoder/compiler pair at all — carries no
      evidence either way, so the base type name is the whole story Dart's
      real answer and this function's PRE-#824 answer agree on
      (`Box(42) is Box<int>` is `true`). The rewrite instead required a tag
      to exist before even checking the class name, so every untagged
      instance answered `false` against ANY generic argument, class name
      included — also a NEW regression against real `dart run`, and the
      opposite direction from #824's own motivating bug (that one was a
      false POSITIVE on a REIFIED mismatch, `Box<int>(..) is Box<String>`
      answering `true`; this one is a false NEGATIVE with no reification at
      all). A reified tag that disagrees with the queried argument is still
      unambiguous evidence and still answers `false`, exactly as #824 fixed.

    A THIRD regression, in the same family as the two above (PR #898 review,
    round 3): the element-wise recursion added for `List`/`Map`/`Set`/
    `Iterable` lets through element TYPE ARGUMENTS this function has no way
    to resolve at all -- a Dart FUNCTION TYPE (`int Function(int)`), a
    TYPEDEF alias (`typedef Json = Map<String, dynamic>;` leaves no runtime
    trace for `is_type` to resolve `"Json"` against -- it is erased before
    this layer ever sees it), or an SDK structural INTERFACE a core type
    satisfies but `_BUILTIN` does not enumerate (`Comparable`, `Pattern`,
    ...). Before #824 none of this mattered: the generic argument was
    stripped and ignored outright, so `fs is List<int Function(int)>`,
    `js is List<Json>` and `[1, 2] is List<Comparable>` all answered `true`
    on real `dart run`, matching this function's own pre-#824 answer; #824's
    recursion instead asked the FINAL fallback below to resolve each of
    those three names on every element and, finding none of them in
    `_BUILTIN` and no class-name match either (every element here is a bare
    runtime primitive -- a function, a `Map`, an `int` -- never a compiled
    Ball class of that name), answered `false` for every one, three NEW
    silent wrong answers against real `dart run` on THIS target. The fix
    recognizes a function-type signature structurally (`_is_function_type_signature`,
    checked against `callable(value)`) and, for the remaining unresolved
    names, applies the exact same "absence of evidence" rule already used
    two paragraphs up: a class-name MISMATCH is unambiguous evidence only
    when `value` carries a declared Ball type identity of its own to
    mismatch against (`_has_declared_identity`) -- a real, compiled Ball
    class instance matched against an unrelated name (the existing
    `is_type(value, "UnrelatedError")` contract) still answers `false`, but a
    bare primitive matched against a name this function cannot otherwise
    resolve answers `true`, exactly like the pre-#824 base-type-only check.

    ``None`` is handled FIRST, independent of whether ``typename`` is simple
    or generic: Dart's sound null safety makes ``null`` assignable to any
    NULLABLE type (a trailing ``?``) and to ``dynamic``/``Null``/``void``,
    regardless of the base type — a rule #824's own generic-element recursion
    needs just as much as a plain `x is int?` does. Checking it up front
    matters for the self-hosted engine's OWN compiled source, not just user
    fixtures: `engine.dart`'s `ballObjectSetField` tests `target is
    Map<String, Object?>` (every Ball value is `Object?`, so that bound is
    meant to be trivial), which recurses into `is_type(v, "Object?")` for
    every entry — and a non-inherited instance's `__super__` field is
    legitimately `None`. Stripping the `?` before a bare, null-excluding
    `_BUILTIN["Object"]` lookup made that recursion silently answer `False`
    the moment any field was `None`, which made EVERY setter write silently
    no-op on every object with no superclass (a `104_getter_setter`-class
    regression #824's own fix introduced).
    """
    t = typename.strip()
    if value is None:
        return t in ("dynamic", "Null", "void") or t.endswith("?")
    m = _GENERIC_TYPE_RE.match(t)
    if m:
        base_type = m.group(1)
        type_args = _split_type_args(m.group(2))
        if base_type == "List" and isinstance(value, list):
            if len(type_args) == 1:
                return all(is_type(e, type_args[0]) for e in value)
            return True
        if base_type == "Map" and isinstance(value, dict):
            if len(type_args) == 2:
                return all(
                    is_type(k, type_args[0]) and is_type(v, type_args[1])
                    for k, v in value.items()
                )
            return True
        if base_type == "Set" and isinstance(value, BallSet):
            if len(type_args) == 1:
                return all(is_type(e, type_args[0]) for e in value)
            return True
        if base_type == "Iterable" and isinstance(value, (list, BallSet)):
            if len(type_args) == 1:
                return all(is_type(e, type_args[0]) for e in value)
            return True
        # A user object (or a dict-tagged self-hosted-engine one): no class
        # match is unambiguous (`"x" is Box<int>` is `false` regardless of
        # reification), but a class match with NO reified type-argument tag
        # is NOT evidence of a mismatch — it is the absence of evidence, and
        # answers `true` exactly like the pre-#824 base-type-only check did.
        if not _class_name_matches(value, base_type):
            return False
        obj_type_args = _reified_type_args(value)
        if obj_type_args is None:
            return True
        if len(obj_type_args) == len(type_args):
            return obj_type_args == type_args
        return False
    if _is_function_type_signature(t):
        return callable(value)
    bt = _base_type_name(t)
    checker = _BUILTIN.get(bt)
    if checker is not None:
        return checker(value)
    if _class_name_matches(value, bt):
        return True
    # `bt` is neither a `_BUILTIN` name nor the name of `value`'s own class:
    # unambiguous evidence of a mismatch ONLY when `value` carries a declared
    # Ball type identity of its own to mismatch against in the first place.
    # A bare runtime primitive (an `int`/`str`/`list`/plain `dict`/`BallSet`,
    # or a plain callable) matched against a name this function does not
    # otherwise model -- a typedef ALIAS (erased before this layer ever sees
    # it; a Ball typedef has no runtime representation at all) or an SDK
    # structural INTERFACE a core type satisfies but `_BUILTIN` does not
    # enumerate (`Comparable`, `Pattern`, ...) -- carries no evidence either
    # way, so it answers like the pre-#824 base-type-only check did: `True`.
    return not _has_declared_identity(value)


def with_type_args(value, type_args):
    """Tag a freshly constructed instance with its reified generic type
    argument(s) (``Box<int>(42)`` -> ``Box(42)`` carrying
    ``__type_args__ == "<int>"``), so :func:`is_type` can later answer a
    generic `is` check against it — issue #824. The encoder emits this as an
    ordinary ``__type_args__`` field on the constructor's ``messageCreation``;
    `_SYNTH_FIELDS` keeps it out of the constructor CALL itself (it is never a
    real parameter), so it is applied here, after construction, instead.
    Returns ``value`` so the call composes in expression position."""
    try:
        value.__type_args__ = type_args
    except AttributeError:
        pass
    return value


def type_of(value) -> str:
    """``std.type_of`` (#489) -- the value's canonical runtime type NAME.

    The string form of the very discrimination :func:`is_type` performs: the
    BASE type name, with generic type arguments dropped and any module prefix
    stripped (``main:Chain`` -> ``Chain``). Both Dart's
    ``value.runtimeType.toString()`` and JavaScript's ``typeof`` encode to this
    function, so it must agree with the Dart reference engine's ``_typeNameOf``.
    """
    if value is None:
        return "Null"
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, int):
        return "int"
    if isinstance(value, float):
        return "double"
    if isinstance(value, str):
        return "String"
    if isinstance(value, (list, tuple)):
        return "List"
    if isinstance(value, BallSet):
        return "Set"
    if isinstance(value, dict):
        # A self-hosted-engine object is a dict tagged with ``__type__``.
        tag = value.get("__type__")
        if isinstance(tag, str) and tag:
            return tag.rsplit(":", 1)[-1]
        return "Map"
    if callable(value):
        return "Function"
    # Any remaining runtime object (RegExp, StringBuffer, a compiled user
    # class, ...) reports its own class name rather than a silent placeholder.
    return type(value).__name__


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
