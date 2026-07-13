"""``ballpyc`` — the Ball → Python compiler CLI.

    python -m ball_compiler <program.ball.json> [-o out.py]

Writes the compiled Python module to ``-o`` (or stdout). Exit codes follow the
Ball CLI convention: 0 success, 2 compile error, 3 I/O error.
"""

from __future__ import annotations

import argparse
import sys

from .compiler import CompileError, compile_program
from .loader import load_program


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="ballpyc", description="Compile a Ball program (.ball.json) to Python source.")
    parser.add_argument("input", help="path to a .ball.json program")
    parser.add_argument("-o", "--output", help="output .py path (default: stdout)")
    args = parser.parse_args(argv)

    try:
        program = load_program(args.input)
    except OSError as ex:
        print(f"ballpyc: cannot read {args.input}: {ex}", file=sys.stderr)
        return 3

    try:
        source = compile_program(program)
    except CompileError as ex:
        print(f"ballpyc: {ex}", file=sys.stderr)
        return 2

    if args.output:
        try:
            with open(args.output, "w", encoding="utf-8") as fh:
                fh.write(source)
        except OSError as ex:
            print(f"ballpyc: cannot write {args.output}: {ex}", file=sys.stderr)
            return 3
    else:
        sys.stdout.write(source)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
