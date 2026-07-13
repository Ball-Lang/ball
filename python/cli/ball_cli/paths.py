"""Locate the sibling Ball Python packages and put them on ``sys.path``.

The Python packages are deliberately isolated — there is no workspace manager;
each is consumed from a plain checkout via ``PYTHONPATH`` (see
``python/AGENTS.md``, the engine's ``__main__._bootstrap_paths``, and the
compiler/encoder ``conftest.py``). The CLI is a fifth package that imports the
other four, so it does the same bootstrap once at startup: walk up to the repo
root (marked by ``proto/ball/v1/ball.proto``) and prepend the sibling package
directories.

The bootstrap is best-effort: outside a checkout (e.g. a ``pip install``ed
``ball`` whose dependencies are already importable) it is a no-op, and per-verb
imports surface any genuinely missing package themselves.
"""

from __future__ import annotations

import sys
from pathlib import Path

# The sibling package roots, in the order the engine needs them: the runtime
# (ballrt) and the generated protobuf binding (ball.v1) must precede the engine,
# which imports both.
_SIBLINGS = (
    ("python", "runtime"),       # ballrt
    ("python", "shared", "gen"),  # ball.v1.ball_pb2
    ("python", "engine"),         # ball_engine
    ("python", "compiler"),       # ball_compiler
    ("python", "encoder"),        # ball_encoder
)


def repo_root() -> Path | None:
    """Walk up from this file to the repo root (``proto/ball/v1/ball.proto``).

    Returns ``None`` when not inside a checkout — the same marker the engine's
    regen tool and the Go CLI's test helper use."""
    d = Path(__file__).resolve().parent
    while d != d.parent:
        if (d / "proto" / "ball" / "v1" / "ball.proto").exists():
            return d
        d = d.parent
    return None


def bootstrap_sys_path() -> None:
    """Prepend the sibling package directories to ``sys.path`` (idempotent)."""
    root = repo_root()
    if root is None:
        return
    for parts in _SIBLINGS:
        p = str(root.joinpath(*parts))
        if p not in sys.path:
            sys.path.insert(0, p)
