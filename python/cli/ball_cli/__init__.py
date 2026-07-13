"""``ball_cli`` — the ``ball`` command-line interface for the Python toolchain.

Public API: :func:`ball_cli.cli.run` (``run(argv, stdout, stderr) -> int``), the
in-process entry point every test drives. ``python -m ball_cli`` / the ``ball``
console script wrap it.
"""

from __future__ import annotations

from .cli import run

__all__ = ["run"]
