"""Compile the self-hosted CLI core on first use and cache it (issue #570).

The exact mechanism :mod:`ball_engine.bootstrap` uses for the engine, applied to
the portable CLI verbs. ``compiled_cli.py`` is a generated artifact: gitignored
in a checkout (written by ``python -m ball_cli.regen``) and deliberately NOT
shipped in the ``ball-lang`` wheel — the repo never distributes generated code.

So the wheel carries the CLI core's Ball **source** as package data
(``_clicore/cli_core.ball.json.gz``, written at build time by
``python/cli/tool/bundle_cli_core.py``) and this module compiles it with the
bundled, pure-Python ``ball_compiler`` the first time ``ball info``/``validate``/
``tree``/``version`` needs it, caching the result under a per-user cache
directory.

Resolution order for the Ball source:

1. ``_clicore/cli_core.ball.json.gz`` inside the installed package (the wheel);
2. ``dart/self_host/cli.ball.json`` in the surrounding checkout (so a developer
   who has run ``gen_cli_json.dart`` gets the same path without a bundling step).

The cache lives under its own ``clicore`` subdirectory of the shared
``ball-lang`` cache root — the engine's cache key and this one both hash their
own source, so a collision was never possible, but a separate subdirectory keeps
``BALL_CACHE_DIR`` inspectable (one directory per artifact) and makes an
accidental cross-load impossible by construction.

Everything that can go wrong (no source, an unwritable cache directory, a
compiler failure) raises :class:`CliCoreBootstrapError` with an actionable
message; the CLI reports it as a clean ``ball: …`` runtime error, never a
traceback.
"""

from __future__ import annotations

import gzip
import hashlib
import importlib.util
import json
import os
import sys
import tempfile
from pathlib import Path
from types import ModuleType

__all__ = [
    "CliCoreBootstrapError",
    "load_cli_core",
    "cache_root",
    "cache_key",
    "source_bytes",
    "cached_module_path",
    "ensure_compiled",
]

_BUNDLED_RELATIVE = ("_clicore", "cli_core.ball.json.gz")
_MODULE_NAME = "ball_cli._cached_compiled_cli"
_DIST_NAME = "ball-lang"

# One process compiles at most once; the loaded module is reused.
_LOADED: ModuleType | None = None


class CliCoreBootstrapError(RuntimeError):
    """The self-hosted CLI core could not be made available, with a reason a user
    can act on."""


def _dist_version() -> str:
    try:
        from importlib.metadata import PackageNotFoundError, version
    except ImportError:  # pragma: no cover - importlib.metadata is stdlib >= 3.8
        return "source"
    try:
        return version(_DIST_NAME)
    except PackageNotFoundError:
        return "source"


def bundled_source_path() -> Path | None:
    """The gzipped Ball source shipped inside the installed package, if present."""
    path = Path(__file__).resolve().parent.joinpath(*_BUNDLED_RELATIVE)
    return path if path.is_file() else None


def checkout_source_path() -> Path | None:
    """``dart/self_host/cli.ball.json`` in the surrounding checkout, if present."""
    d = Path(__file__).resolve().parent
    while d != d.parent:
        if (d / "proto" / "ball" / "v1" / "ball.proto").is_file():
            candidate = d / "dart" / "self_host" / "cli.ball.json"
            return candidate if candidate.is_file() else None
        d = d.parent
    return None


def source_bytes() -> bytes:
    """The CLI core's Ball program JSON bytes, from the wheel or the checkout."""
    bundled = bundled_source_path()
    if bundled is not None:
        try:
            return gzip.decompress(bundled.read_bytes())
        except OSError as ex:
            raise CliCoreBootstrapError(
                f"the bundled CLI-core source at {bundled} is unreadable: {ex}"
            ) from ex
    checkout = checkout_source_path()
    if checkout is not None:
        return checkout.read_bytes()
    raise CliCoreBootstrapError(
        "the self-hosted CLI core is not available: this install carries no bundled "
        "source (ball_cli/_clicore/cli_core.ball.json.gz) and no "
        "dart/self_host/cli.ball.json was found nearby.\n"
        "In a checkout, generate it and build compiled_cli.py directly:\n"
        "    cd dart && dart run compiler/tool/gen_cli_json.dart\n"
        "    cd ../python/cli && python -m ball_cli.regen"
    )


