"""``ball tree <program.ball.json>`` — print the module/import tree (issue #570).

Delegates to the self-hosted CLI core's ``cli_core.treeReport`` (see
:mod:`ball_cli.cli_core`), byte-identical to the Dart CLI's ``tree``. The Python
sibling of ``rust/cli/src/commands/tree.rs`` and ``go/cli/tree.go``.
"""

from __future__ import annotations

from typing import TextIO

from ..argparse_util import StreamParser
from ..cli_core import program_view, reports


def command(args: list[str], stdout: TextIO, stderr: TextIO) -> int:
    parser = StreamParser(
        prog="ball tree",
        description="Print a Ball program's module/import tree.",
        out=stdout,
        err=stderr,
    )
    parser.add_argument("input", metavar="<program.ball.json>", help="path to a .ball.json program")
    ns = parser.parse_args(args)

    view = program_view(ns.input)
    stdout.write(reports().treeReport(view) + "\n")
    return 0
