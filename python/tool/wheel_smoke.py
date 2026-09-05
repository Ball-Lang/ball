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
2. `python -m build python/` - BOTH artifacts, exactly what publish-pypi.yml
   uploads; each is checked to carry the engine source and no generated module
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
import tarfile
import tempfile
import zipfile
from pathlib import Path

FIXTURE = ("tests", "conformance", "100_complex_control_flow.ball.json")
GOLDEN = ("tests", "conformance", "100_complex_control_flow.expected_output.txt")
ENCODE_SOURCE = ("python", "encoder", "tests", "testdata", "fizzbuzz.py")
#: The cli-core verbs' goldens, shared with the Go/Python parity gates
#: (tests/cli_core_goldens/README.md). FIXTURE's stem names them.
CLI_CORE_GOLDEN_DIR = ("tests", "cli_core_goldens")
CLI_CORE_VERBS = ("info", "validate", "tree")


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
    # Clear dist/ AND build/: setuptools' build_py only copies files that are
    # missing or newer, so a stale build/lib/ from an earlier build (one made
    # before python/setup.py's generated-module filter, or before a regen) would
    # be packaged as-is and leak the generated engine into the wheel.
    for stale in (dist, root / "python" / "build", root / "python" / "ball_lang.egg-info"):
        if stale.exists():
            shutil.rmtree(stale)

    run([sys.executable, str(root / "python" / "engine" / "tool" / "bundle_selfhost.py")])
    run([sys.executable, str(root / "python" / "cli" / "tool" / "bundle_cli_core.py")])
    # Build BOTH artifacts, because publish-pypi.yml uploads both: a wheel-only
    # check would leave the sdist (what `pip install --no-binary` uses) unverified.
    run([sys.executable, "-m", "build", str(root / "python")])

    wheels = sorted(dist.glob("ball_lang-*.whl"))
    if len(wheels) != 1:
        raise SystemExit(f"[smoke] expected exactly one wheel in {dist}, found {len(wheels)}")
    sdists = sorted(dist.glob("ball_lang-*.tar.gz"))
    if len(sdists) != 1:
        raise SystemExit(f"[smoke] expected exactly one sdist in {dist}, found {len(sdists)}")
    wheel, sdist = wheels[0], sdists[0]
    print(f"[smoke] built {wheel.name} ({wheel.stat().st_size} bytes) "
          f"and {sdist.name} ({sdist.stat().st_size} bytes)")

    # Both artifacts must carry the engine SOURCE and NOT the generated module.
    # A tree that has run `python -m ball_engine.regen` (every CI job with a
    # conformance sweep) has compiled_engine.py sitting inside the package
    # directory, and a plain `packages = [...]` sweep would ship it — see
    # python/setup.py's build_py filter, which this asserts.
    with zipfile.ZipFile(wheel) as zf:
        wheel_names = set(zf.namelist())
    with tarfile.open(sdist) as tf:
        # Strip the "ball_lang-<version>/" prefix every sdist member carries.
        sdist_names = {name.split("/", 1)[-1] for name in tf.getnames()}
    for label, names, generated, bundled in (
        (
            "wheel",
            wheel_names,
            "ball_engine/compiled_engine.py",
            "ball_engine/_selfhost/engine.ball.json.gz",
        ),
        (
            "sdist",
            sdist_names,
            "engine/ball_engine/compiled_engine.py",
            "engine/ball_engine/_selfhost/engine.ball.json.gz",
        ),
        (
            "wheel",
            wheel_names,
            "ball_cli/compiled_cli.py",
            "ball_cli/_clicore/cli_core.ball.json.gz",
        ),
        (
            "sdist",
            sdist_names,
            "cli/ball_cli/compiled_cli.py",
            "cli/ball_cli/_clicore/cli_core.ball.json.gz",
        ),
    ):
        if generated in names:
            raise SystemExit(
                f"[smoke] the {label} ships the GENERATED {generated} — it must ship only "
                "the engine source (python/setup.py's build_py filter is not working)"
            )
        if bundled not in names:
            raise SystemExit(
                f"[smoke] the {label} is missing {bundled} — `ball run` would have nothing "
                "to compile ([tool.setuptools.package-data] or bundle_selfhost.py)"
            )
        print(f"[smoke] {label} carries {bundled} and not {generated}")

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

        # The cli-core verbs (issue #570). Same bootstrap story as `run`: no
        # compiled_cli.py is shipped, so the first one compiles the bundled Ball
        # source into BALL_CACHE_DIR. Each report is compared to the checked-in
        # golden as BYTES, so this proves the WHEEL's verbs are byte-identical to
        # the Dart CLI - not merely non-empty.
        stem = FIXTURE[-1].removesuffix(".ball.json")
        checked = 0
        for verb in CLI_CORE_VERBS:
            produced = subprocess.run(
                [str(ball), verb, str(fixture)], check=True, capture_output=True, env=env
            ).stdout
            golden_path = root.joinpath(*CLI_CORE_GOLDEN_DIR, f"{stem}.{verb}.txt")
            expected_report = normalize(golden_path.read_bytes())
            if not expected_report:
                raise SystemExit(f"[smoke] golden {golden_path} is empty - a vacuous comparison")
            if normalize(produced) != expected_report:
                raise SystemExit(
                    f"[smoke] `ball {verb}` differs from {golden_path.name}\n"
                    f"  actual:   {normalize(produced)!r}\n"
                    f"  expected: {expected_report!r}"
                )
            checked += 1
            print(f"[smoke] ball {verb} -> matches {golden_path.name}")

        version_verb = subprocess.run(
            [str(ball), "version"], check=True, capture_output=True, env=env
        ).stdout
        if not normalize(version_verb).startswith("ball "):
            raise SystemExit(f"[smoke] `ball version` printed {normalize(version_verb)!r}")
        checked += 1
        print(f"[smoke] ball version -> {normalize(version_verb)}")

        # Positive floor: a loop that silently ran zero verbs must not pass.
        if checked != len(CLI_CORE_VERBS) + 1 or checked < 4:
            raise SystemExit(f"[smoke] exercised {checked} cli-core verbs, expected 4")

        cached_cli = list((workdir / "cache").rglob("compiled_cli.py"))
        if len(cached_cli) != 1:
            raise SystemExit(
                f"[smoke] expected one cache-compiled CLI core under {workdir / 'cache'}, "
                f"found {len(cached_cli)}"
            )
        print(f"[smoke] cli-core cache: {cached_cli[0]} ({cached_cli[0].stat().st_size} bytes)")

        print("[smoke] OK - wheel builds, installs standalone, and all nine verbs work")
        return 0
    finally:
        if args.keep:
            print(f"[smoke] kept {workdir}")
        else:
            shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
