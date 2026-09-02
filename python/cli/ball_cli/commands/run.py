"""``ball run <program.ball.json>`` — execute via the self-hosted Python engine.

Loads the program view and drives it through ``python/engine``'s compiled
self-hosted engine, writing each captured stdout line to the command's stdout.

Self-host gating (the Python analog of the Go CLI's ``selfhost`` build tag and the
Rust CLI's ``self_host`` Cargo feature): the engine runs from the generated
``compiled_engine.py`` when it is present (the regenerated checkout state), and
otherwise from ``ball_engine.bootstrap``, which compiles the bundled Ball engine
source into a per-user cache dir on first use — the only path a ``pip
install``ed ``ball-lang`` wheel has, since generated code is never shipped
(issue #496).

When neither is available — a fresh checkout with no
``dart/self_host/engine.ball.json`` and no bundled source — the failure is
honest: exit 1 with the "regenerate with python -m ball_engine.regen" message,
never a silent success, never a raw traceback. The same holds for an unwritable
cache directory or a compile failure, each with its own actionable message.

The steps are split so each maps to the right exit code: a missing/unreadable
file is an I/O error (3); a malformed program is invalid (2); a program that ran
and failed — or the engine not being built — is a runtime error (1).
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import TextIO

from ..argparse_util import StreamParser
from ..errors import io_error, parse_error, runtime_error

_REGEN_HINT = (
    "the self-hosted Python engine is not built: ball_engine/compiled_engine.py "
    "is absent.\nRegenerate it with:\n"
    "    cd python/engine && python -m ball_engine.regen\n"
    "(first run `cd dart && dart run compiler/tool/gen_engine_json.dart` if "
    "dart/self_host/engine.ball.json is also missing)."
)


def command(args: list[str], stdout: TextIO, stderr: TextIO) -> int:
    parser = StreamParser(
        prog="ball run",
        description="Execute a Ball program (.ball.json) via the self-hosted Python engine.",
        out=stdout,
        err=stderr,
    )
    parser.add_argument("input", metavar="<program.ball.json>", help="path to a .ball.json program")
    ns = parser.parse_args(args)

    try:
        text = Path(ns.input).read_text(encoding="utf-8")
    except OSError as ex:
        raise io_error(f"could not read {ns.input}: {ex}") from ex

    try:
        from ball_engine import load_view_from_json, run_program_view
    except ImportError as ex:  # ballrt / ball.v1 / protobuf not importable
        raise runtime_error(f"the self-hosted Python engine is unavailable: {ex}") from ex

    try:
        view = load_view_from_json(text)
    except json.JSONDecodeError as ex:
        raise parse_error(f"could not parse {ns.input}: not valid JSON: {ex}") from ex
    except Exception as ex:  # protobuf ParseError: a malformed ball.v1.Program shape
        raise parse_error(f"could not load {ns.input}: {ex}") from ex

    # BootstrapError carries an already-actionable message (no bundled/checkout
    # engine source, an unwritable cache dir, or a compile failure) — report it
    # verbatim rather than wrapping it in a second layer of prose.
    try:
        from ball_engine.bootstrap import BootstrapError
    except ImportError:  # pragma: no cover - ball_engine imported fine just above
        BootstrapError = ()  # type: ignore[assignment]

    try:
        lines = run_program_view(view)
    except BootstrapError as ex:
        raise runtime_error(str(ex)) from ex
    except ImportError as ex:
        # `from . import compiled_engine` on the absent artifact raises a plain
        # ImportError ("cannot import name 'compiled_engine' …"), not
        # ModuleNotFoundError — catch the whole family.
        if _is_compiled_engine_missing(ex):
            raise runtime_error(_REGEN_HINT) from ex
        raise runtime_error(f"run failed: engine unavailable: {ex}") from ex
    except Exception as ex:  # a Ball throw / runtime error escaping the engine
        raise runtime_error(f"run failed: {ex}") from ex

    for line in lines:
        stdout.write(line + "\n")
    return 0


def _is_compiled_engine_missing(ex: ImportError) -> bool:
    """True when ``ex`` is the honest "self-hosted engine not built" signal —
    the absent gitignored ``ball_engine.compiled_engine`` module."""
    name = getattr(ex, "name", "") or ""
    return name.endswith("compiled_engine") or "compiled_engine" in str(ex)
