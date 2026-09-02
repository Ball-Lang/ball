"""``ball_engine.bootstrap``: compile-on-first-use, caching, and failure modes.

This is the only path a ``pip install ball-lang`` wheel has to a working engine
(issue #496): the wheel ships the engine's Ball SOURCE, never the generated
``compiled_engine.py``, so the first ``ball run`` compiles it into a per-user
cache directory.

The cheap mechanics (cache dir, key, hit/miss, invalidation, unwritable
directory) are exercised against a small real Ball program, so the whole file
stays fast. The expensive proof — that the cache-bootstrapped engine is a
*correct* engine, not merely a file — is ``test_bootstrapped_engine_matches_golden``,
which runs a real conformance fixture through it and compares stdout to the
fixture's golden BYTES.
"""

from __future__ import annotations

import os
import stat
import sys

import pytest
from conftest import (
    CONFORMANCE,
    EXAMPLES,
    read_golden,
    require_selfhost_source,
)

from ball_engine import bootstrap

# A small, real Ball program: enough to exercise compile -> write -> import
# without paying for the ~21 MB self-host engine on every assertion.
SMALL_PROGRAM = EXAMPLES / "hello_world" / "hello_world.ball.json"


@pytest.fixture
def cache(tmp_path, monkeypatch):
    """Point the bootstrap's cache at a temp dir and clear the process cache."""
    monkeypatch.setenv("BALL_CACHE_DIR", str(tmp_path / "cache"))
    monkeypatch.setattr(bootstrap, "_LOADED", None)
    return tmp_path / "cache"


@pytest.fixture
def small_source() -> bytes:
    return SMALL_PROGRAM.read_bytes()


def test_cache_root_honours_the_env_override(tmp_path, monkeypatch):
    monkeypatch.setenv("BALL_CACHE_DIR", str(tmp_path / "elsewhere"))
    assert bootstrap.cache_root() == tmp_path / "elsewhere"


def test_cache_root_is_platform_appropriate_without_the_override(monkeypatch):
    monkeypatch.delenv("BALL_CACHE_DIR", raising=False)
    root = bootstrap.cache_root()
    assert root.name == "engine"
    assert root.parent.name == "ball-lang"
    if sys.platform != "win32":
        monkeypatch.setenv("XDG_CACHE_HOME", "/tmp/xdg-example")
        assert str(bootstrap.cache_root()).startswith("/tmp/xdg-example")


def test_cache_key_covers_source_version_and_python(small_source, monkeypatch):
    key = bootstrap.cache_key(small_source)
    assert bootstrap.cache_key(small_source) == key, "must be deterministic"
    assert bootstrap.cache_key(small_source + b" ") != key, "a changed source is a new key"
    assert f"py{sys.version_info.major}.{sys.version_info.minor}" in key

    monkeypatch.setattr(bootstrap, "_dist_version", lambda: "9.9.9")
    assert bootstrap.cache_key(small_source) != key, "a version bump is a new key"
    assert bootstrap.cache_key(small_source).startswith("9.9.9-")


def test_first_call_compiles_and_second_call_reuses(cache, small_source, monkeypatch):
    path = bootstrap.ensure_compiled(small_source)
    assert path.is_file() and path.stat().st_size > 0
    assert cache in path.parents

    # A second call must NOT recompile: make compilation itself an error, so a
    # recompile would fail loudly rather than merely being slow.
    def must_not_compile(_src):
        raise AssertionError("recompiled despite a warm cache")

    monkeypatch.setattr(bootstrap, "_compile_source", must_not_compile)
    assert bootstrap.ensure_compiled(small_source) == path


def test_changed_source_forces_a_fresh_compile(cache, small_source):
    first = bootstrap.ensure_compiled(small_source)
    second = bootstrap.ensure_compiled(small_source + b"\n")
    assert first != second
    assert first.is_file() and second.is_file()


def test_version_bump_forces_a_fresh_compile(cache, small_source, monkeypatch):
    first = bootstrap.ensure_compiled(small_source)
    monkeypatch.setattr(bootstrap, "_dist_version", lambda: "42.0.0")
    second = bootstrap.ensure_compiled(small_source)
    assert first != second
    assert second.is_file()


