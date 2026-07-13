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


def run_program_view(view, timeout_ms=None):
    """Run a loaded program view; return the captured stdout lines."""
    from . import compiled_engine as ce  # gitignored; absent on a fresh checkout

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
