"""``ball info <program.ball.json>`` — print a program's structure (issue #570).

The report text is not written here: it comes from the self-hosted CLI core
(``cli_core.infoReport``, compiled through the Ball → Python compiler — see
:mod:`ball_cli.cli_core`), so it is byte-identical to what the Dart CLI prints.
The Python sibling of ``rust/cli/src/commands/info.rs`` and ``go/cli/info.go``.

The program is LOADED before the CLI core is resolved, so a missing file (exit 3)
or a malformed program (exit 2) reports its own, more specific failure rather
than being masked by the "CLI core not built" message.
"""

from __future__ import annotations

from typing import TextIO

from ..argparse_util import StreamParser
from ..cli_core import program_view, reports


def command(args: list[str], stdout: TextIO, stderr: TextIO) -> int:
    parser = StreamParser(
        prog="ball info",
        description="Print a Ball program's structure (modules, types, functions).",
        out=stdout,
        err=stderr,
    )
    parser.add_argument("input", metavar="<program.ball.json>", help="path to a .ball.json program")
    ns = parser.parse_args(args)

    view = program_view(ns.input)
    stdout.write(reports().infoReport(view) + "\n")
    return 0
