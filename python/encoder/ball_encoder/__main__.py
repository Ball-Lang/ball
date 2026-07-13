"""``ballpyenc`` — the Python → Ball encoder CLI front-end.

    python -m ball_encoder <src.py> [-o out.ball.json]

Encodes a Python source file to a Ball program and writes it as
``@type``-enveloped proto3 JSON (a drop-in ``.ball.json`` every loader accepts —
the Dart/TS/Go loaders and ``python/compiler`` all strip the ``@type`` key).
Exit codes follow the Ball CLI convention: 0 success, 2 encode error, 3 I/O
error.
"""

from __future__ import annotations

import argparse
import json
import sys

from .encoder import EncodeError, encode


def _with_type_envelope(program: dict) -> dict:
    """Prepend the ``google.protobuf.Any`` ``@type`` discriminator the committed
    ``.ball.json`` fixtures carry, so the output round-trips through every loader."""
    return {"@type": "type.googleapis.com/ball.v1.Program", **program}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="ballpyenc", description="Encode a Python source file to a Ball program (.ball.json).")
    parser.add_argument("input", help="path to a .py source file")
    parser.add_argument("-o", "--output", help="output .ball.json path (default: stdout)")
    args = parser.parse_args(argv)

    try:
        with open(args.input, encoding="utf-8") as fh:
            source = fh.read()
    except OSError as ex:
        print(f"ballpyenc: cannot read {args.input}: {ex}", file=sys.stderr)
        return 3

    try:
        program = encode(source)
    except EncodeError as ex:
        print(f"ballpyenc: {ex}", file=sys.stderr)
        return 2

    text = json.dumps(_with_type_envelope(program), indent=2, ensure_ascii=False) + "\n"
    if args.output:
        try:
            with open(args.output, "w", encoding="utf-8") as fh:
                fh.write(text)
        except OSError as ex:
            print(f"ballpyenc: cannot write {args.output}: {ex}", file=sys.stderr)
            return 3
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