def test_load_engine_imports_the_cached_module(cache, small_source):
    module = bootstrap.load_engine(small_source)
    assert module.__name__ == "ball_engine._cached_compiled_engine"
    # The compiled library really is Python that imported cleanly.
    assert any(not name.startswith("__") for name in vars(module))


@pytest.mark.skipif(sys.platform == "win32", reason="chmod 0o500 does not block writes on Windows")
def test_unwritable_cache_dir_is_a_clean_error(tmp_path, monkeypatch, small_source):
    blocked = tmp_path / "readonly"
    blocked.mkdir()
    os.chmod(blocked, stat.S_IRUSR | stat.S_IXUSR)
    monkeypatch.setenv("BALL_CACHE_DIR", str(blocked / "cache"))
    monkeypatch.setattr(bootstrap, "_LOADED", None)
    try:
        with pytest.raises(bootstrap.BootstrapError) as excinfo:
            bootstrap.ensure_compiled(small_source)
    finally:
        os.chmod(blocked, stat.S_IRWXU)
    message = str(excinfo.value)
    assert "BALL_CACHE_DIR" in message, message
    assert "could not write" in message, message


def test_missing_source_is_a_clean_error_with_the_regenerate_hint(monkeypatch):
    monkeypatch.setattr(bootstrap, "bundled_source_path", lambda: None)
    monkeypatch.setattr(bootstrap, "checkout_source_path", lambda: None)
    with pytest.raises(bootstrap.BootstrapError) as excinfo:
        bootstrap.source_bytes()
    assert "python -m ball_engine.regen" in str(excinfo.value)


def test_a_compiler_failure_is_a_clean_error(cache):
    with pytest.raises(bootstrap.BootstrapError) as excinfo:
        bootstrap.ensure_compiled(b"{ not json")
    assert "not valid JSON" in str(excinfo.value)


def test_source_bytes_prefers_the_bundled_copy(monkeypatch, tmp_path, small_source):
    import gzip

    bundled = tmp_path / "engine.ball.json.gz"
    bundled.write_bytes(gzip.compress(small_source))
    monkeypatch.setattr(bootstrap, "bundled_source_path", lambda: bundled)
    monkeypatch.setattr(
        bootstrap, "checkout_source_path", lambda: pytest.fail("checkout used despite a bundle")
    )
    assert bootstrap.source_bytes() == small_source


# ── The real proof: a cache-bootstrapped engine produces the golden output ──


def test_bootstrapped_engine_matches_golden(cache):
    """Run a conformance fixture through the compile-on-first-use engine.

    Proves the bootstrap path yields a CORRECT engine, not merely a file: the
    captured stdout must equal the fixture's golden byte-for-byte (goldens read
    as bytes, only CRLF normalised).
    """
    require_selfhost_source()

    from ball_engine import driver, loader

    fixture = CONFORMANCE / "100_complex_control_flow.ball.json"
    golden = CONFORMANCE / "100_complex_control_flow.expected_output.txt"
    assert fixture.is_file() and golden.is_file()

    # Force the bootstrap path even in a tree that has a regenerated
    # compiled_engine.py: that artifact is exactly what a wheel does NOT have.
    engine = bootstrap.load_engine()
    assert engine.__name__ == "ball_engine._cached_compiled_engine"
    assert bootstrap.cached_module_path().is_file()

    # A real engine, not a stub: the compiled module is hundreds of KB.
    assert bootstrap.cached_module_path().stat().st_size > 100_000

    view = loader.load_view_from_json(fixture.read_text(encoding="utf-8"))
    actual = "\n".join(driver.run_with_engine(engine, view))
    expected = read_golden(golden)
    # Positive floor: "" == "" must never read as a pass.
    assert expected.strip(), "the golden is empty — the comparison would be vacuous"
    assert actual.strip(), "the bootstrapped engine printed nothing"
    assert actual.rstrip("\n") == expected.rstrip("\n")
