#!/usr/bin/env python3
"""Bundle the self-hosted CLI-core Ball source into the package, for the wheel.

The cli-core sibling of ``python/engine/tool/bundle_selfhost.py`` (issue #570).
``python -m build python/`` must produce a wheel whose ``ball info`` / ``validate``
/ ``tree`` / ``version`` work with no checkout and no Dart toolchain. The wheel
therefore ships the CLI core's Ball SOURCE (never the generated
``compiled_cli.py`` — the repo does not distribute generated code), which
:mod:`ball_cli.bootstrap_clicore` compiles into a user cache dir on first use.

This script gzips ``dart/self_host/cli.ball.json`` (itself a gitignored artifact
of ``dart run compiler/tool/gen_cli_json.dart``) into
``python/cli/ball_cli/_clicore/cli_core.ball.json.gz``, which
``[tool.setuptools.package-data]`` picks up. The output is a build artifact and
is gitignored like every other generated file.

Usage:  python python/cli/tool/bundle_cli_core.py [--check]

    --check  exit non-zero unless the bundle already exists and matches the
             current source (a drift guard for a release pipeline)
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import sys
from pathlib import Path


def repo_root() -> Path:
    d = Path(__file__).resolve().parent
    while d != d.parent:
        if (d / "proto" / "ball" / "v1" / "ball.proto").is_file():
            return d
        d = d.parent
    raise SystemExit("[bundle-cli] not inside the ball repo (no proto/ball/v1/ball.proto)")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify the bundle is present and current instead of writing it",
    )
    args = parser.parse_args(argv)

    root = repo_root()
    src = root / "dart" / "self_host" / "cli.ball.json"
    out = root / "python" / "cli" / "ball_cli" / "_clicore" / "cli_core.ball.json.gz"

    if not src.is_file():
        raise SystemExit(
            f"[bundle-cli] {src} is missing; regenerate the self-host source first:\n"
            f"             cd dart && dart run compiler/tool/gen_cli_json.dart"
        )
    raw = src.read_bytes()
    digest = hashlib.sha256(raw).hexdigest()

    if args.check:
        if not out.is_file():
            print(f"[bundle-cli] MISSING: {out}", file=sys.stderr)
            return 1
        if hashlib.sha256(gzip.decompress(out.read_bytes())).hexdigest() != digest:
            print(f"[bundle-cli] STALE: {out} does not match {src}", file=sys.stderr)
            return 1
        print(f"[bundle-cli] up to date: {out}")
        return 0

    out.parent.mkdir(parents=True, exist_ok=True)
    # mtime=0 so repeated runs on the same source are byte-identical.
    out.write_bytes(gzip.compress(raw, compresslevel=9, mtime=0))
    print(
        f"[bundle-cli] {src} ({len(raw)} bytes) -> {out} ({out.stat().st_size} bytes, "
        f"sha256 {digest[:16]}…)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