def cache_root() -> Path:
    """The per-user cache directory, overridable with ``BALL_CACHE_DIR``.

    Mirrors :func:`ball_engine.bootstrap.cache_root` platform for platform, with
    a ``clicore`` leaf instead of ``engine`` so the two artifacts never share a
    directory.
    """
    override = os.environ.get("BALL_CACHE_DIR")
    if override:
        return Path(override).expanduser() / "clicore"
    if sys.platform == "win32":
        base = os.environ.get("LOCALAPPDATA") or os.environ.get("APPDATA")
        if base:
            return Path(base) / "ball-lang" / "clicore"
        return Path.home() / "AppData" / "Local" / "ball-lang" / "clicore"
    xdg = os.environ.get("XDG_CACHE_HOME")
    base_dir = Path(xdg) if xdg else Path.home() / ".cache"
    return base_dir / "ball-lang" / "clicore"


def cache_key(src: bytes) -> str:
    """A cache key over (distribution version, Python minor, source digest)."""
    digest = hashlib.sha256(src).hexdigest()[:32]
    py = f"{sys.version_info.major}.{sys.version_info.minor}"
    return f"{_dist_version()}-py{py}-{digest}"


def _compile_source(src: bytes) -> str:
    try:
        from ball_compiler.compiler import compile_library
    except ImportError as ex:
        raise CliCoreBootstrapError(
            f"the Ball -> Python compiler is not importable ({ex}); the ball-lang "
            "install is incomplete"
        ) from ex
    try:
        program = json.loads(src.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as ex:
        raise CliCoreBootstrapError(f"the CLI-core source is not valid JSON: {ex}") from ex
    program.pop("@type", None)  # google.protobuf.Any envelope
    try:
        return compile_library(program)
    except Exception as ex:  # a compiler bug or an unsupported shape — fail loud
        raise CliCoreBootstrapError(
            f"compiling the self-hosted CLI core failed: {type(ex).__name__}: {ex}"
        ) from ex


def _write_atomic(target: Path, text: str) -> None:
    """Write ``text`` to ``target`` so a concurrent reader never sees a partial file."""
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=str(target.parent), suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(text)
            os.replace(tmp, target)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
    except OSError as ex:
        raise CliCoreBootstrapError(
            f"could not write the compiled CLI-core cache at {target.parent}: {ex}\n"
            "Set BALL_CACHE_DIR to a writable directory."
        ) from ex


def cached_module_path(src: bytes | None = None) -> Path:
    """Where the compiled CLI core for ``src`` lives (compiled or not)."""
    if src is None:
        src = source_bytes()
    return cache_root() / cache_key(src) / "compiled_cli.py"


def ensure_compiled(src: bytes | None = None) -> Path:
    """Return the cached compiled-CLI-core path, compiling it on a cache miss."""
    if src is None:
        src = source_bytes()
    path = cached_module_path(src)
    if path.is_file() and path.stat().st_size > 0:
        return path
    _write_atomic(path, _compile_source(src))
    return path


def load_cli_core(src: bytes | None = None) -> ModuleType:
    """Import the compiled CLI core, compiling+caching it on first use."""
    global _LOADED
    if _LOADED is not None and src is None:
        return _LOADED
    path = ensure_compiled(src)
    spec = importlib.util.spec_from_file_location(_MODULE_NAME, path)
    if spec is None or spec.loader is None:
        raise CliCoreBootstrapError(f"could not load the compiled CLI core at {path}")
    module = importlib.util.module_from_spec(spec)
    # Registered under its own name so the compiled module's own imports resolve,
    # without shadowing ball_cli.compiled_cli.
    sys.modules[_MODULE_NAME] = module
    try:
        spec.loader.exec_module(module)
    except Exception as ex:
        sys.modules.pop(_MODULE_NAME, None)
        raise CliCoreBootstrapError(
            f"the cached compiled CLI core at {path} failed to import: "
            f"{type(ex).__name__}: {ex}\nDelete that directory to force a rebuild."
        ) from ex
    if src is None:
        _LOADED = module
    return module
