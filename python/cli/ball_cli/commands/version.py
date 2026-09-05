"""``ball version`` — print ``ball <version>`` (issue #570).

The line comes from the self-hosted CLI core (``cli_core.versionLine``, whose
whole logic is ``"ball " + version``), so the FORMAT is the portable one every
``ball`` shares rather than a Python re-write.

**VERSION POLICY** (issue #366): each CLI reports its OWN registry's package
version. Python's registry is PyPI, so this is ``ball_cli.__version__`` — the
installed ``ball-lang`` distribution version, or ``0.0.0+source`` in a checkout.

**Relationship to the ``--version`` FLAG**: they are deliberately different and
both exist, exactly as they do for Rust (clap's built-in ``--version`` alongside
a ``version`` subcommand). ``ball --version`` is this toolchain's own banner
(``ball <v> (Python toolchain)``); ``ball version`` is the PORTABLE line every
``ball`` prints identically. The flag is handled in :mod:`ball_cli.cli`'s
dispatch before subcommand lookup, so the two never collide.
"""

from __future__ import annotations

from typing import TextIO

from .. import __version__
from ..argparse_util import StreamParser
from ..cli_core import reports


def command(args: list[str], stdout: TextIO, stderr: TextIO) -> int:
    parser = StreamParser(
        prog="ball version",
        description="Print the CLI version (the portable cli-core line).",
        out=stdout,
        err=stderr,
    )
    # No positional: unlike info/validate/tree, `version` takes no program. The
    # parser rejects any extra argument with the usual usage error (exit 2).
    parser.parse_args(args)

    stdout.write(reports().versionLine(__version__) + "\n")
    return 0
