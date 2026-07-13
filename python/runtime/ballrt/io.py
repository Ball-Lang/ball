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

    try:
        entry(None)
    except BallThrow as ex:
        sys.stderr.write("Unhandled exception: " + to_str(ex.value) + "\n")
        sys.stdout.flush()
        sys.exit(1)
    sys.stdout.flush()
