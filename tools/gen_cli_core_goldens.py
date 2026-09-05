#!/usr/bin/env python3
"""Copy the five canonical cli-core golden reports into tests/cli_core_goldens/.

The second half of the golden-regeneration pipeline (issue #570). The first half
is Dart's own emitter::

    cd dart && dart run cli/tool/gen_cli_parity_goldens.dart <tmp_dir>

which writes ``<stem>.{info,validate,tree,audit}.txt`` for EVERY conformance
fixture, carrying ``cli_core``'s raw report text with **no** trailing newline
(the C++ ``audit`` gate compares those raw bytes). Every `ball` CLI, however,
prints the report with one trailing newline (Dart ``writeln``, Go ``Fprintln``,
Python ``stdout.write(report + "\\n")``), so this script selects the five
parity fixtures and appends that byte — making each golden exactly what
``ball <verb> <fixture>`` writes to stdout.

Doing the selection here rather than with a ``dart run … > golden`` shell
redirect keeps the bytes UTF-8-exact on a non-UTF-8 Windows console.

Usage:  python tools/gen_cli_core_goldens.py <tmp_dir_from_gen_cli_parity_goldens>
"""

from __future__ import annotations

import sys
from pathlib import Path

#: The same slice dart/cli/test/cli_core_parity_test.dart and
#: rust/cli/tests/cli_core_parity.rs use — control flow, classes, cascades,
#: maps, sets.
FIXTURES = (
    "100_complex_control_flow",
    "101_simple_class",
    "111_cascade_operator",
    "116_map_iteration",
    "118_set_operations",
)

#: `version` is asserted directly against the compiled function (its whole logic
#: is "ball " + version); `audit` is not a Go/Python verb.
VERBS = ("info", "validate", "tree")


def repo_root() -> Path:
    d = Path(__file__).resolve().parent
    while d != d.parent:
        if (d / "proto" / "ball" / "v1" / "ball.proto").is_file():
            return d
        d = d.parent
    raise SystemExit("[goldens] not inside the ball repo (no proto/ball/v1/ball.proto)")


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        raise SystemExit(__doc__)
    src = Path(argv[0]).resolve()
    if not src.is_dir():
        raise SystemExit(f"[goldens] {src} is not a directory")
    out = repo_root() / "tests" / "cli_core_goldens"
    out.mkdir(parents=True, exist_ok=True)

    written = 0
    for fixture in FIXTURES:
        for verb in VERBS:
            raw = (src / f"{fixture}.{verb}.txt").read_bytes()
            # A vacuous golden would make the gates pass on nothing; and a \r in
            # the source would smuggle a platform artifact into a byte compare.
            if not raw:
                raise SystemExit(f"[goldens] {fixture}.{verb}.txt is empty")
            if b"\r" in raw:
                raise SystemExit(
                    f"[goldens] {fixture}.{verb}.txt contains a CR — regenerate it with "
                    "gen_cli_parity_goldens.dart (a shell redirect on a Windows console "
                    "rewrites newlines)"
                )
            (out / f"{fixture}.{verb}.txt").write_bytes(raw + b"\n")
            written += 1

    if written != len(FIXTURES) * len(VERBS):
        raise SystemExit(f"[goldens] wrote {written} files, expected {len(FIXTURES) * len(VERBS)}")
    print(f"[goldens] wrote {written} golden reports -> {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
