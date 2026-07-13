"""Shared pytest fixtures: import paths + native/round-trip run helpers.

The encoder package lives beside the Phase-2 compiler and runtime packages; all
three are put on ``sys.path`` so a test can encode Python → Ball, compile the
Ball back to Python with ``python/compiler``, and execute the emitted module
(which ``import ballrt``). The round-trip is the encoder's proof of correctness
(the CLAUDE.md bar): native Python == encode → compile → run.
"""

from __future__ import annotations

import io
import re
import subprocess
import sys
from contextlib import redirect_stdout
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]  # repo root (…/py-encoder)
ENCODER = ROOT / "python" / "encoder"
COMPILER = ROOT / "python" / "compiler"
RUNTIME = ROOT / "python" / "runtime"
TESTDATA = Path(__file__).resolve().parent / "testdata"

for p in (str(ENCODER), str(COMPILER), str(RUNTIME)):
    if p not in sys.path:
        sys.path.insert(0, p)


def read_source(name: str) -> str:
    return (TESTDATA / name).read_text(encoding="utf-8")


def run_native(name: str) -> str:
    """Run a testdata program with the native Python interpreter, returning
    stdout. A genuine native run (subprocess), the reference behaviour every
    round-trip is checked against."""
    proc = subprocess.run(
        [sys.executable, str(TESTDATA / name)],
        capture_output=True, text=True, check=True,
    )
    return proc.stdout


def run_ball(source: str) -> str:
    """Encode Python → Ball, compile the Ball back to Python with the Phase-2
    compiler, and execute it in-process, returning stdout."""
    from ball_encoder import encode
    from ball_compiler import compile_program
    import ballrt

    program = encode(source)
    compiled = compile_program(program)
    ns: dict = {}
    exec(compile(compiled, "<compiled>", "exec"), ns)
    match = re.search(r"ballrt\.run_entry\((\w+)\)", compiled)
    entry = ns.get(match.group(1)) if match else ns.get("main")
    buf = io.StringIO()
    try:
        with redirect_stdout(buf):
            if entry is not None:
                ballrt.run_entry(entry)
    except SystemExit:
        pass
    return buf.getvalue()


@pytest.fixture
def testdata_dir() -> Path:
    return TESTDATA
