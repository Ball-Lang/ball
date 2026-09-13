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
