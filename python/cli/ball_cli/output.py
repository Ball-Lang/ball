"""Shared output helper: write to ``-o <file>`` or the command's stdout."""

from __future__ import annotations

from pathlib import Path
from typing import TextIO

from .errors import io_error


def write_output(out_path: str | None, content: str, stdout: TextIO) -> None:
    """Write ``content`` to ``out_path``, or to ``stdout`` when it is falsy.

    Shared by ``compile`` (Python source) and ``encode`` (JSON text). A write
    failure to ``--output`` is an I/O error (exit 3)."""
    if out_path:
        try:
            Path(out_path).write_text(content, encoding="utf-8")
        except OSError as ex:
            raise io_error(f"could not write {out_path}: {ex}") from ex
    else:
        stdout.write(content)
