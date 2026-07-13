"""``ball`` / ``python -m ball_cli`` — the thin binary entry point.

Forwards ``argv`` and the process exit code; all logic lives in
:func:`ball_cli.cli.run` so the CLI stays testable in-process.
"""

from __future__ import annotations

import sys

from .cli import run


def main(argv: list[str] | None = None) -> int:
    # Ball programs may print non-ASCII; force UTF-8 so a cp1252 Windows console
    # does not raise UnicodeEncodeError on `run` output.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")
        except (AttributeError, ValueError):
            pass
    return run(sys.argv[1:] if argv is None else argv, sys.stdout, sys.stderr)


if __name__ == "__main__":
    raise SystemExit(main())
