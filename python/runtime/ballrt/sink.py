"""The declared text sink (issue #630): ``sink_create`` / ``sink_write`` /
``sink_to_string``.

A sink is a ``__type__``-tagged ``dict`` carrying its accumulated text under
``__buffer__``, NOT an ``io.StringIO``. Two properties depend on that, and both
fail SILENTLY when a target gets them wrong:

* :func:`ballrt.type_of` answers ``"Sink"``, because its ``isinstance(value,
  dict)`` arm already reads a ``__type__`` tag. An ``io.StringIO`` backing would
  answer ``"StringIO"`` here and ``"String"``/``"StringBuilder"``/``"Builder"``
  elsewhere, so a Ball program branching on ``type_of`` would take a different
  arm per target.
* A Python ``dict`` is a reference, so an append performed inside a callee is
  visible to the caller. The precedent is issue #300, where a by-value clone lost
  every list append.

Before #630 this target had no sink at all (``grep -r __buffer__ python/`` found
nothing), so a Ball program using a ``StringBuffer`` was refused by the compiler
even though every self-hosted engine runs one fine.
"""

from __future__ import annotations

from .ops import to_str

BALL_SINK_TAG = "std:Sink"
BALL_SINK_BUFFER = "__buffer__"


def sink_create(initial=None):
    """``std.sink_create(initial?)`` — a new text sink, optionally seeded."""
    return {
        "__type__": BALL_SINK_TAG,
        BALL_SINK_BUFFER: "" if initial is None else to_str(initial),
    }


def sink_write(sink, text):
    """``std.sink_write(sink, text)`` — append ``text``.

    Returns ``None``: the observable effect is the in-place mutation, which is
    what makes the sink reference-semantic.
    """
    backing = _sink_backing(sink, "sink_write")
    existing = backing.get(BALL_SINK_BUFFER)
    backing[BALL_SINK_BUFFER] = ("" if existing is None else to_str(existing)) + to_str(text)
    return None


def sink_to_string(sink):
    """``std.sink_to_string(sink)`` — the accumulated text, in write order."""
    backing = _sink_backing(sink, "sink_to_string")
    existing = backing.get(BALL_SINK_BUFFER)
    return "" if existing is None else to_str(existing)


def _sink_backing(sink, function: str):
    """The live backing dict of a sink, or a loud failure.

    Never fabricate an empty sink: silently accepting a non-sink turns every
    mis-routed ``sink_write`` into a discarded write (issue #55's shape).
    """
    if isinstance(sink, dict) and sink.get("__type__") == BALL_SINK_TAG:
        return sink
    raise TypeError(
        f"std.{function}: expected a sink (std.sink_create), got {type(sink).__name__}"
    )
