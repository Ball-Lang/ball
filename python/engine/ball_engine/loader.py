"""Load a target Ball program into the canonical proto3-JSON view the compiled
self-hosted engine reads through the ``ball_proto`` access-pattern functions.

The Python sibling of ``go/engine/loader.go`` / ``csharp/engine/src/Loader.cs`` /
``rust/engine/src/loader.rs``: parse the ``.ball.json`` into the generated
``Program`` protobuf (materialising proto3 defaults — an absent ``inputType``
becomes ``""``, an absent repeated field ``[]``, which the engine relies on),
then post-process the resulting dict to the exact shape the engine expects:

* ``intValue`` (a proto3 int64 that JSON renders as a *string*) -> a Python
  ``int`` (the engine does ``lit.intValue.toInt()``).
* ``doubleValue`` -> forced to a Python ``float``.
* ``bytesValue`` (base64) -> a ``list[int]`` of byte values.
* every ``metadata`` field -> re-expanded from its collapsed proto3-JSON object to
  the raw ``google.protobuf.Struct`` shape (``{fields: {key: {stringValue: …}}}``),
  because the engine reads ``func.metadata.fields['kind'].stringValue``.

The generated protobuf binding is used only here (the engine package), never by
the zero-dependency ``ballrt`` runtime. A ``google.protobuf.Any`` ``@type``
envelope is stripped first.
"""

from __future__ import annotations

import base64
import json
from pathlib import Path

from google.protobuf import json_format

from ball.v1 import ball_pb2


def load_program_view(path: str | Path) -> dict:
    return load_view_from_json(Path(path).read_text(encoding="utf-8"))


def load_view_from_json(text: str) -> dict:
    obj = _unwrap_any(json.loads(text))
    program = ball_pb2.Program()
    json_format.ParseDict(obj, program, ignore_unknown_fields=True)
    raw = _to_dict_with_defaults(program)
    return _normalize(raw, None)


def _unwrap_any(obj):
    if isinstance(obj, dict) and "@type" in obj:
        return {k: v for k, v in obj.items() if k != "@type"}
    return obj


def _to_dict_with_defaults(msg) -> dict:
    # Materialise proto3 defaults so an absent singular field reads as its default
    # (the kwarg was renamed across protobuf major versions).
    try:
        return json_format.MessageToDict(msg, always_print_fields_with_no_presence=True)
    except TypeError:
        return json_format.MessageToDict(msg, including_default_value_fields=True)


# ── Post-processing (int64 / double / bytes / metadata Struct) ───────────────

def _normalize(v, key):
    if isinstance(v, dict):
        if key == "metadata":
            return _wrap_struct(v)
        return {k: _normalize(val, k) for k, val in v.items()}
    if isinstance(v, list):
        return [_normalize(x, None) for x in v]
    if isinstance(v, str):
        if key == "intValue":
            return int(v)
        if key == "bytesValue":
            return list(base64.b64decode(v))
        return v
    if isinstance(v, bool):
        return v
    if isinstance(v, (int, float)):
        if key == "doubleValue":
            return float(v)
        return v
    return v


def _wrap_struct(m: dict) -> dict:
    return {"fields": {k: _wrap_value(v) for k, v in m.items()}}


def _wrap_value(v):
    if v is None:
        return {"nullValue": 0}
    if isinstance(v, bool):
        return {"boolValue": v}
    if isinstance(v, (int, float)):
        return {"numberValue": float(v)}
    if isinstance(v, str):
        return {"stringValue": v}
    if isinstance(v, list):
        return {"listValue": {"values": [_wrap_value(x) for x in v]}}
    if isinstance(v, dict):
        return {"structValue": _wrap_struct(v)}
    return {"stringValue": str(v)}
