"""Whole-corpus ROUND-TRIP leg for the Python target (issue #452 item 3).

The engine leg (``runner.py``) sweeps the corpus through the self-hosted Python
engine; ``python/compiler/conformance/runner.py`` sweeps it through the Ball ->
Python compiler. This is the third question: **can the Python encoder read back
what the Python compiler emits?**

Per fixture:

1. ``load_program`` + ``compile_program`` -> Python source (``python/compiler``).
2. ``ball_encoder.encode`` that source back into a Ball program
   (``python/encoder``).
3. Run the **RE-ENCODED** program on the **Dart reference engine**
   (``dart run dart/cli/bin/ball.dart run <reencoded.ball.json>``). Ground truth
   on purpose: running it on Python's own engine would only prove the Python
   pipeline agrees with itself.
4. Byte-compare stdout to the fixture's ``.expected_output.txt`` golden.

Prints the CI-parseable::

    Results: N passed, M failed, T total (K skipped carve-outs)

plus a ``FAILING [name] status detail`` line per non-passing fixture.

**A near-zero baseline is the honest, expected answer, not a bug.** The compiler
emits a flat module dispatching through ``ballrt.*`` helpers over Ball runtime
values; the encoder is a syntactic, ``ast``-based reader built for idiomatic
hand-written Python. Neither was ever designed to meet in the middle. The C#
analogue (``csharp/engine/conformance/RoundTripLeg.cs``, the row this leg
mirrors) measures exactly 0. This leg exists to keep that number **live and
honest**, not to be made green by weakening either side — raising it is
encoder/compiler work tracked elsewhere.

**No PR gate.** The ``python-roundtrip`` row lives in
``.github/workflows/conformance-matrix.yml``, which has **no** ``pull_request``
trigger — it runs on push-to-main, the weekly schedule, or manual dispatch. An
absent check on a PR is not a green one.

**Bytes, not text.** Goldens *and* subprocess stdout are read as bytes and only
``\\r\\n`` -> ``\\n`` is normalised. Python's text mode would collapse a lone
``\\r`` (a semantic character several fixtures print) on *both* sides, which has
silently corrupted golden comparison in this repo before.

Env knobs: ``BALL_FIXTURE=<name>`` (single fixture, full diff),
``BALL_TIMEOUT_S`` (per-fixture Dart-run kill, default 60), ``BALL_WORKERS``,
``BALL_DART`` (the Dart executable, default ``dart``).
"""

from __future__ import annotations

import concurrent.futures
import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

CARVEOUTS = {"196_timeout", "197_memory_limit", "201_input_validation", "202_sandbox_mode"}

_HERE = Path(__file__).resolve()
_PYTHON_DIR = _HERE.parents[2]                 # python
_REPO_ROOT = _HERE.parents[3]                  # repo root
_CONFORMANCE = _REPO_ROOT / "tests" / "conformance"
_BALL_DART = _REPO_ROOT / "dart" / "cli" / "bin" / "ball.dart"

# This module is run as `python -m conformance.roundtrip` from `python/engine`,
# so its sibling packages are not importable by default (each Python package
# here is isolated — see python/AGENTS.md).
for _sibling in ("compiler", "encoder"):
    _path = str(_PYTHON_DIR / _sibling)
    if _path not in sys.path:
        sys.path.insert(0, _path)

from ball_compiler import compile_program, load_program  # noqa: E402
from ball_encoder import encode  # noqa: E402

_TIMEOUT_S = float(os.environ.get("BALL_TIMEOUT_S", "60"))
_WORKERS = int(os.environ.get("BALL_WORKERS", str(min(8, (os.cpu_count() or 4)))))
_DART = os.environ.get("BALL_DART", "dart")


@dataclass
class Result:
    name: str
    status: str   # pass | fail | compile-error | encode-error | timeout | error
    detail: str = ""


@dataclass
class Summary:
    passed: int = 0
    failed: int = 0
    total: int = 0
    skipped: int = 0
    results: list = None


def _normalize(raw: bytes) -> str:
    """Decode UTF-8 and normalise ONLY CRLF -> LF (never text mode)."""
    return raw.decode("utf-8", errors="replace").replace("\r\n", "\n")


def _dart_executable() -> str:
    """Resolve the Dart launcher to a full path.

    On Windows the `dart` on PATH is often a shim whose extension CreateProcess
    will not discover on its own, so resolve it here rather than let a fixture
    fail with a misleading "cannot find the file" — the same trap
    ``RoundTripLeg.cs`` documents for .NET's ``Process.Start``.
    """
    resolved = shutil.which(_DART)
    if resolved is None:
        raise RuntimeError(
            f"the Dart reference engine is required for the round-trip leg but "
            f"'{_DART}' is not on PATH (set BALL_DART to its full path)"
        )
    return resolved


