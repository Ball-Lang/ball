#!/usr/bin/env python3
"""Bundle the self-host Ball engine source into the package, for the wheel.

`python -m build python/` must produce a wheel whose `ball run` works with no
checkout and no Dart toolchain. The wheel therefore ships the engine's Ball
SOURCE (never the generated compiled_engine.py — the repo does not distribute
generated code), which `ball_engine.bootstrap` compiles into a user cache dir on
first use.

This script gzips `dart/self_host/engine.ball.json` (itself a gitignored
artifact of `dart run compiler/tool/gen_engine_json.dart`) into
`python/engine/ball_engine/_selfhost/engine.ball.json.gz`, which
`[tool.setuptools.package-data]` picks up. The output is a build artifact and is
gitignored like every other generated file.

Usage:  python python/engine/tool/bundle_selfhost.py [--check]

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
    raise SystemExit("[bundle] not inside the ball repo (no proto/ball/v1/ball.proto)")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify the bundle is present and current instead of writing it",
    )
    args = parser.parse_args(argv)

    root = repo_root()
    src = root / "dart" / "self_host" / "engine.ball.json"
    out = root / "python" / "engine" / "ball_engine" / "_selfhost" / "engine.ball.json.gz"

    if not src.is_file():
        raise SystemExit(
            f"[bundle] {src} is missing; regenerate the self-host source first:\n"
            f"          cd dart && dart run compiler/tool/gen_engine_json.dart"
        )
    raw = src.read_bytes()
    digest = hashlib.sha256(raw).hexdigest()

    if args.check:
        if not out.is_file():
            print(f"[bundle] MISSING: {out}", file=sys.stderr)
            return 1
        if hashlib.sha256(gzip.decompress(out.read_bytes())).hexdigest() != digest:
            print(f"[bundle] STALE: {out} does not match {src}", file=sys.stderr)
            return 1
        print(f"[bundle] up to date: {out}")
        return 0

    out.parent.mkdir(parents=True, exist_ok=True)
    # mtime=0 so repeated runs on the same source are byte-identical.
    out.write_bytes(gzip.compress(raw, compresslevel=9, mtime=0))
    print(
        f"[bundle] {src} ({len(raw)} bytes) -> {out} ({out.stat().st_size} bytes, "
        f"sha256 {digest[:16]}…)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
