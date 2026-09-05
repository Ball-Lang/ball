#!/usr/bin/env python3
"""Cross-CLI verb-set parity gate (issue #570, epic #361).

Every registry ships a `ball`, and #361's definition of done is that they all
expose the SAME verbs. That requirement lived only in prose: each language's CLI
suite asserts on the verbs THAT language implements, so a CLI which never had a
verb never failed anything — which is precisely how `go/cli` and `python/cli`
shipped without `info`/`validate`/`tree`/`version` for a whole release cycle
while every other gate stayed green.

This script turns the prose into an assertion. For each CLI named on the command
line it runs `--help`, extracts the verb set from the help text's Commands
block, and checks it against `tools/cli_verbs.json`:

* every portable verb the manifest does not list as `missing` for that CLI must
  be present — a CLI silently dropping (or never adding) a shared verb fails;
* every verb OUTSIDE the portable set must be declared in that CLI's `extras` —
  a CLI silently growing a target-specific verb fails, so the shared surface
  cannot erode from the other side either;
* every `missing` carve-out must still be genuinely missing — a carve-out cannot
  outlive the gap it documents.

Positive floors, so an empty or mis-wired run can never read as success:
the portable set must have at least four verbs, at least `--min-clis` CLIs must
be checked, and every CLI's extracted verb set must be non-empty.

Usage:

    python tools/check_cli_verb_parity.py \\
        --cli go=go/cli/ball --cli python="python -m ball_cli" [--min-clis 4]

Each `--cli` is `<name>=<command>`, where `<name>` keys into the manifest and
`<command>` is shell-split and run with `--help` appended, from the repo root
unless `--cwd` is given as `<name>:<dir>`.

Exit code 0 on parity, 1 on any divergence (with a report naming the CLI, the
verb, and the manifest entry that would accept it if the difference is
deliberate).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

#: A help text's verb-list section header: "Commands:", "COMMANDS",
#: "Subcommands:" — every CLI in this repo uses one of these (Dart's own runner,
#: Go/Python's usage constants, TS's USAGE template, clap's derive output for
#: Rust, and System.CommandLine's for C#).
_SECTION = re.compile(r"^\s*(commands|subcommands)\s*:?\s*$", re.IGNORECASE)

#: A verb token: lowercase, may contain digits and dashes (`round-trip`).
#: Continuation lines in a Commands block start with punctuation or prose, so
#: this filters them out without needing per-CLI parsing.
_VERB = re.compile(r"^[a-z][a-z0-9-]*$")


def repo_root() -> Path:
    d = Path(__file__).resolve().parent
    while d != d.parent:
        if (d / "proto" / "ball" / "v1" / "ball.proto").is_file():
            return d
        d = d.parent
    raise SystemExit("[verb-parity] not inside the ball repo (no proto/ball/v1/ball.proto)")


def extract_verbs(help_text: str) -> set[str]:
    """The verb set listed in a help text's Commands block.

    The block starts at the section header and ends at the first line that is
    neither blank nor indented (the next section, or trailing prose). Only the
    first token of an indented line is considered, and only when it looks like a
    verb — so a wrapped description line contributes nothing.
    """
    lines = help_text.splitlines()
    verbs: set[str] = set()
    in_block = False
    for line in lines:
        if _SECTION.match(line):
            in_block = True
            continue
        if not in_block:
            continue
        if not line.strip():
            continue  # a blank line inside the block is tolerated
        if not line.startswith((" ", "\t")):
            break  # unindented => the block is over
        token = line.split()[0]
        if _VERB.match(token):
            verbs.add(token)
    return verbs


def split_command(command: str) -> list[str]:
    """Shell-split a `--cli` command into argv.

    On Windows, POSIX-mode `shlex` treats the backslashes in a native path as
    escape characters and silently eats them (``C:\\Python\\python.exe`` becomes
    ``C:Pythonpython.exe``, which then "cannot be found"). Non-POSIX mode keeps
    them but leaves surrounding quotes attached, so they are stripped here. CI
    runs on Linux, but a developer reproducing the gate locally must get the
    same answer.
    """
    if os.name == "nt":
        return [token.strip('"') for token in shlex.split(command, posix=False)]
    return shlex.split(command)


def run_help(name: str, command: str, cwd: Path) -> str:
    argv = split_command(command) + ["--help"]
    # Resolve the program through PATH ourselves: on Windows a toolchain
    # front-end is often a .bat/.cmd shim, which subprocess will not find from a
    # bare name without a shell. Doing the lookup here keeps the call shell-free
    # (no quoting hazards) and behaves identically on Linux CI.
    resolved = shutil.which(argv[0])
    if resolved is not None:
        argv[0] = resolved
    try:
        proc = subprocess.run(
            argv, cwd=str(cwd), capture_output=True, text=True, timeout=600,
            env={**os.environ, "NO_COLOR": "1"},
        )
    except FileNotFoundError as ex:
        raise SystemExit(f"[verb-parity] {name}: cannot run {argv!r} in {cwd}: {ex}")
    except subprocess.TimeoutExpired as ex:
        raise SystemExit(f"[verb-parity] {name}: `--help` timed out: {ex}")
    # A CLI may print usage to stderr (several do for a bare invocation); accept
    # either stream, but insist the process succeeded — a crashed `--help` must
    # not be mistaken for "no verbs".
    if proc.returncode != 0:
        raise SystemExit(
            f"[verb-parity] {name}: `{' '.join(argv)}` exited {proc.returncode}\n"
            f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
        )
    return proc.stdout + "\n" + proc.stderr


def check(name: str, verbs: set[str], manifest: dict) -> list[str]:
    """Return the problems for one CLI (empty when it matches the manifest)."""
    portable = set(manifest["portable"])
    ignore = set(manifest.get("ignore", []))
    entry = manifest["clis"].get(name)
    if entry is None:
        return [
            f"{name}: not declared in tools/cli_verbs.json — add an entry with its "
            f"extras/missing before wiring it into the gate"
        ]
    extras = set(entry.get("extras", []))
    missing = set(entry.get("missing", []))
    verbs = verbs - ignore

    problems: list[str] = []
    if not verbs:
        problems.append(f"{name}: extracted NO verbs from --help — the scrape is broken")

    for verb in sorted((portable - missing) - verbs):
        problems.append(
            f"{name}: missing the portable verb {verb!r} "
            f"(add it to the CLI, or declare it under clis.{name}.missing with a reason)"
        )
    for verb in sorted(verbs - portable - extras):
        problems.append(
            f"{name}: exposes {verb!r}, which is neither portable nor declared "
            f"(promote it to `portable` for every CLI, or declare it under clis.{name}.extras)"
        )
    for verb in sorted(missing & verbs):
        problems.append(
            f"{name}: declares {verb!r} as missing but the CLI now exposes it — "
            f"remove it from clis.{name}.missing (or promote the whole set)"
        )
    return problems


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--cli", action="append", default=[], metavar="NAME=COMMAND",
        help="a CLI to check; COMMAND is run with --help appended",
    )
    parser.add_argument(
        "--cwd", action="append", default=[], metavar="NAME:DIR",
        help="run NAME's command from DIR (relative to the repo root)",
    )
    parser.add_argument(
        "--min-clis", type=int, default=1,
        help="fail unless at least this many CLIs were checked (positive floor)",
    )
    parser.add_argument(
        "--manifest", default=None, metavar="PATH",
        help="the verb-set contract to check against (default: tools/cli_verbs.json). "
             "Used by this script's own self-test to drive synthetic contracts.",
    )
    args = parser.parse_args(argv)

    root = repo_root()
    manifest_path = Path(args.manifest) if args.manifest else root / "tools" / "cli_verbs.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

    portable = manifest.get("portable", [])
    # Positive floor on the contract itself: an emptied/truncated manifest must
    # not turn this gate into a no-op.
    if len(portable) < 4:
        print(
            f"[verb-parity] {manifest_path} declares only {len(portable)} portable "
            "verbs; the shared surface is at least run/compile/encode/check",
            file=sys.stderr,
        )
        return 1

    cwds: dict[str, Path] = {}
    for spec in args.cwd:
        name, _, directory = spec.partition(":")
        cwds[name] = root / directory

    if not args.cli:
        print("[verb-parity] no --cli given; nothing to check", file=sys.stderr)
        return 1

    problems: list[str] = []
    checked = 0
    for spec in args.cli:
        name, sep, command = spec.partition("=")
        if not sep or not command:
            print(f"[verb-parity] bad --cli spec {spec!r}; expected NAME=COMMAND", file=sys.stderr)
            return 1
        verbs = extract_verbs(run_help(name, command, cwds.get(name, root)))
        print(f"[verb-parity] {name}: {' '.join(sorted(verbs))}")
        problems.extend(check(name, verbs, manifest))
        checked += 1

    if checked < args.min_clis:
        print(
            f"[verb-parity] checked {checked} CLIs, expected at least {args.min_clis} — "
            "a shrunken run must not read as a pass",
            file=sys.stderr,
        )
        return 1

    if problems:
        print("", file=sys.stderr)
        for p in problems:
            print(f"[verb-parity] FAIL {p}", file=sys.stderr)
        return 1

    print(
        f"[verb-parity] OK: {checked} CLI(s), portable verb set "
        f"{{{', '.join(sorted(portable))}}} ({len(portable)} verbs) exposed by every one"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
