"""Load a Ball program from disk into the raw proto3-JSON dict view.

``compile`` and ``check`` inspect the program as nested ``dict``s/``list``s with
camelCase keys — the same view ``python/compiler`` walks — so no protobuf runtime
is needed for those verbs (``run`` uses the engine's own protobuf-backed loader).
This wraps ``ball_compiler.load_program`` to map its failure modes onto the CLI's
exit-code contract: a missing/unreadable file is an I/O error (exit 3); malformed
JSON is an invalid program (exit 2).
"""

from __future__ import annotations

import json

from .errors import io_error, parse_error


def load_program_dict(path: str) -> dict:
    """Load ``path`` (a ``.ball.json``) into its raw proto3-JSON dict view."""
    from ball_compiler.loader import load_program  # sibling; bootstrapped onto sys.path

    try:
        program = load_program(path)
    except OSError as ex:
        raise io_error(f"could not read {path}: {ex}") from ex
    except json.JSONDecodeError as ex:
        raise parse_error(f"could not parse {path}: not valid JSON: {ex}") from ex

    if not isinstance(program, dict):
        raise parse_error(f"could not load {path}: not a JSON object (ball.v1.Program)")
    return program
