"""Whole-corpus conformance sweep for the self-hosted Python engine.

Drives every ``tests/conformance/*.ball.json`` fixture through the compiled
engine and compares stdout to its ``.expected_output.txt`` golden, printing the
CI-parseable::

    Results: N passed, M failed, T total (K skipped carve-outs)

plus a ``FAILING [name] status detail`` line per non-passing fixture.

Each fixture runs as its own ``python -m ball_engine`` **subprocess** with a
per-fixture timeout, so a runaway (infinite loop / unbounded recursion) is simply
killed — a Python process is trivially killable, which sidesteps the goroutine
-leak problem the Go runner has to work around cooperatively. Fixtures run in
parallel (subprocess.run releases the GIL while waiting) to keep the ~320-fixture
sweep well under the wall-clock budget.

A fixture with no golden is a documented carve-out and is skipped (the same 4
resource-limit/sandbox fixtures Rust/C#/Go skip). ``BALL_FIXTURE=<name>`` runs a
single fixture with a full diff.
"""

from __future__ import annotations

import concurrent.futures
import glob
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

CARVEOUTS = {"196_timeout", "197_memory_limit", "201_input_validation", "202_sandbox_mode"}

_HERE = Path(__file__).resolve()
_ENGINE_DIR = _HERE.parents[1]                 # python/engine
_REPO_ROOT = _HERE.parents[3]                  # repo root
_CONFORMANCE = _REPO_ROOT / "tests" / "conformance"

# Per-fixture wall-clock budget (subprocess kill). Overridable for fast sweeps.
_TIMEOUT_S = float(os.environ.get("BALL_TIMEOUT_S", "120"))
# Cooperative execution-timeout the engine self-aborts at, a hair under the kill.
_ENGINE_TIMEOUT_MS = int(_TIMEOUT_S * 1000) - 5000
_WORKERS = int(os.environ.get("BALL_WORKERS", str(min(8, (os.cpu_count() or 4)))))


@dataclass
class Result:
    name: str
    status: str   # pass | fail | timeout | error
    detail: str = ""


@dataclass
class Summary:
    passed: int = 0
    failed: int = 0
    total: int = 0
    skipped: int = 0
    results: list = None


def _run_one(name: str, path: str, golden: str) -> Result:
    env = dict(os.environ)
    env["BALL_TIMEOUT_MS"] = str(max(1000, _ENGINE_TIMEOUT_MS))
    try:
        proc = subprocess.run(
            [sys.executable, "-m", "ball_engine", path],
            cwd=str(_ENGINE_DIR),
            env=env,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=_TIMEOUT_S,
        )
    except subprocess.TimeoutExpired:
        return Result(name, "timeout", f"killed after {_TIMEOUT_S:.0f}s")

    actual = proc.stdout.replace("\r\n", "\n").rstrip("\n")
    expected = golden.replace("\r\n", "\n").rstrip("\n")
    if actual == expected:
        return Result(name, "pass")
    if proc.returncode != 0:
        err = (proc.stderr or "").strip().splitlines()
        detail = err[-1] if err else "non-zero exit"
        if "Execution timeout exceeded" in (proc.stderr or ""):
            return Result(name, "timeout", "execution timeout")
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
    paths = sorted(glob.glob(str(_CONFORMANCE / "*.ball.json")))
    jobs = []
    skipped = 0
    for path in paths:
        name = Path(path).name[: -len(".ball.json")]
        if only and name != only:
            continue
        golden_path = path[: -len(".ball.json")] + ".expected_output.txt"
        if not os.path.exists(golden_path):
            skipped += 1
            continue
        golden = Path(golden_path).read_text(encoding="utf-8")
        jobs.append((name, path, golden))

    results: list[Result] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=_WORKERS) as ex:
        futs = {ex.submit(_run_one, n, p, g): n for (n, p, g) in jobs}
        for fut in concurrent.futures.as_completed(futs):
            results.append(fut.result())

    results.sort(key=lambda r: r.name)
    s = Summary(results=results, skipped=skipped)
    for r in results:
        s.total += 1
        if r.status == "pass":
            s.passed += 1
        else:
            s.failed += 1
    return s


def main() -> int:
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
