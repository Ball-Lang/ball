"""Resolve the self-hosted CLI core and expose its report functions.

The portable verbs ``info`` / ``validate`` / ``tree`` / ``version`` do not
compute their own text: it comes from ``dart/shared/lib/cli_core.dart`` compiled
through the Ball → Python compiler, so every ``ball`` on every registry prints
byte-identical reports (issue #570, epic #361). This module is the single place
that decides WHERE that compiled code comes from, so the four command modules
stay three lines each.

Resolution order (the Python analog of Go's ``clicore`` build tag and Rust's
``cli_core`` Cargo feature — Python has no compile-time feature flags, so
availability *is* the gate, exactly like ``run``'s engine resolution):

1. ``ball_cli.compiled_cli`` — the generated module ``python -m ball_cli.regen``
   writes. Present in a regenerated checkout; gitignored, and never shipped.
2. :func:`ball_cli.bootstrap_clicore.load_cli_core` — compiles the bundled (or
   checkout) Ball source into a per-user cache dir on first use. This is the only
   path an installed ``ball-lang`` wheel has.

When neither is available the failure is honest: a
:class:`~ball_cli.errors.CliError` with exit 1 and the exact commands that fix
it — never a silent success, never a raw traceback.

The program-taking verbs are handed the engine's canonical proto3-JSON view (the
same tree the self-hosted engine reads), because the compiled ``cli_core``
functions inspect a program through the identical ``ball_proto`` access patterns
the compiled engine does.
"""

from __future__ import annotations

from types import ModuleType

from .errors import parse_error, runtime_error

_REGEN_HINT = (
    "the self-hosted CLI core is not built: ball_cli/compiled_cli.py is absent and no "
    "Ball source was found to compile.\nRegenerate it with:\n"
    "    cd dart && dart run compiler/tool/gen_cli_json.dart\n"
    "    cd python/cli && python -m ball_cli.regen"
)


def reports() -> ModuleType:
    """The compiled ``cli_core`` module, by the resolution order above."""
    try:
        from . import compiled_cli  # type: ignore[attr-defined]

        return compiled_cli
    except ImportError:
        pass
    from .bootstrap_clicore import CliCoreBootstrapError, load_cli_core

    try:
        return load_cli_core()
    except CliCoreBootstrapError as ex:
        # BootstrapError already carries an actionable message (no source, an
        # unwritable cache dir, a compile failure) — report it verbatim rather
        # than wrapping it in a second layer of prose. The no-source case names
        # the regeneration commands itself.
        raise runtime_error(str(ex)) from ex
    except ImportError as ex:  # ball_compiler itself missing — an incomplete install
        raise runtime_error(f"{_REGEN_HINT}\n(underlying error: {ex})") from ex


def program_view(path: str):
    """Load ``path`` into the canonical proto3-JSON view the reports consume.

    Reuses the engine's own loader (``ball_engine.load_view_from_json``): the
    compiled ``cli_core`` reads a program through the same ``ball_proto`` access
    patterns the compiled engine does, so it needs the same materialised view —
    there is no second loader here.
    """
    import json
    from pathlib import Path

    from .errors import io_error

    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError as ex:
        raise io_error(f"could not read {path}: {ex}") from ex

    try:
        from ball_engine import load_view_from_json
    except ImportError as ex:  # ballrt / ball.v1 / protobuf not importable
        raise runtime_error(f"the Ball program loader is unavailable: {ex}") from ex

    try:
        return load_view_from_json(text)
    except json.JSONDecodeError as ex:
        raise parse_error(f"could not parse {path}: not valid JSON: {ex}") from ex
    except Exception as ex:  # protobuf ParseError: a malformed ball.v1.Program shape
        raise parse_error(f"could not load {path}: {ex}") from ex
