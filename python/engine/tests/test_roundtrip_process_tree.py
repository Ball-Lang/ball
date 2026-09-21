"""Negative control: a timed-out round-trip fixture must leave no orphan (#791).

``dart run`` is a launcher — it forks the Dart VM, and the VM is what actually
executes the re-encoded program and holds the inherited stdout pipe. A timeout
that kills only the immediate ``dart`` therefore leaves that VM running,
orphaned, in the CI runner: a resource leak on every fixture that times out, and
one completely invisible to a test that only checks the harness came back with a
``timeout`` status (it always did).

So the assertion here is about the GRANDCHILD, not about the harness. The
control is the real shape, not a mock: a fabricated stand-in ``dart`` that forks
a grandchild inheriting its stdout and then blocks, driven through the
production :func:`conformance.roundtrip._run_dart`. It mirrors
``go/engine/conformance/roundtrip_timeout_test.go`` (the Go leg's control for
the *other* half of this defect, a ``cmd.Wait`` that never returns) and the
Rust sibling in ``rust/engine/tests/roundtrip_conformance.rs``.

Liveness is observed through a heartbeat file the grandchild appends to every
50 ms, rather than a pid probe: a file that stops growing is a process that is
gone, it cannot be confused by pid reuse, and ``os.kill(pid, 0)`` has no
portable spelling (on Windows signal 0 *terminates* rather than probes).
"""

from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path

import importlib.util

import pytest
from conftest import CONFORMANCE, ROOT


def _load_roundtrip_leg():
    """Import ``python/engine/conformance/roundtrip.py`` by PATH.

    Not ``from conformance import roundtrip``: ``python/compiler/conformance``
    is a real package owning that same top-level name, and the engine suite's
    ``conftest`` puts the compiler on ``sys.path`` too — so the plain import
    silently resolves to the compiler's package. In production the leg runs as
    ``python -m conformance.roundtrip`` from ``python/engine``, where its own
    directory wins; only a test process has both on the path.
    """
    path = ROOT / "python" / "engine" / "conformance" / "roundtrip.py"
    spec = importlib.util.spec_from_file_location("ball_roundtrip_leg", path)
    assert spec is not None and spec.loader is not None, f"cannot load {path}"
    module = importlib.util.module_from_spec(spec)
    # `@dataclass` resolves annotations through `sys.modules[cls.__module__]`,
    # so the module has to be registered BEFORE it is executed.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


roundtrip = _load_roundtrip_leg()

# The grandchild appends every 50 ms for this many iterations. It must
# comfortably outlive the assertion window below — but never forever: a control
# that leaks a process for an hour on every RED run is its own defect.
_HOLD_ITERATIONS = 600          # 30 s
_HEARTBEAT_INTERVAL_S = 0.05

# Long enough for the stand-in to fork its grandchild and for the heartbeat to
# reach the disk, short enough that this test costs a couple of seconds.
_BUDGET_S = 1.5
_SETTLE_S = 0.75
_OBSERVE_S = 1.5

_STAND_IN = f"""\
import os
import subprocess
import sys
import time

# Beside this script, so the test can find it without being told.
HEARTBEAT = os.path.splitext(os.path.abspath(__file__))[0] + ".heartbeat"

if "--ball-hold" in sys.argv:
    # The grandchild: it inherited the harness's stdout pipe.
    for _ in range({_HOLD_ITERATIONS}):
        with open(HEARTBEAT, "ab") as fh:
            fh.write(b".")
            fh.flush()
        time.sleep({_HEARTBEAT_INTERVAL_S})
    sys.exit(0)

# The stand-in `dart`: hand our stdout to a grandchild that outlives us, then
# block. Killing only this process leaves the grandchild running.
subprocess.Popen([sys.executable, os.path.abspath(__file__), "--ball-hold"])
time.sleep(3600)
"""


def _write_stand_in(tmp_path: Path) -> tuple[str, Path]:
    """Write the fabricated `dart` and return ``(launcher, heartbeat)``.

    ``_run_dart`` builds the command line itself, so the stand-in has to BE an
    executable named on the command line — not a Python module the test can
    import. A one-line native launcher delegates to this interpreter, which
    keeps the control toolchain-free on both families.
    """
    script = tmp_path / "stand_in.py"
    script.write_text(_STAND_IN, encoding="utf-8", newline="\n")
    heartbeat = tmp_path / "stand_in.heartbeat"

    if os.name == "nt":
        launcher = tmp_path / "dart.bat"
        launcher.write_text(
            f'@echo off\r\n"{sys.executable}" "{script}" %*\r\n',
            encoding="utf-8",
            newline="",
        )
    else:
        launcher = tmp_path / "dart"
        launcher.write_text(
            f'#!/bin/sh\nexec "{sys.executable}" "{script}" "$@"\n',
            encoding="utf-8",
            newline="\n",
        )
        launcher.chmod(0o755)
    return str(launcher), heartbeat


def _size(path: Path) -> int:
    return path.stat().st_size if path.exists() else 0


def test_a_timed_out_fixture_leaves_no_orphaned_descendant_process(tmp_path, monkeypatch):
    monkeypatch.setenv("BALL_TIMEOUT_S", str(_BUDGET_S))
    launcher, heartbeat = _write_stand_in(tmp_path)

    # Any real fixture path: the fabricated launcher never reads its arguments.
    ball_json = CONFORMANCE / "28_fibonacci.ball.json"
    assert ball_json.is_file(), (
        f"the control needs a real fixture path to hand the launcher: {ball_json}"
    )

    started = time.monotonic()
    with pytest.raises(subprocess.TimeoutExpired):
        roundtrip._run_dart(launcher, str(ball_json))
    elapsed = time.monotonic() - started
    assert elapsed < 30, (
        f"the per-fixture budget must be reachable through BALL_TIMEOUT_S; the "
        f"runaway was only killed after {elapsed:.1f}s"
    )

    # Let any write that was already in flight when the kill landed settle.
    time.sleep(_SETTLE_S)
    first = _size(heartbeat)
    # POSITIVE FLOOR. Without it a control that never managed to fork a
    # grandchild would report a frozen heartbeat and pass while proving nothing.
    assert first > 0, (
        f"the stand-in never wrote a heartbeat ({heartbeat}), so this run "
        f"fabricated no live grandchild and proves nothing about the kill"
    )

    # A live grandchild appends every 50 ms, so ~30 more bytes land in this
    # window. A heartbeat that has not moved is a process that is gone.
    time.sleep(_OBSERVE_S)
    second = _size(heartbeat)
    assert second == first, (
        f"the timed-out fixture's GRANDCHILD is still running: its heartbeat grew "
        f"from {first} to {second} bytes {_OBSERVE_S}s after the harness reported "
        f"the timeout. The kill reached only the immediate `dart` process, so a "
        f"real sweep leaks one orphaned Dart VM per timed-out fixture (issue #791)"
    )
