"""Self-hosted Python Ball engine (epic #445 Phase 4).

Runs Ball programs by compiling the reference engine
(``dart/self_host/engine.ball.json``) through ``ball_compiler`` into the
gitignored ``compiled_engine.py`` (see :mod:`ball_engine.regen`) and driving it
with a thin native wrapper (:mod:`ball_engine.driver`).

The driver/loader are imported lazily via ``__getattr__`` so that
``python -m ball_engine.regen`` (which runs before ``ballrt`` is on the path)
does not trip over the driver's ``import ballrt``.
"""

from __future__ import annotations

__all__ = [
    "run_program_file",
    "run_program_view",
    "load_program_view",
    "load_view_from_json",
]


def __getattr__(name):
    if name in ("run_program_file", "run_program_view"):
        from . import driver
        return getattr(driver, name)
    if name in ("load_program_view", "load_view_from_json"):
        from . import loader
        return getattr(loader, name)
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
