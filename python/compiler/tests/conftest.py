"""Shared pytest fixtures: import paths + a compile-and-run helper.

The compiler package lives beside the runtime package; both are put on
``sys.path`` so tests can compile a program and then execute the emitted module
(which ``import ballrt``).
"""

from __future__ import annotations

import io
import re
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
    """Execute a compiled Python module's entry function, capturing stdout.

    The entry name is read from the emitted ``ballrt.run_entry(<name>)`` line
    (the entry is ``sanitize(entryFunction)``, not necessarily ``main``)."""
    import ballrt

    ns: dict = {}
    exec(compile(source, "<compiled>", "exec"), ns)
    match = re.search(r"ballrt\.run_entry\((\w+)\)", source)
    entry = ns.get(match.group(1)) if match else ns.get("main")
    buf = io.StringIO()
    try:
        with redirect_stdout(buf):
            if entry is not None:
                ballrt.run_entry(entry)
    except SystemExit:
        pass
    return buf.getvalue()


def read_golden(path: Path) -> str:
    """Read a golden file, normalising only CRLF line separators to LF.

    A Windows checkout stores goldens with CRLF, but a fixture may legitimately
    print an embedded lone CR (Dart ``'\\r'``). ``Path.read_text`` uses universal
    newlines and would collapse that semantic CR to LF, so read bytes and strip
    only ``\\r\\n`` pairs — the compiled program writes ``\\n`` line endings."""
    return path.read_bytes().decode("utf-8").replace("\r\n", "\n")


@pytest.fixture
def conformance_dir() -> Path:
    return CONFORMANCE
