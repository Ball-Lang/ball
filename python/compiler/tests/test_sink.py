"""The declared text sink (issue #630): ``sink_create``/``sink_write``/``sink_to_string``.

Both properties pinned here fail SILENTLY when a target gets them wrong:

1. ``std.type_of`` answers ``"Sink"`` — never the host type. A bare
   ``io.StringIO`` backing would answer ``"StringIO"`` here and diverge from the
   reference engine and every other target, so a Ball program branching on
   ``type_of`` would take a different arm per target.
2. The sink is REFERENCE-SEMANTIC: a value handed to another function and
   appended to there is observably longer to the caller. Precedent: issue #300,
   where a by-value clone lost every list append.

Before #630 this target had no sink at all — ``grep -r __buffer__ python/`` found
nothing — so a Ball program using a ``StringBuffer`` was refused by the compiler,
even though every self-hosted engine runs one fine (an engine's own sink is
compiled ``engine_std.dart``, not the compiler's dispatch table).
"""

from __future__ import annotations

import ballrt


def test_sink_is_a_tagged_reference_value():
    sink = ballrt.sink_create()

    assert ballrt.type_of(sink) == "Sink"

    ballrt.sink_write(sink, "a")

    # The by-value trap: hand the sink to a callee and append there.
    def append(s):
        ballrt.sink_write(s, "b")

    append(sink)

    assert ballrt.sink_to_string(sink) == "ab"


def test_sink_create_seeds_from_initial():
    sink = ballrt.sink_create("x")
    ballrt.sink_write(sink, "y")
    assert ballrt.sink_to_string(sink) == "xy"
