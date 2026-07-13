"""Console output (std.print / std.print_error)."""

from __future__ import annotations

import sys

from .ops import to_str


def print_(message=None):
    sys.stdout.write(to_str(message))
    sys.stdout.write("\n")
    return None


def print_error(message=None):
    sys.stderr.write(to_str(message))
    sys.stderr.write("\n")
    return None


def run_entry(entry):
    """Invoke a compiled program's entry function and flush stdout.

    ``entry`` is the compiled entry function; it takes one input (unused for a
    ``void main()``). A Ball ``throw`` that escapes surfaces as a non-zero exit.
    """
    from .flow import BallThrow

    # A compiled module run standalone (`python out.py`) may print non-ASCII;
    # force UTF-8 so a cp1252 Windows console does not raise UnicodeEncodeError.
    # Mirrors ball_cli/__main__.py so both entry paths share one contract.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")
        except (AttributeError, ValueError):
            pass

    try:
        entry(None)
    except BallThrow as ex:
        sys.stderr.write("Unhandled exception: " + to_str(ex.value) + "\n")
        sys.stdout.flush()
        sys.exit(1)
    sys.stdout.flush()
