"""The four core verbs, one module each (mirrors ``rust/cli/src/commands/``).

Each module exposes ``command(args, stdout, stderr) -> int``: parse the verb's
own flags (a :class:`~ball_cli.argparse_util.StreamParser`), do the work writing
output to ``stdout``, and return 0 — raising :class:`~ball_cli.errors.CliError`
on any expected failure.
"""
