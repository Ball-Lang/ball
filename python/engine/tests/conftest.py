"""Shared fixtures for the engine suite: import paths + self-host source lookup.

The Python packages are isolated (no workspace manager), so the sibling sources
the engine needs — ``ballrt`` (runtime), ``ball.v1`` (generated protobuf
binding), and ``ball_compiler`` (which ``ball_engine.bootstrap`` calls) — are put
on ``sys.path`` here, exactly as the compiler/encoder/cli suites do.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]  # repo root
_PACKAGES = (
    ROOT / "python" / "engine",
    ROOT / "python" / "runtime",
    ROOT / "python" / "shared" / "gen",
    ROOT / "python" / "compiler",
)
for _p in _PACKAGES:
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

CONFORMANCE = ROOT / "tests" / "conformance"
EXAMPLES = ROOT / "examples"
SELFHOST_BUNDLE = ROOT / "python" / "engine" / "ball_engine" / "_selfhost" / "engine.ball.json.gz"
SELFHOST_JSON = ROOT / "dart" / "self_host" / "engine.ball.json"


def selfhost_source_available() -> bool:
    return SELFHOST_BUNDLE.exists() or SELFHOST_JSON.exists()


def require_selfhost_source() -> None:
    """Skip — or, in CI, FAIL — when no self-host engine source is present.

    A skip is right on a fresh developer checkout (the source is a gitignored
    Dart-toolchain artifact). It is wrong in CI, where the regen step ran and a
    silent skip would turn this gate into a no-op: set
    ``BALL_REQUIRE_SELFHOST_SOURCE=1`` there so an absent source is a failure.
    """
    if selfhost_source_available():
        return
    import os

    if os.environ.get("BALL_REQUIRE_SELFHOST_SOURCE") == "1":
        pytest.fail(
            "BALL_REQUIRE_SELFHOST_SOURCE=1 but neither "
            f"{SELFHOST_BUNDLE} nor {SELFHOST_JSON} exists — the self-host "
            "regeneration step did not run"
        )
    pytest.skip(
        "no self-host engine source (run `cd dart && dart run "
        "compiler/tool/gen_engine_json.dart`)"
    )


def read_golden(path: Path) -> str:
    """Read a golden as BYTES, normalising only CRLF -> LF.

    Never ``read_text``: Python's universal newlines would also collapse a
    semantic lone ``\\r`` a fixture legitimately prints, masking a real
    divergence (see .claude/rules/python.md).
    """
    return path.read_bytes().decode("utf-8").replace("\r\n", "\n")


@pytest.fixture
def conformance_dir() -> Path:
    return CONFORMANCE
