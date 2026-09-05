"""The cli-core resolution order and its honest-failure contract (issue #570).

Python has no compile-time feature flag, so AVAILABILITY is the gate (the
analog of Go's ``clicore`` build tag and Rust's ``cli_core`` Cargo feature):

1. the generated ``ball_cli.compiled_cli`` (``python -m ball_cli.regen``);
2. else :func:`ball_cli.bootstrap_clicore.load_cli_core`, which compiles the
   bundled/checkout Ball source into a per-user cache dir on first use — the
   only path an installed ``ball-lang`` wheel has, because the wheel never ships
   generated code (issue #496);
3. else an honest exit-1 with the exact commands that fix it — never a silent
   success, never a raw traceback.

A checkout normally has BOTH (1) and (2), so the failure path is exercised by
neutralising them rather than by deleting files.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest
from conftest import ROOT, run_cli

FIXTURE = str(ROOT / "tests" / "conformance" / "101_simple_class.ball.json")
CLI_CORE_VERBS = ("info", "validate", "tree", "version")


@pytest.fixture
def no_compiled_cli(monkeypatch):
    """Make ``from . import compiled_cli`` fail, so resolution falls through to
    the bootstrap — the state of a fresh checkout and of an installed wheel.

    Both halves matter: the sys.modules entry AND the attribute a previous import
    set on the package, since ``from pkg import mod`` consults the attribute
    first. A meta-path finder then blocks a fresh import off disk.
    """
    import ball_cli
    import ball_cli.bootstrap_clicore as bootstrap

    monkeypatch.delitem(sys.modules, "ball_cli.compiled_cli", raising=False)
    if hasattr(ball_cli, "compiled_cli"):
        monkeypatch.delattr(ball_cli, "compiled_cli")

    class _Block:
        @staticmethod
        def find_spec(name, path=None, target=None):
            if name == "ball_cli.compiled_cli":
                raise ModuleNotFoundError("blocked by test: compiled_cli is absent")
            return None

    monkeypatch.setattr(sys, "meta_path", [_Block, *sys.meta_path])
    monkeypatch.setattr(bootstrap, "_LOADED", None, raising=False)
    return bootstrap


def test_bootstrap_compiles_the_checkout_source_when_compiled_cli_is_absent(
    no_compiled_cli, monkeypatch, tmp_path
):
    """The wheel's path, exercised from the checkout: with no generated module,
    the CLI compiles ``dart/self_host/cli.ball.json`` into the cache dir and the
    verbs work."""
    if not (ROOT / "dart" / "self_host" / "cli.ball.json").is_file():
        # BALL_REQUIRE_CLI_CORE=1 (ci.yml's post-regen parity step) turns this
        # skip into a failure, so a regen step that silently did not run cannot
        # reduce the gate to a no-op.
        if os.environ.get("BALL_REQUIRE_CLI_CORE"):
            pytest.fail(
                "BALL_REQUIRE_CLI_CORE is set but dart/self_host/cli.ball.json is absent; "
                "run `cd dart && dart run compiler/tool/gen_cli_json.dart`",
                pytrace=False,
            )
        pytest.skip("dart/self_host/cli.ball.json absent (run gen_cli_json.dart)")
    monkeypatch.setenv("BALL_CACHE_DIR", str(tmp_path / "cache"))

    stdout, stderr, code = run_cli("info", FIXTURE)
    assert code == 0, stderr
    assert stdout.startswith("Program: ")

    cached = list((tmp_path / "cache").rglob("compiled_cli.py"))
    assert len(cached) == 1, f"expected one cache-compiled CLI core, found {cached}"
    assert cached[0].stat().st_size > 0


def test_every_verb_fails_honestly_when_no_cli_core_is_available(
    no_compiled_cli, monkeypatch, tmp_path
):
    """No generated module and no Ball source: exit 1, nothing on stdout, and a
    message naming the two commands that fix it."""
    monkeypatch.setenv("BALL_CACHE_DIR", str(tmp_path / "cache"))
    monkeypatch.setattr(no_compiled_cli, "bundled_source_path", lambda: None)
    monkeypatch.setattr(no_compiled_cli, "checkout_source_path", lambda: None)

    checked = 0
    for verb in CLI_CORE_VERBS:
        args = [verb] if verb == "version" else [verb, FIXTURE]
        stdout, stderr, code = run_cli(*args)
        assert code == 1, f"{verb}: exit={code} stderr={stderr!r}"
        assert stdout == "", f"{verb} must print nothing without a CLI core, got {stdout!r}"
        assert "gen_cli_json.dart" in stderr, stderr
        assert "ball_cli.regen" in stderr, stderr
        checked += 1
    # Positive floor: a shrunken verb list must not read as a pass.
    assert checked == len(CLI_CORE_VERBS) >= 4


def test_load_failures_still_win_over_the_missing_cli_core(
    no_compiled_cli, monkeypatch, tmp_path
):
    """Even with no CLI core at all, a missing program file is an I/O error (3):
    the gap must not mask a more specific, actionable failure."""
    monkeypatch.setenv("BALL_CACHE_DIR", str(tmp_path / "cache"))
    monkeypatch.setattr(no_compiled_cli, "bundled_source_path", lambda: None)
    monkeypatch.setattr(no_compiled_cli, "checkout_source_path", lambda: None)

    _, _, code = run_cli("info", str(tmp_path / "definitely-absent.ball.json"))
    assert code == 3


def test_cache_key_covers_the_source_so_a_regen_recompiles(no_compiled_cli):
    """Two different sources must never share a cache entry — otherwise a
    regenerated cli_core would silently keep running the old compiled code."""
    a = no_compiled_cli.cache_key(b'{"name":"a"}')
    b = no_compiled_cli.cache_key(b'{"name":"b"}')
    assert a != b
    assert a == no_compiled_cli.cache_key(b'{"name":"a"}')


def test_cache_root_is_separate_from_the_engine_cache(no_compiled_cli, monkeypatch, tmp_path):
    """The CLI core and the engine cache under distinct directories, so neither
    can ever load the other's compiled module."""
    import ball_engine.bootstrap as engine_bootstrap

    monkeypatch.setenv("BALL_CACHE_DIR", str(tmp_path / "cache"))
    cli_root = Path(no_compiled_cli.cache_root())
    engine_root = Path(engine_bootstrap.cache_root())
    assert cli_root != engine_root
    assert cli_root.name == "clicore"
