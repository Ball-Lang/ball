"""Drive the compiled self-hosted engine over a target program.

Constructs the compiled ``BallEngine`` (the 16-arg constructor: the program
view, an stdout callback capturing each printed line, permissive limits, and a
``StdModuleHandler``), then calls the compiled instance ``run``. The Python
sibling of ``go/engine/compiled/driver.go`` and ``csharp/engine``'s
``RunSelfHosted``.

The compiled engine is a deep tree-walker-on-tree-walker, so it is driven on a
worker thread with a large C stack and a lifted Python recursion limit; a Ball
``throw`` / unhandled error that escapes surfaces as an exception to the caller.
"""

from __future__ import annotations

import sys
import threading

import ballrt

from .loader import load_program_view

# A large native stack + recursion budget for the tree-walk-on-tree-walk. The
# engine's methods carry big frames (hundreds of field-alias locals), so the
# default 1000-frame limit is nowhere near enough. Windows caps/aligns the thread
# stack size, so try progressively smaller values.
_STACK_CANDIDATES = (256 * 1024 * 1024, 128 * 1024 * 1024, 64 * 1024 * 1024, 32 * 1024 * 1024)
_RECURSION_LIMIT = 200_000


def _set_stack_size():
    for size in _STACK_CANDIDATES:
        try:
            threading.stack_size(size)
            return
        except (ValueError, OSError):
            continue


def compiled_engine():
    """The compiled self-hosted engine module.

    Two sources, in order:

    1. ``ball_engine.compiled_engine`` — the gitignored artifact
       ``python -m ball_engine.regen`` writes next to this file. Present in a
       checkout that has regenerated it; this is what the conformance sweep and
       every CI leg exercise, so that path is unchanged.
    2. :func:`ball_engine.bootstrap.load_engine` — compiles the Ball engine
       source (bundled in the ``ball-lang`` wheel as package data, or found in
       the surrounding checkout) into a per-user cache dir on first use. This is
       the only path an installed wheel has, since generated code is never
       shipped (issue #496).

    A failure in (2) raises :class:`ball_engine.bootstrap.BootstrapError` with an
    actionable message, which the CLI reports as a clean ``ball: …`` error.
    """
    try:
        from . import compiled_engine as ce  # gitignored; absent on a fresh checkout

        return ce
    except ImportError as ex:
        name = getattr(ex, "name", "") or ""
        if not (name.endswith("compiled_engine") or "compiled_engine" in str(ex)):
            raise  # a genuine import failure INSIDE the generated module
    from . import bootstrap

    return bootstrap.load_engine()


def run_program_view(view, timeout_ms=None):
    """Run a loaded program view through the available engine; return stdout lines."""
    return run_with_engine(compiled_engine(), view, timeout_ms)


def run_with_engine(ce, view, timeout_ms=None):
    """Run ``view`` through an explicitly supplied compiled-engine module.

    Split out of :func:`run_program_view` so a caller can pin which engine module
    is used — the bootstrap test drives the cache-compiled one even in a tree
    that also has a regenerated ``compiled_engine.py``.
    """
    out: list[str] = []
    box: dict[str, BaseException] = {}

    def stdout(msg):
        out.append(ballrt.to_str(msg))

    def target():
        try:
            sys.setrecursionlimit(_RECURSION_LIMIT)
            handler = ce.StdModuleHandler()
            engine = ce.BallEngine(
                view,            # program
                stdout,          # stdout
                None,            # stderr
                None,            # stdinReader
                None,            # envGet
                [],              # args
                False,           # enableProfiling
                1_000_000,       # maxRecursionDepth
                timeout_ms,      # timeoutMs
                None,            # maxMemoryBytes
                1_000_000,       # maxModules
                1_000_000,       # maxExpressionDepth
                None,            # maxProgramSizeBytes
                False,           # sandbox
                [handler],       # moduleHandlers
                None,            # resolver
            )
            engine.run(None)
        except BaseException as exc:  # noqa: BLE001 — surfaced to the caller
            box["e"] = exc

    _set_stack_size()
    t = threading.Thread(target=target)
    t.start()
    t.join()
    if "e" in box:
        raise box["e"]
    return out


def run_program_file(path, timeout_ms=None):
    return run_program_view(load_program_view(path), timeout_ms)
