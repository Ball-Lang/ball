"""A stdlib :mod:`argparse` parser wired into the CLI's injected streams.

The whole CLI is exercisable in-process through :func:`ball_cli.cli.run` (the
Go/Rust pattern), so it must never call :func:`sys.exit` or write to the real
``sys.stdout``/``sys.stderr``. :class:`StreamParser` routes ``argparse``'s help
and diagnostics to the streams ``run`` was handed, and converts ``argparse``'s
two exit paths into exceptions the caller maps to exit codes:

* a bad flag / missing argument -> :class:`~ball_cli.errors.CliError` (exit 2);
* ``-h``/``--help`` -> :class:`HelpRequested` after the help text is printed to
  the command's stdout (exit 0).
"""

from __future__ import annotations

import argparse
import sys

from .errors import EXIT_USAGE, CliError


class HelpRequested(Exception):
    """Raised (instead of ``SystemExit``) when ``-h``/``--help`` was handled."""


class StreamParser(argparse.ArgumentParser):
    """An ``ArgumentParser`` that prints to injected streams and never exits."""

    def __init__(self, *args, out, err, **kwargs) -> None:
        self._out = out
        self._err = err
        super().__init__(*args, **kwargs)

    def _print_message(self, message: str, file=None) -> None:
        if not message:
            return
        # argparse prints help with file=sys.stdout and everything else to
        # stderr; route accordingly onto the command's own streams.
        stream = self._out if file is sys.stdout else self._err
        stream.write(message)

    def exit(self, status: int = 0, message: str | None = None) -> None:  # noqa: A003
        if message:
            self._err.write(message)
        # The only argparse-initiated clean exit is --help (status 0); any other
        # status is a failure (the message, if any, is already on stderr).
        if status == 0:
            raise HelpRequested()
        raise CliError(status, "")

    def error(self, message: str) -> None:
        raise CliError(EXIT_USAGE, f"{self.prog}: {message}")
