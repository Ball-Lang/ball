"""Run a single Ball program through the self-hosted engine, printing its stdout.

    python -m ball_engine <program.ball.json>

Used as a killable subprocess by the conformance runner (a Python process is
trivially killable, sidestepping the goroutine-leak problem the Go runner has to
work around). Bootstraps the sibling ``ballrt`` runtime and the generated
protobuf bindings onto ``sys.path`` so it runs from a plain checkout.

Exit codes: 0 = ran (output on stdout); 1 = a Ball/runtime error (message on
stderr). The runner compares stdout to the golden regardless of exit code.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path


def _bootstrap_paths():
    here = Path(__file__).resolve()
    # .../python/engine/ball_engine/__main__.py -> repo root is 4 parents up.
    root = here.parents[3]
    for rel in ("python/runtime", "python/shared/gen", "python/engine"):
        p = str(root / rel)
        if p not in sys.path:
            sys.path.insert(0, p)


def main(argv) -> int:
    if len(argv) < 2:
        print("usage: python -m ball_engine <program.ball.json>", file=sys.stderr)
        return 2
    _bootstrap_paths()
    from ball_engine.driver import run_program_file

    timeout_ms = None
    env_t = os.environ.get("BALL_TIMEOUT_MS")
    if env_t:
        try:
            timeout_ms = int(env_t)
        except ValueError:
            timeout_ms = None

    try:
        out = run_program_file(argv[1], timeout_ms=timeout_ms)
    except BaseException as exc:  # noqa: BLE001 — surface message, non-zero exit
        sys.stdout.flush()
        print(str(exc), file=sys.stderr)
        return 1
    sys.stdout.write("\n".join(out))
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
