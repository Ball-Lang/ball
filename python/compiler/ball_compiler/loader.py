"""Loading Ball programs from disk into the raw proto3-JSON dict view.

The compiler walks the proto3-JSON representation of a ``Program`` directly as
nested ``dict``s / ``list``s (camelCase keys — ``entryModule``, ``typeName``,
``messageCreation`` …), exactly as the Go loader uses its raw-JSON view. This
keeps the compiler free of a protobuf runtime dependency; ``.ball.json`` is the
canonical input. A ``.ball.json`` may be wrapped in a ``google.protobuf.Any``
envelope (``{"@type": ".../ball.v1.Program", …}``); the ``@type`` key is
stripped on load.
"""

from __future__ import annotations

import json
from pathlib import Path


def unwrap_any(obj):
    """Drop a ``google.protobuf.Any`` ``@type`` envelope key if present."""
    if isinstance(obj, dict) and "@type" in obj:
        return {k: v for k, v in obj.items() if k != "@type"}
    return obj


def load_program(path: str | Path) -> dict:
    """Load a ``.ball.json`` program into its raw proto3-JSON dict view."""
    p = Path(path)
    text = p.read_text(encoding="utf-8")
    return unwrap_any(json.loads(text))
