"""Shared pytest fixtures: import paths + a compile-and-run helper.

The compiler package lives beside the runtime package; both are put on
``sys.path`` so tests can compile a program and then execute the emitted module
(which ``import ballrt``).
"""

from __future__ import annotations

import io
import sys
from contextlib import redirect_stdout
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]  # repo root (…/py-compiler)
RUNTIME = ROOT / "python" / "runtime"
COMPILER = ROOT / "python" / "compiler"
CONFORMANCE = ROOT / "tests" / "conformance"

for p in (str(RUNTIME), str(COMPILER)):
    if p not in sys.path:
        sys.path.insert(0, p)


def run_source(source: str) -> str:
    """Execute a compiled Python module's ``main`` entry, capturing stdout."""
    import ballrt

    ns: dict = {}
    exec(compile(source, "<compiled>", "exec"), ns)
    entry = ns.get("main")
    buf = io.StringIO()
    try:
        with redirect_stdout(buf):
            if entry is not None:
                ballrt.run_entry(entry)
    except SystemExit:
        pass
    return buf.getvalue()


@pytest.fixture
def conformance_dir() -> Path:
    return CONFORMANCE
