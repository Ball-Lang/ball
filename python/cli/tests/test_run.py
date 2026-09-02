"""`ball run`: self-host execution + the honest "engine not built" failure.

Two paths, mirroring the Go CLI's default-build vs. `-tags selfhost` split:

* without the generated ``compiled_engine.py`` (the fresh-checkout / plain-pytest
  state) ``run`` must fail honestly with exit 1 and the regenerate hint — never a
  silent success, never a raw traceback;
* with the artifact present — or with a bootstrappable self-host source, which
  ``ball_engine.bootstrap`` compiles into a cache dir on first use (issue #496) —
  ``run`` executes the program for real. That test is skipped when neither is
  available, so plain pytest stays green on a fresh checkout.
"""

from __future__ import annotations

import pytest

from conftest import COMPILED_ENGINE, SELFHOST_SOURCE_AVAILABLE, fixture, run_cli


def test_run_without_compiled_engine_reports_regenerate(monkeypatch, hello_world):
    # Simulate the absent artifact deterministically: the engine's driver raises
    # the exact ImportError `from . import compiled_engine` produces when the
    # gitignored file is missing. (On a fresh checkout it is genuinely absent —
    # see the companion natural-state assertion below.)
    from ball_engine import driver

    def boom(*_args, **_kwargs):
        raise ImportError("cannot import name 'compiled_engine' from 'ball_engine'")

    monkeypatch.setattr(driver, "run_program_view", boom)

    out, err, code = run_cli("run", hello_world)
    assert code == 1
    assert out == ""  # nothing printed when the engine is not built
    assert "python -m ball_engine.regen" in err
    assert "compiled_engine.py" in err


@pytest.mark.skipif(
    COMPILED_ENGINE.exists() or SELFHOST_SOURCE_AVAILABLE,
    reason=(
        "a compiled engine or a bootstrappable self-host source is present — the "
        "natural honest-failure path can't be observed"
    ),
)
def test_run_natural_absence_is_honest(hello_world):
    # No monkeypatch: prove the real nothing-available path (the CI / fresh-checkout
    # case, before the Dart regen step) surfaces the regenerate hint and exit 1.
    out, err, code = run_cli("run", hello_world)
    assert code == 1
    assert out == ""
    assert "python -m ball_engine.regen" in err


@pytest.mark.skipif(
    not (COMPILED_ENGINE.exists() or SELFHOST_SOURCE_AVAILABLE),
    reason=(
        "no compiled engine and no self-host source — regenerate with "
        "python -m ball_engine.regen (or gen_engine_json.dart) to run this"
    ),
)
def test_run_executes_hello_world(hello_world):
    out, err, code = run_cli("run", hello_world)
    assert code == 0, err
    assert out.strip() == "Hello, World!"


def test_run_missing_file_is_io_error_exit_3():
    # The file is read before the engine is touched, so this is deterministic
    # regardless of the compiled-engine state.
    _, err, code = run_cli("run", "no_such_program.ball.json")
    assert code == 3
    assert "could not read" in err
