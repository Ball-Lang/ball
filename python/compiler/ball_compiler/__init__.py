"""ball_compiler — the Ball → Python compiler.

Public API:

* :func:`~ball_compiler.compiler.compile_program` — compile a raw proto3-JSON
  ``Program`` dict to Python source.
* :func:`~ball_compiler.loader.load_program` — load a ``.ball.json`` file to that
  dict view.
* :class:`~ball_compiler.compiler.CompileError` — raised (fail-loud) on any
  unsupported construct.

The ``python -m ball_compiler`` front-end (``ballpyc``) wraps both.
"""

from __future__ import annotations

from .compiler import CompileError, Compiler, compile_program
from .loader import load_program

__all__ = ["CompileError", "Compiler", "compile_program", "load_program"]
