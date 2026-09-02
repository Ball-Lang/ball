#!/usr/bin/env python3
"""Build the `ball-lang` wheel, install it into a clean venv, and use it.

The five python/ packages are consumed from a checkout through a sys.path
bootstrap, so every existing gate can only prove "the checkout works". This
script proves the thing a user actually gets (issue #496): a wheel, installed
into an empty virtual environment **outside the repository**, with no repo path
on PYTHONPATH, running all four verbs plus `--version` — including `ball run`,
which exercises the compile-on-first-use engine bootstrap against a cache dir it
creates itself.

Steps:

1. `python/engine/tool/bundle_selfhost.py`   (package the Ball engine source)
2. `python -m build --wheel python/`
3. create a venv in a temp dir, `pip install <wheel>`
4. `ball --version`, `ball check`, `ball compile`, `ball encode`, `ball run`
5. assert `ball run`'s stdout equals the fixture's golden, compared as BYTES

Usage:  python python/tool/wheel_smoke.py [--keep]
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

FIXTURE = ("tests", "conformance", "100_complex_control_flow.ball.json")
GOLDEN = ("tests", "conformance", "100_complex_control_flow.expected_output.txt")
ENCODE_SOURCE = ("python", "encoder", "tests", "testdata", "fizzbuzz.py")


def repo_root() -> Path:
    d = Path(__file__).resolve().parent
    while d != d.parent:
        if (d / "proto" / "ball" / "v1" / "ball.proto").is_file():
            return d
        d = d.parent
    raise SystemExit("[smoke] not inside the ball repo (no proto/ball/v1/ball.proto)")


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    print(f"[smoke] $ {' '.join(str(c) for c in cmd)}", flush=True)
    return subprocess.run(cmd, check=True, **kwargs)


def clean_env() -> dict[str, str]:
    """The child environment: no PYTHONPATH, so nothing resolves to the checkout.

    Without this the installed wheel could be silently shadowed by the repo's own
    sources and the smoke would prove nothing.
    """
    env = dict(os.environ)
    env.pop("PYTHONPATH", None)
    env["PYTHONIOENCODING"] = "utf-8"
    return env


def normalize(raw: bytes) -> str:
    """Decode captured stdout / a golden, normalising ONLY CRLF -> LF.

    Never text mode: universal newlines would also collapse a semantic lone \\r a
    fixture legitimately prints (see .claude/rules/python.md).
    """
    return raw.decode("utf-8").replace("\r\n", "\n").rstrip("\n")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--keep", action="store_true", help="keep the temp venv for inspection")
    args = parser.parse_args(argv)

    root = repo_root()
    dist = root / "python" / "dist"
    if dist.exists():
        shutil.rmtree(dist)

    run([sys.executable, str(root / "python" / "engine" / "tool" / "bundle_selfhost.py")])
    run([sys.executable, "-m", "build", "--wheel", str(root / "python")])

    wheels = sorted(dist.glob("ball_lang-*.whl"))
    if len(wheels) != 1:
        raise SystemExit(f"[smoke] expected exactly one wheel in {dist}, found {len(wheels)}")
    wheel = wheels[0]
    print(f"[smoke] built {wheel.name} ({wheel.stat().st_size} bytes)")

    # OUTSIDE the repo: an in-tree venv would let ball_cli.paths / the engine
    # bootstrap find the checkout and mask a packaging defect.
    workdir = Path(tempfile.mkdtemp(prefix="ball-wheel-smoke-"))
    try:
        venv = workdir / "venv"
        run([sys.executable, "-m", "venv", str(venv)])
        bindir = venv / ("Scripts" if os.name == "nt" else "bin")
        py = bindir / ("python.exe" if os.name == "nt" else "python")
        ball = bindir / ("ball.exe" if os.name == "nt" else "ball")

        run([str(py), "-m", "pip", "install", "--quiet", str(wheel)], env=clean_env())
        if not ball.exists():
            raise SystemExit(f"[smoke] the wheel installed no `ball` console script at {ball}")

        env = clean_env()
        env["BALL_CACHE_DIR"] = str(workdir / "cache")

        version = subprocess.run(
            [str(ball), "--version"], check=True, capture_output=True, env=env
        ).stdout
        if not version.strip():
            raise SystemExit("[smoke] `ball --version` printed nothing")
        print(f"[smoke] ball --version -> {normalize(version)}")

        fixture = root.joinpath(*FIXTURE)
        run([str(ball), "check", str(fixture)], env=env)
        run([str(ball), "compile", str(fixture), "-o", str(workdir / "out.py")], env=env)
        run(
            [str(ball), "encode", str(root.joinpath(*ENCODE_SOURCE)), "-o",
             str(workdir / "out.ball.json")],
            env=env,
        )
        for produced in (workdir / "out.py", workdir / "out.ball.json"):
            if not produced.is_file() or produced.stat().st_size == 0:
                raise SystemExit(f"[smoke] {produced} was not written")

        # `ball run` is the real test of the bootstrap: no compiled_engine.py is
        # shipped, so this compiles the bundled source into BALL_CACHE_DIR first.
        result = subprocess.run(
            [str(ball), "run", str(fixture)], check=True, capture_output=True, env=env
        )
        actual = normalize(result.stdout)
        expected = normalize(root.joinpath(*GOLDEN).read_bytes())
        if not expected:
            raise SystemExit("[smoke] the golden is empty — the comparison would be vacuous")
        if actual != expected:
            raise SystemExit(f"[smoke] `ball run` output differs\n  actual:   {actual!r}\n"
                             f"  expected: {expected!r}")
        print(f"[smoke] ball run -> {actual!r} (matches the golden)")

        cached = list((workdir / "cache").rglob("compiled_engine.py"))
        if len(cached) != 1:
            raise SystemExit(
                f"[smoke] expected one cache-compiled engine under {workdir / 'cache'}, "
                f"found {len(cached)}"
            )
        print(f"[smoke] engine cache: {cached[0]} ({cached[0].stat().st_size} bytes)")
        print("[smoke] OK - wheel builds, installs standalone, and all five verbs work")
        return 0
    finally:
        if args.keep:
            print(f"[smoke] kept {workdir}")
        else:
            shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
