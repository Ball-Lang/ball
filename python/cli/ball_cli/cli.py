"""``ball`` — the Ball language CLI for the Python toolchain (epic #445 Phase 5).

The four core verbs ``run`` / ``compile`` / ``encode`` / ``check`` over
``python/engine``, ``python/compiler``, and ``python/encoder``. The verb surface
mirrors the Go (``go/cli``), Rust (``rust/cli``), and C# (``csharp/cli``) CLIs'
core four; the self-hosted cli-core verbs those targets added later
(``info``/``validate``/``tree``/``version``) are a deliberate follow-up — see
``python/cli/AGENTS.md``.

All logic lives here (and in ``commands/``) so the whole CLI is exercisable
in-process by the tests through :func:`run`, without spawning a subprocess;
``__main__`` is a thin ``sys.exit(run(sys.argv[1:], sys.stdout, sys.stderr))``.
"""

from __future__ import annotations

from typing import TextIO

from .argparse_util import HelpRequested
from .commands import check as check_cmd
from .commands import compile as compile_cmd
from .commands import encode as encode_cmd
from .commands import run as run_cmd
from .errors import EXIT_OK, EXIT_USAGE, CliError
from .paths import bootstrap_sys_path

_USAGE = """\
ball — the Ball language CLI (Python toolchain)

Usage:
  ball <command> [arguments]

Commands:
  run      <program.ball.json>   Execute a Ball program via the self-hosted engine
                                 (needs the generated compiled_engine.py — regenerate
                                 with: python -m ball_engine.regen)
  compile  <program.ball.json>   Compile a Ball program to Python source     [-o out.py]
  encode   <source.py>           Encode a Python source file into a Ball program [-o out.ball.json]
  check    <program.ball.json>   Parse and validate a Ball program without running it [--compile]

Programs are read as proto3 JSON (.ball.json / .json), optionally wrapped in a
google.protobuf.Any @type envelope.

Exit codes: 0 success · 1 runtime error · 2 invalid program / usage · 3 I/O error.
"""

_HANDLERS = {
    "run": run_cmd.command,
    "compile": compile_cmd.command,
    "encode": encode_cmd.command,
    "check": check_cmd.command,
}


def run(argv: list[str], stdout: TextIO, stderr: TextIO) -> int:
    """Dispatch ``argv`` (the arguments after the program name) to a subcommand
    and return the process exit code.

    A command's own output (compiled source, encoded program, run output, check
    summary) goes to ``stdout``; diagnostics go to ``stderr``. Every expected
    failure is raised as a :class:`~ball_cli.errors.CliError` and reported here as
    ``ball: <message>`` — a genuine bug propagates as a traceback, never a stray
    error class dumped at the user.
    """
    bootstrap_sys_path()
    try:
        return _dispatch(argv, stdout, stderr)
    except HelpRequested:
        return EXIT_OK
    except CliError as ex:
        if ex.message:
            print(f"ball: {ex.message}", file=stderr)
        return ex.code


def _dispatch(argv: list[str], stdout: TextIO, stderr: TextIO) -> int:
    if not argv:
        stderr.write(_USAGE)
        return EXIT_USAGE

    cmd, rest = argv[0], argv[1:]
    if cmd in ("-h", "--help", "help"):
        stdout.write(_USAGE)
        return EXIT_OK

    handler = _HANDLERS.get(cmd)
    if handler is None:
        print(f"ball: unknown command {cmd!r}\n", file=stderr)
        stderr.write(_USAGE)
        return EXIT_USAGE

    return handler(rest, stdout, stderr)
