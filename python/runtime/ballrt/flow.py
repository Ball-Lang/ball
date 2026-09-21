"""Flow signals for break / continue / return / throw.

Ball's control flow is a set of base functions (invariant #4), and the
non-local jumps they express (``return``/``break``/``continue``/``throw``) are
modelled here as Python exceptions. This is the natural device: the compiler
emits helper *calls* (``ret``/``brk``/``cont``/``throw``) rather than Python
statements, so a jump is a valid Python expression usable in both statement and
value position, and it propagates across nested-``def`` / lambda boundaries the
way a bare Python ``return`` never could.

Function bodies catch :class:`BallReturn`; loop bodies catch :class:`BallBreak`
and :class:`BallContinue`; a ``try`` catches :class:`BallThrow`.
"""

from __future__ import annotations


class BallReturn(Exception):
    """A ``std.return`` — unwinds to the enclosing function."""

    __slots__ = ("value",)

    def __init__(self, value=None):
        self.value = value


class BallBreak(Exception):
    """A ``std.break`` — unwinds to the enclosing (optionally labelled) loop."""

    __slots__ = ("label",)

    def __init__(self, label=""):
        self.label = label or ""


class BallContinue(Exception):
    """A ``std.continue`` — advances the enclosing (optionally labelled) loop."""

    __slots__ = ("label",)

    def __init__(self, label=""):
        self.label = label or ""


class BallThrow(Exception):
    """A Ball ``throw`` carrying an arbitrary Ball payload."""

    __slots__ = ("value",)

    def __init__(self, value=None):
        self.value = value


# The stack of currently-caught throw payloads, so ``rethrow`` inside a catch
# clause re-raises the value being handled.
_caught: list = []


def ret(value=None):
    """Raise :class:`BallReturn`. Returns nothing — it always raises."""
    raise BallReturn(value)


def brk(label=""):
    raise BallBreak(label)


def cont(label=""):
    raise BallContinue(label)


def throw(value=None):
    raise BallThrow(value)


def state_error(message):
    """Throw Dart's ``StateError`` — the ONE way every site raises it (#616).

    An empty ``.first``/``.last``/``removeLast``/``reduce``, or a ``firstWhere``
    with no match and no ``orElse``. Two halves, and the sites used to get one
    or the other:

    * TYPED — the thrown value is a Dart-shaped ``StateError``, so a program's
      own ``on StateError catch`` matches it. ``list_first``/``list_last``
      used to let Python's native ``IndexError`` escape, which is not a
      :class:`BallThrow` at all, so the compiled ``try`` never saw it; the
      ``reduce``/``firstWhere`` method arms threw a bare STRING, which reports
      runtimeType ``String`` and matches no typed clause.
    * OBSERVABLE — it stringifies as Dart's own ``StateError.toString()``,
      ``Bad state: <message>`` (see :class:`~ballrt.selfhost.StateError`), so
      ``to_string(e)`` in the catch body reads the same here as on the Dart
      reference engine.

    ``StateError`` is imported lazily: ``selfhost`` imports this module.
    """
    from .selfhost import StateError

    raise BallThrow(StateError(message))


def rethrow():
    if _caught:
        raise BallThrow(_caught[-1])
    raise BallThrow(None)


# ── Typed `on <Type> catch` dispatch (issue #724) ───────────────────────────
#
# The compiler lowers a `try`'s clause list to an `if`/`elif` chain over
# :func:`catch_matches`, so the clause-selection RULE lives here — one place,
# shared by every compiled program — exactly as Go's ``ballrt.CatchMatches``
# and Rust's ``ball_catch_matches`` do for the same lowering (issue #615).

#: Payload kinds that carry no type tag of their own. A thrown string / number /
#: bool / list / tuple / set is ``std.throw``'s untagged case.
_UNTAGGED_BUILTINS = (str, bytes, bytearray, bool, int, float, complex,
                      list, tuple, set, frozenset)


def _reports_own_type_name(thrown) -> bool:
    """Whether a runtime OBJECT payload names its own exception type.

    A class the *program* defines (a compiled user class) always does. A class
    the RUNTIME defines does only when it is one of the Dart-shaped error types
    — ``FormatException`` / ``RangeError`` / ``ArgumentError`` / ``IndexError``
    from :mod:`ballrt.dart_errors`, and ``StateError`` from
    :mod:`ballrt.selfhost`. Every other runtime class is a *value* container
    (``BallSet``, ``StringBuffer``, ``RegExp``, …), which the reference engine
    sees as an untagged payload, so it must not answer a typed clause.

    Both modules are imported lazily: each of them imports this one.
    """
    module = getattr(type(thrown), "__module__", "") or ""
    if not module.startswith("ballrt."):
        return True
    from . import dart_errors
    from .selfhost import StateError

    return isinstance(thrown, (dart_errors.Exception, dart_errors.Error, StateError))


def exception_type_name(thrown) -> str:
    """The type tag a typed ``on <Type> catch`` clause matches ``thrown`` against.

    Follows the reference engine's rule (``std.throw`` in
    ``dart/engine/lib/engine_std.dart``, read back by ``_evalLazyTry``): a
    ``__type__``-tagged map reports its tag, an exception object reports its
    class name, and anything untagged reports ``std.throw``'s own default,
    ``Exception``.
    """
    if isinstance(thrown, dict):
        tag = thrown.get("__type__")
        if isinstance(tag, str) and tag:
            return tag
        return "Exception"
    if thrown is None or isinstance(thrown, _UNTAGGED_BUILTINS) or callable(thrown):
        return "Exception"
    if _reports_own_type_name(thrown):
        return type(thrown).__name__
    return "Exception"


def catch_matches(thrown, type_name: str) -> bool:
    """Whether an ``on <Type> catch`` clause declaring ``type_name`` handles
    ``thrown``.

    A thrown value's tag may be module-qualified (``main:StateError``) while the
    clause names the bare type, so BOTH spellings match — exactly what
    ``_evalLazyTry`` does in the reference engine. An untyped ``catch (e)``
    clause is never routed through here: it matches unconditionally.
    """
    actual = exception_type_name(thrown)
    if actual == type_name:
        return True
    index = actual.find(":")
    return index >= 0 and actual[index + 1:] == type_name
