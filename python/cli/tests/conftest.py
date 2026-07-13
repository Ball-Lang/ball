"""Shared pytest fixtures for the CLI suite: import paths + in-process helpers.

The CLI package plus the four sibling packages it drives (runtime, shared/gen,
engine, compiler, encoder) are put on ``sys.path`` so the whole CLI runs
in-process through :func:`ball_cli.run` — no subprocess. ``run_cli`` captures
stdout/stderr and the exit code; ``run_python_source`` executes a compiled Python
module so ``compile`` can be proven to emit runnable code.
"""

from __future__ import annotations

import io
import re
import sys
from contextlib import redirect_stdout
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]  # repo root (…/py-cli)
_PACKAGES = (
    ROOT / "python" / "cli",
    ROOT / "python" / "runtime",
    ROOT / "python" / "shared" / "gen",
    ROOT / "python" / "engine",
    ROOT / "python" / "compiler",
    ROOT / "python" / "encoder",
)
for _p in _PACKAGES:
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

CONFORMANCE = ROOT / "tests" / "conformance"
EXAMPLES = ROOT / "examples"
COMPILED_ENGINE = ROOT / "python" / "engine" / "ball_engine" / "compiled_engine.py"


def run_cli(*args: str) -> tuple[str, str, int]:
    """Invoke ``ball_cli.run`` in-process, returning (stdout, stderr, exit code)."""
    from ball_cli import run

    out, err = io.StringIO(), io.StringIO()
    code = run(list(args), out, err)
    return out.getvalue(), err.getvalue(), code


def run_python_source(source: str) -> str:
    """Execute a compiled Python module's entry function, capturing stdout.

    The entry name is read from the emitted ``ballrt.run_entry(<name>)`` line (the
    entry is ``sanitize(entryFunction)``, not necessarily ``main``) — mirrors the
    compiler suite's ``run_source``."""
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


def fixture(*rel: str) -> str:
    """Resolve a path relative to the repo root, asserting it exists."""
    path = ROOT.joinpath(*rel)
    assert path.exists(), f"fixture missing: {path}"
    return str(path)


@pytest.fixture
def conformance_dir() -> Path:
    return CONFORMANCE


@pytest.fixture
def hello_world() -> str:
    return fixture("examples", "hello_world", "hello_world.ball.json")