def _run_one(name: str, path: str, golden: bytes, dart: str, workdir: str) -> Result:
    # 1. Ball -> Python (fail-loud by design; a scope gap is a FAILURE here).
    try:
        source = compile_program(load_program(path))
    except Exception as ex:  # CompileError, KeyError, RecursionError, …
        msg = " / ".join(f"{type(ex).__name__}: {ex}".splitlines())
        return Result(name, "compile-error", msg[:200])

    # 2. Python -> Ball (the step that is expected to reject compiler-emitted
    #    shapes today — that rejection is the measurement).
    try:
        program = encode(source)
    except Exception as ex:  # EncodeError, SyntaxError, RecursionError, …
        msg = " / ".join(f"{type(ex).__name__}: {ex}".splitlines())
        return Result(name, "encode-error", msg[:200])

    # 3. Serialize as the `@type`-enveloped `.ball.json` every Ball CLI reads.
    ball_json = os.path.join(workdir, f"{name}.ball.json")
    try:
        envelope = {"@type": "type.googleapis.com/ball.v1.Program", **program}
        with open(ball_json, "w", encoding="utf-8", newline="\n") as fh:
            json.dump(envelope, fh)
    except Exception as ex:
        return Result(name, "error", f"serialize: {type(ex).__name__}: {ex}"[:200])

    # 4. Run the RE-ENCODED program on the Dart reference engine (ground truth).
    try:
        proc = subprocess.run(
            [dart, "run", str(_BALL_DART), "run", ball_json],
            cwd=str(_REPO_ROOT),
            stdin=subprocess.DEVNULL,
            capture_output=True,   # bytes: no text=True, no newline translation
            timeout=_TIMEOUT_S,
        )
    except subprocess.TimeoutExpired:
        return Result(name, "timeout", f"killed after {_TIMEOUT_S:.0f}s")

    actual = _normalize(proc.stdout).rstrip("\n")
    expected = _normalize(golden).rstrip("\n")
    if actual == expected:
        return Result(name, "pass")

    if proc.returncode != 0:
        err = _normalize(proc.stderr).strip().splitlines()
        detail = err[-1] if err else f"dart run exited {proc.returncode}"
        return Result(name, "error", detail[:200])

    el = expected.split("\n")
    al = actual.split("\n")
    if os.environ.get("BALL_FIXTURE"):
        detail = (f"\n--- expected ({len(el)}) ---\n{expected}"
                  f"\n--- actual ({len(al)}) ---\n{actual}")
    else:
        exp0 = el[0] if el else "<none>"
        act0 = al[0] if al else "<none>"
        detail = f"expected({len(el)}): {exp0} | actual({len(al)}): {act0}"
    return Result(name, "fail", detail)


def run_all(only: str = "") -> Summary:
    dart = _dart_executable()
    paths = sorted(glob.glob(str(_CONFORMANCE / "*.ball.json")))
    jobs = []
    skipped = 0
    for path in paths:
        name = Path(path).name[: -len(".ball.json")]
        golden_path = path[: -len(".ball.json")] + ".expected_output.txt"
        if not os.path.exists(golden_path):
            skipped += 1          # documented carve-out (no golden) — never counted
            continue
        if only and name != only:
            continue
        jobs.append((name, path, Path(golden_path).read_bytes()))

    workdir = tempfile.mkdtemp(prefix="ball_pyroundtrip_")
    results: list[Result] = []
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=_WORKERS) as ex:
            futs = [ex.submit(_run_one, n, p, g, dart, workdir) for (n, p, g) in jobs]
            for fut in concurrent.futures.as_completed(futs):
                results.append(fut.result())
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    results.sort(key=lambda r: r.name)
    s = Summary(results=results, skipped=skipped)
    for r in results:
        s.total += 1
        if r.status == "pass":
            s.passed += 1
        else:
            s.failed += 1

    # Positive floor. A sweep that ran nothing prints "0 passed, 0 failed, 0
    # total" and would read as green — an exit code plus a failure count cannot
    # tell "all passed" from "nothing ran". Refuse to report a vacuous pass.
    if s.total == 0:
        raise RuntimeError(
            "the round-trip leg ran zero fixtures — refusing to report a "
            "vacuous pass (check the fixture filter; the corpus has "
            "hundreds of golden-having fixtures)"
        )
    return s


def main() -> int:
    # Fixture output/diagnostics can be non-ASCII; a cp1252 Windows console would
    # otherwise kill the sweep with UnicodeEncodeError *after* it had done all the
    # work but *before* it printed the Results line.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass

    only = os.environ.get("BALL_FIXTURE", "")
    s = run_all(only)
    for r in s.results:
        if r.status != "pass":
            print(f"FAILING [{r.name}] {r.status} {r.detail}")
    print(f"Results: {s.passed} passed, {s.failed} failed, {s.total} total "
          f"({s.skipped} skipped carve-outs)")
    return 0 if s.failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
