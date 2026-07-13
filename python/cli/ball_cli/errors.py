"""The CLI error model and the process exit-code contract.

Every verb signals failure by raising :class:`CliError`, which carries its own
process exit code. :func:`ball_cli.cli.run` catches it, prints ``ball: <msg>`` to
stderr, and returns the code. The contract mirrors the Rust/Go CLIs
(``rust/cli/src/error.rs`` / ``go/cli/error.go``) so the four Python verbs behave
identically:

======  ==========================================================================
 Code   Meaning
======  ==========================================================================
 ``0``  success (the absence of a ``CliError``)
 ``1``  runtime error — a program ran but failed, or ``run`` when the self-hosted
        engine is not built (``compiled_engine.py`` absent)
 ``2``  invalid/unparseable program — a bad ``.ball.json`` shape, Python source
        ``encode`` could not turn into a program, a program too malformed to
        compile, or ``check`` found it invalid; also usage errors (unknown
        command/flag, wrong argument count)
 ``3``  file-not-found / other I/O error reading input or writing ``--output``
======  ==========================================================================
"""

from __future__ import annotations

EXIT_OK = 0
EXIT_RUNTIME = 1
EXIT_USAGE = 2  # invalid program OR usage error — the Rust/Go CLIs fold both here
EXIT_IO = 3


class CliError(Exception):
    """A CLI-level failure carrying its own process exit code.

    An empty ``message`` suppresses the ``ball: …`` stderr line (used when the
    failure was already reported), leaving only the exit code.
    """

    def __init__(self, code: int, message: str = "") -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def io_error(message: str) -> CliError:
    """Exit 3: an input file could not be read, or an output could not be written."""
    return CliError(EXIT_IO, message)


def parse_error(message: str) -> CliError:
    """Exit 2: the input was not a valid ``ball.v1.Program`` / encodable Python
    source, a program was too malformed to compile, or ``check`` found it invalid."""
    return CliError(EXIT_USAGE, message)


def usage_error(message: str) -> CliError:
    """Exit 2: a usage error — unknown command/flag, wrong argument count."""
    return CliError(EXIT_USAGE, message)


def runtime_error(message: str) -> CliError:
    """Exit 1: a program executed but failed, or ``run`` cannot run because the
    self-hosted engine is not built in."""
    return CliError(EXIT_RUNTIME, message)
