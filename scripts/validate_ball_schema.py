#!/usr/bin/env python3
"""Validates ball.schema.json against the real Ball-JSON corpus.

Usage:
    python scripts/validate_ball_schema.py [--verbose]

Validates every fixture under tests/conformance/*.ball.json (the corpus
tracked by docs/TESTING_STRATEGY.md) and, as a bonus, every hand-written
program under examples/**/*.ball.json, against the root of ball.schema.json
(a ball.v1.Program, optionally wrapped in a google.protobuf.Any envelope).

Exit code is 0 iff every file validates. This script IS the test for
GitHub issue #133 (ball.schema.json + BALL_JSON_SPEC.md) — see the LANE
description in that issue for the acceptance criterion.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

try:
    import jsonschema
    from jsonschema import Draft202012Validator
except ImportError:  # pragma: no cover
    print(
        "error: the 'jsonschema' package is required (pip install jsonschema)",
        file=sys.stderr,
    )
    sys.exit(2)


REPO_ROOT = Path(__file__).resolve().parent.parent
SCHEMA_PATH = REPO_ROOT / "ball.schema.json"
CORPUS_GLOBS = [
    "tests/conformance/*.ball.json",
    "examples/**/*.ball.json",
]


def load_schema() -> dict:
    with SCHEMA_PATH.open("r", encoding="utf-8") as f:
        return json.load(f)


def iter_corpus_files() -> list[Path]:
    seen: set[Path] = set()
    files: list[Path] = []
    for pattern in CORPUS_GLOBS:
        for path in sorted(REPO_ROOT.glob(pattern)):
            if path not in seen:
                seen.add(path)
                files.append(path)
    return files


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--verbose", "-v", action="store_true", help="print every file as it validates"
    )
    args = parser.parse_args()

    schema = load_schema()
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema)

    files = iter_corpus_files()
    if not files:
        print("error: no corpus files found — glob patterns matched nothing", file=sys.stderr)
        return 2

    failures: list[tuple[Path, str]] = []
    for path in files:
        rel = path.relative_to(REPO_ROOT)
        try:
            with path.open("r", encoding="utf-8") as f:
                instance = json.load(f)
        except json.JSONDecodeError as exc:
            failures.append((rel, f"invalid JSON: {exc}"))
            continue

        errors = sorted(validator.iter_errors(instance), key=lambda e: list(e.absolute_path))
        if errors:
            first = errors[0]
            loc = "/".join(str(p) for p in first.absolute_path) or "<root>"
            failures.append((rel, f"at {loc}: {first.message}"))
        elif args.verbose:
            print(f"OK    {rel}")

    total = len(files)
    passed = total - len(failures)
    print(f"\n{passed}/{total} files valid against ball.schema.json")

    if failures:
        print(f"\n{len(failures)} FAILURE(S):", file=sys.stderr)
        for rel, msg in failures:
            print(f"  FAIL {rel}: {msg}", file=sys.stderr)
        return 1

    print("All files valid.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
