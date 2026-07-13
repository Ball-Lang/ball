"""ball_encoder — the Python → Ball encoder (Ball epic #445, Phase 3).

Parses Python source with the standard library :mod:`ast` and emits a Ball
``Program`` as the raw proto3-JSON dict view the Ball → Python compiler
(``python/compiler``) consumes. It is the inverse of that compiler; see
:mod:`ball_encoder.encoder` for the construct coverage and invariants.

    from ball_encoder import encode, EncodeError
    program = encode("print('hi')")   # -> proto3-JSON Program dict
"""

from __future__ import annotations

from .encoder import EncodeError, encode

__all__ = ["encode", "EncodeError"]
