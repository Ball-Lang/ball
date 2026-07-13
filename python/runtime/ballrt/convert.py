"""``std_convert`` — UTF-8 / base64 / JSON codecs (namespaced ``ballrt.cvt.*``).

Dart's ``dart:convert`` models bytes as ``List<int>`` (0-255), which is how the
engine passes and expects them; these helpers mirror that.
"""

from __future__ import annotations

import base64 as _base64
import json as _json


def _to_bytes(v) -> bytes:
    if isinstance(v, (bytes, bytearray)):
        return bytes(v)
    if isinstance(v, list):
        return bytes(b & 0xFF for b in v)
    if isinstance(v, str):
        return v.encode("utf-8")
    raise TypeError(f"ball: cannot treat {type(v).__name__} as bytes")


def utf8_encode(v):
    """UTF-8 encode a string to a Dart ``List<int>`` of byte values."""
    return list(v.encode("utf-8"))


def utf8_decode(v):
    """UTF-8 decode a byte list / bytes to a string."""
    return _to_bytes(v).decode("utf-8")


def base64_encode(v):
    return _base64.b64encode(_to_bytes(v)).decode("ascii")


def base64_decode(v):
    return list(_base64.b64decode(v))


def json_encode(v):
    from .ops import to_str  # deferred: avoid a runtime import cycle

    def default(o):
        return to_str(o)

    return _json.dumps(v, separators=(",", ":"), ensure_ascii=False, default=default)


def json_decode(v):
    return _json.loads(v)
