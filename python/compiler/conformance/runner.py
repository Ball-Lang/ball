"""Whole-corpus COMPILE leg for the Ball -> Python compiler.

The engine leg (``python/engine/conformance/runner.py``) sweeps the corpus
through the self-hosted *engine*. This is the other half: it sweeps the same
corpus through the Ball -> **Python compiler**, i.e. it answers "how much of the
language can we actually *emit* Python for, and does that Python print the
golden?" — a claim nothing measured before.

Per fixture:

1. ``load_program`` + ``compile_program`` -> Python source (the compiler is
   fail-loud by design: an unsupported construct raises ``CompileError``).
2. Write the source to a temp ``.py`` and run it as its own subprocess
   (``PYTHONPATH=python/runtime`` so the emitted ``import ballrt`` resolves),
   with a per-fixture timeout so one runaway fixture cannot wedge the sweep.
3. Byte-compare stdout to the ``.expected_output.txt`` golden.

Prints the CI-parseable::

    Results: N passed, M failed, T total (K skipped carve-outs)

plus a ``FAILING [name] status detail`` line per non-passing fixture.

**A fixture the compiler cannot emit is a FAILURE, not a crash.** The leg's job
is an honest count, so a ``CompileError`` is recorded as ``compile-error`` and
folded into ``failed`` — never skipped, never silently green. Only the four
documented golden-less carve-outs (196/197/201/202) are skipped, exactly as
every other runner skips them.

**Bytes, not text.** Goldens *and* subprocess stdout are read as bytes and only
``\\r\\n`` -> ``\\n`` is normalised. Python's text mode would collapse a lone
``\\r`` (a semantic character several fixtures print) to ``\\n`` on *both* sides,
which has silently corrupted golden comparison in this repo before.

Env knobs: ``BALL_FIXTURE=<name>`` (single fixture, full diff),
``BALL_TIMEOUT_S`` (per-fixture kill, default 60), ``BALL_WORKERS``,
``BALL_KEEP_SOURCE=1`` (keep the emitted .py files for debugging).
"""

from __future__ import annotations

import concurrent.futures
import glob
import os
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

CARVEOUTS = {"196_timeout", "197_memory_limit", "201_input_validation", "202_sandbox_mode"}

_HERE = Path(__file__).resolve()
_COMPILER_DIR = _HERE.parents[1]               # python/compiler
_PYTHON_DIR = _HERE.parents[2]                 # python
_REPO_ROOT = _HERE.parents[3]                  # repo root
_RUNTIME_DIR = _PYTHON_DIR / "runtime"
_CONFORMANCE = _REPO_ROOT / "tests" / "conformance"

if str(_COMPILER_DIR) not in sys.path:
    sys.path.insert(0, str(_COMPILER_DIR))

from ball_compiler import compile_program, load_program  # noqa: E402

_TIMEOUT_S = float(os.environ.get("BALL_TIMEOUT_S", "60"))
_WORKERS = int(os.environ.get("BALL_WORKERS", str(min(8, (os.cpu_count() or 4)))))
_KEEP_SOURCE = os.environ.get("BALL_KEEP_SOURCE") == "1"


@dataclass
class Result:
    name: str
    status: str   # pass | fail | compile-error | timeout | error
    detail: str = ""


@dataclass
class Summary:
    passed: int = 0
    failed: int = 0
    total: int = 0
    skipped: int = 0
    results: list = None


def _normalize(raw: bytes) -> str:
    """Decode UTF-8 and normalise ONLY CRLF -> LF.

    A lone CR is a legitimate program output (fixture 249 prints one); text-mode
    universal newlines would collapse it to LF and make a wrong answer compare
    equal — or a right answer compare unequal. Bytes in, one substitution, done.
    """
    return raw.decode("utf-8", errors="replace").replace("\r\n", "\n")


def _run_one(name: str, path: str, golden: bytes, workdir: str) -> Result:
    # 1. Compile. Fail-loud (#55): an unsupported construct raises. That is a
    #    FAILURE of this leg, not a crash of the sweep.
    try:
        source = compile_program(load_program(path))
    except Exception as ex:  # CompileError, KeyError, RecursionError, …
        msg = " / ".join(f"{type(ex).__name__}: {ex}".splitlines())
        return Result(name, "compile-error", msg[:200])

    out_py = os.path.join(workdir, f"{name}.py")
    with open(out_py, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(source)

    # 2. Run the emitted module as its own process (killable timeout).
    env = dict(os.environ)
    existing = env.get("PYTHONPATH")
    env["PYTHONPATH"] = (
        str(_RUNTIME_DIR) + (os.pathsep + existing if existing else "")
    )
    env["PYTHONIOENCODING"] = "utf-8"
    try:
        proc = subprocess.run(
            [sys.executable, out_py],
            cwd=workdir,
            env=env,
            stdin=subprocess.DEVNULL,
            capture_output=True,   # bytes: no text=True, no newline translation
            timeout=_TIMEOUT_S,
        )
    except subprocess.TimeoutExpired:
        return Result(name, "timeout", f"killed after {_TIMEOUT_S:.0f}s")

    # 3. Byte-compare against the golden.
    actual = _normalize(proc.stdout).rstrip("\n")
    expected = _normalize(golden).rstrip("\n")
    if actual == expected:
        return Result(name, "pass")

    if proc.returncode != 0:
        err = _normalize(proc.stderr).strip().splitlines()
        detail = err[-1] if err else f"non-zero exit ({proc.returncode})"
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
        golden_path = path[: -len(".ball.json")] + ".expected_output.txt"
        if not os.path.exists(golden_path):
            skipped += 1          # documented carve-out (no golden) — never counted
            continue
        if only and name != only:
            continue
        jobs.append((name, path, Path(golden_path).read_bytes()))

    workdir = tempfile.mkdtemp(prefix="ball_pycompile_")
    results: list[Result] = []
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=_WORKERS) as ex:
            futs = [ex.submit(_run_one, n, p, g, workdir) for (n, p, g) in jobs]
            for fut in concurrent.futures.as_completed(futs):
                results.append(fut.result())
    finally:
        if not _KEEP_SOURCE:
            import shutil
            shutil.rmtree(workdir, ignore_errors=True)
        else:
            print(f"emitted sources kept in {workdir}", file=sys.stderr)

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
