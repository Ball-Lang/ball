"""``ball encode <source.py> [-o out.ball.json]`` — Python -> Ball program.

Reads a Python source file, encodes it into a ``ball.v1.Program`` via
``python/encoder``, and writes it as ``@type``-enveloped proto3 JSON (a drop-in
``.ball.json`` every loader accepts — the Dart/TS/Go loaders and
``python/compiler`` all strip the ``@type`` key). Mirrors the ``ballpyenc``
front-end's serialization exactly.

The encoder fails loud: source it cannot represent (an unsupported construct
outside its documented scope — see ``python/encoder/AGENTS.md``) raises
``EncodeError``, surfaced here as an invalid-program error (exit 2), never a
placeholder program.
"""

from __future__ import annotations

import json
from typing import TextIO

from ..argparse_util import StreamParser
from ..errors import io_error, parse_error
from ..output import write_output


def command(args: list[str], stdout: TextIO, stderr: TextIO) -> int:
    parser = StreamParser(
        prog="ball encode",
        description="Encode a Python source file into a Ball program (.ball.json).",
        out=stdout,
        err=stderr,
    )
    parser.add_argument("input", metavar="<source.py>", help="path to a .py source file")
    parser.add_argument(
        "-o", "--output", metavar="<out.ball.json>",
        help="write the encoded program here instead of stdout",
    )
    ns = parser.parse_args(args)

    try:
        with open(ns.input, encoding="utf-8") as fh:
            source = fh.read()
    except OSError as ex:
        raise io_error(f"could not read {ns.input}: {ex}") from ex

    from ball_encoder import EncodeError, encode

    try:
        program = encode(source)
    except EncodeError as ex:
        raise parse_error(f"encode: {ex}") from ex

    enveloped = {"@type": "type.googleapis.com/ball.v1.Program", **program}
    text = json.dumps(enveloped, indent=2, ensure_ascii=False) + "\n"
    write_output(ns.output, text, stdout)
    return 0
