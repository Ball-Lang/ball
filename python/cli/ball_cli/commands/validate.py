"""``ball validate <program.ball.json>`` — the portable validation report (#570).

Delegates to the self-hosted CLI core's ``cli_core.validateOk`` /
``cli_core.validateReport`` (see :mod:`ball_cli.cli_core`), so the text matches
the Dart CLI's ``validate`` exactly.

**Exit-code note** — the same adaptation ``rust/cli/src/commands/validate.rs``
and ``go/cli/validate.go`` make: the Dart CLI exits 1 on an invalid program (its
generic "command failed" code; the Dart runner has no exit-code contract of its
own), while this CLI's contract (:mod:`ball_cli.errors`) reserves 1 for a
*runtime* failure and 2 for an *invalid/unparseable program*. A failed
``validate`` is squarely the latter, so it raises ``parse_error`` (exit 2). Only
the numeric code is adapted; the report text is not.

``validate`` is distinct from ``check``: ``check`` is this CLI's own
Python-target battery (with an opt-in dry-run compile); ``validate`` is the
PORTABLE report every cli-core ``ball`` shares.
"""

from __future__ import annotations

from typing import TextIO

from ..argparse_util import StreamParser
from ..cli_core import program_view, reports
from ..errors import parse_error


def command(args: list[str], stdout: TextIO, stderr: TextIO) -> int:
    parser = StreamParser(
        prog="ball validate",
        description="Validate a Ball program and print the portable cli-core report.",
        out=stdout,
        err=stderr,
    )
    parser.add_argument("input", metavar="<program.ball.json>", help="path to a .ball.json program")
    ns = parser.parse_args(args)

    view = program_view(ns.input)
    core = reports()
    report = core.validateReport(view)
    if not core.validateOk(view):
        raise parse_error(report)
    stdout.write(report + "\n")
    return 0
