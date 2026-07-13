"""``ball compile <program.ball.json> [-o out.py]`` — Ball -> Python source.

Loads the program and compiles it to runnable Python via ``python/compiler``,
writing to ``-o`` or stdout. The compiler fails loud (issue #55): an unsupported
expression shape or base function raises ``CompileError``, surfaced here as an
invalid-program error (exit 2), never silently-wrong code.
"""

from __future__ import annotations

from typing import TextIO

from ..argparse_util import StreamParser
from ..errors import parse_error
from ..loader import load_program_dict
from ..output import write_output


def command(args: list[str], stdout: TextIO, stderr: TextIO) -> int:
    parser = StreamParser(
        prog="ball compile",
        description="Compile a Ball program (.ball.json) to Python source.",
        out=stdout,
        err=stderr,
    )
    parser.add_argument("input", metavar="<program.ball.json>", help="path to a .ball.json program")
    parser.add_argument(
        "-o", "--output", metavar="<out.py>",
        help="write the generated Python source here instead of stdout",
    )
    ns = parser.parse_args(args)

    program = load_program_dict(ns.input)

    from ball_compiler import CompileError, compile_program

    try:
        source = compile_program(program)
    except CompileError as ex:
        raise parse_error(f"compile: {ex}") from ex

    write_output(ns.output, source, stdout)
    return 0
