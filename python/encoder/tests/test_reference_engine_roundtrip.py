"""The Python round-trip guards' DART REFERENCE-ENGINE half (issue #785).

``test_ballrt_inverse.py`` and ``test_ballrt_namespaced.py`` prove that a Ball
fixture survives Ball -> Python -> Ball -> Python -> **run under ``ballrt``**,
byte-compared against the fixture's own golden. Every one of those runs happens
inside this process, on Python's own runtime. That is a real assertion about the
encoder's inverse — and it is structurally blind to one class of defect: a
re-encoded tree that ``ballrt`` evaluates happily and the **Dart reference
engine** rejects or answers differently. Nothing in the Python round-trip
pipeline ever ran ``dart``.

This module is the missing half. For every fixture those two suites certify, it
runs the ORIGINAL ``.ball.json`` and the RE-ENCODED program on the Dart
reference engine (``dart run dart/cli/bin/ball.dart run …``) and asserts the two
stdouts are identical — the same ground truth the whole-corpus
``python-roundtrip`` matrix row uses
(``python/engine/conformance/roundtrip.py``), brought into the fast in-package
suite so a regression is a failing ``pytest`` in the ``python`` CI job and not
only a moved floor on a row that runs elsewhere.

**The blind spot is not hypothetical**, and
:func:`test_the_reference_engine_sees_a_divergence_ballrt_cannot` is its
executable proof: ``ballrt.getfield`` answers ``None`` for an absent key
(``python/runtime/ballrt/values.py`` — proto3-default tolerance), while the
reference engine fails loud (``BallRuntimeError: Field "hi" not found``,
``dart/engine/lib/engine_eval.dart``). A re-encode that reads an absent key
under an absorbing operator therefore prints the golden under ``ballrt`` and
dies on the reference engine. This is the Python spelling of the exact defect
``csharp/encoder/test/ReferenceEngineExecutionTests.cs`` was written for
(issue #689/#730): ``BallRuntime.FieldGet`` answering ``BallValue.Null`` there,
``getfield`` answering ``None`` here.

**No skip.** These tests shell out to ``dart`` and an unresolvable ``dart`` is a
FAILURE, never a skip — a gate that quietly disappears on the machine lacking
its dependency is precisely the fake-green this module exists to prevent (the
#730/#764 precedent). Dart is this repo's reference implementation, so its SDK
plus a resolved workspace (``dart pub get`` at the repo root) is a prerequisite
of ``python/encoder``'s suite, and ``.github/workflows/ci.yml``'s ``python`` job
sets Dart up BEFORE its test steps for exactly this reason. ``BALL_DART``
overrides which executable is used; ``BALL_TIMEOUT_S`` the per-run kill.

**Bytes, not text.** Goldens *and* subprocess stdout are read as bytes and only
``\\r\\n`` -> ``\\n`` is normalised. Python's text mode collapses a lone ``\\r``
(a semantic character several fixtures print) on *both* sides, which has
silently corrupted golden comparison in this repo before.
"""

from __future__ import annotations

import concurrent.futures
import json
import os
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

import pytest
from ball_compiler import compile_program, load_program
from ball_encoder import encode

# The two ballrt-only round-trip suites are the SOURCE OF TRUTH for what this
# module must cover: anything they certify on Python's own runtime has to agree
# with the reference engine too, so the set is derived rather than hand-kept and
# a fixture added there is covered here on the same day. `_run_source` is
# imported rather than re-implemented — one definition of "execute compiled Ball
# Python in-process and capture stdout".
from test_ballrt_inverse import ROUND_TRIP_FIXTURES as _INVERSE_FIXTURES
from test_ballrt_inverse import _run_source
from test_ballrt_namespaced import ROUND_TRIP_FIXTURES as _NAMESPACED_FIXTURES

ROOT = Path(__file__).resolve().parents[3]
FIXTURES_DIR = ROOT / "tests" / "conformance"
BALL_CLI = ROOT / "dart" / "cli" / "bin" / "ball.dart"

#: Every fixture the two ballrt-only suites round-trip, deduplicated + ordered.
FIXTURES = tuple(sorted(set(_INVERSE_FIXTURES) | set(_NAMESPACED_FIXTURES)))

_TIMEOUT_S = float(os.environ.get("BALL_TIMEOUT_S", "180"))
_WORKERS = int(os.environ.get("BALL_WORKERS", str(min(8, (os.cpu_count() or 4)))))


def _normalize(raw: bytes) -> str:
    """Decode UTF-8 and normalise ONLY CRLF -> LF (never text mode)."""
    return raw.decode("utf-8", errors="replace").replace("\r\n", "\n")


@dataclass(frozen=True)
class _Run:
    """One reference-engine execution."""

    exit_code: int
    stdout: str
    stderr: str


@dataclass
class _Comparison:
    """The original vs. the re-encoded program, both on the reference engine."""

    name: str
    golden: str = ""
    error: str = ""
    original: _Run | None = None
    reencoded: _Run | None = None


def _require_dart() -> str:
    """Resolve the Dart launcher to a full path, failing loud when it is absent.

    On Windows the ``dart`` on PATH is often a shim whose extension
    ``CreateProcess`` will not discover on its own, so resolve it here rather
    than let every case fail with a misleading "cannot find the file" — the same
    trap ``roundtrip.py`` and ``RoundTripLeg.cs`` document.
    """
    requested = os.environ.get("BALL_DART", "dart")
    resolved = shutil.which(requested)
    if resolved is None:
        pytest.fail(
            f"the Dart reference engine is not available ('{requested}' is not "
            "on PATH). It is a prerequisite of this suite, not an optional "
            "extra: install the Dart SDK and run `dart pub get` at the repo "
            "root, or set BALL_DART to a specific executable. This is a "
            "FAILURE and never a skip — a comparison that silently disappears "
            "on the machine lacking its dependency is the fake-green this "
            "module exists to prevent (#730/#764/#785).",
            pytrace=False,
        )
    return resolved


def _run_on_reference_engine(dart: str, ball_json: Path) -> _Run:
    """Run one ``.ball.json`` on the Dart reference engine, reading BYTES."""
    try:
        proc = subprocess.run(
            [dart, "run", str(BALL_CLI), "run", str(ball_json)],
            cwd=str(ROOT),
            stdin=subprocess.DEVNULL,
            capture_output=True,  # bytes: no text=True, no newline translation
            timeout=_TIMEOUT_S,
        )
    except subprocess.TimeoutExpired:
        return _Run(-1, "", f"killed after {_TIMEOUT_S:g}s")
    return _Run(proc.returncode, _normalize(proc.stdout), _normalize(proc.stderr))


def _write_program(program: dict, path: Path) -> Path:
    """Serialize a Ball program as the ``@type``-enveloped JSON every CLI reads."""
    envelope = {"@type": "type.googleapis.com/ball.v1.Program", **program}
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(envelope, fh)
    return path


def _compare(name: str, dart: str, workdir: Path) -> _Comparison:
    """Ball fixture -> Python -> Ball, then run BOTH programs on the engine."""
    fixture = FIXTURES_DIR / f"{name}.ball.json"
    golden = _normalize((FIXTURES_DIR / f"{name}.expected_output.txt").read_bytes())
    result = _Comparison(name=name, golden=golden)

    try:
        program = encode(compile_program(load_program(str(fixture))))
    except Exception as ex:  # CompileError, EncodeError, RecursionError, …
        result.error = (
            f"{name} no longer survives Ball -> Python -> Ball: "
            f"{type(ex).__name__}: {ex}"
        )
        return result

    result.original = _run_on_reference_engine(dart, fixture)
    result.reencoded = _run_on_reference_engine(
        dart, _write_program(program, workdir / f"{name}.ball.json")
    )
    return result


@pytest.fixture(scope="module")
def reference_engine_runs() -> dict[str, _Comparison]:
    """Every fixture's pair of reference-engine runs, computed once.

    Concurrent because a ``dart run`` costs seconds and this suite performs two
    per fixture; the same ``ThreadPoolExecutor`` shape (and ``BALL_WORKERS``
    knob) the whole-corpus leg uses. Module-scoped so the parametrized cases
    below stay one-assertion-per-fixture without paying for the runs twice.
    """
    dart = _require_dart()
    with tempfile.TemporaryDirectory(prefix="ball_py_refengine_") as tmp:
        workdir = Path(tmp)
        with concurrent.futures.ThreadPoolExecutor(max_workers=_WORKERS) as ex:
            futures = {
                name: ex.submit(_compare, name, dart, workdir) for name in FIXTURES
            }
            return {name: fut.result() for name, fut in futures.items()}


def test_the_fixture_set_is_derived_and_not_empty() -> None:
    """A positive floor on the DERIVATION, not on a list kept here.

    An exit code and a failure count cannot tell "all passed" from "nothing
    ran": an empty ``FIXTURES`` would parametrize zero cases and read as green
    forever. Both source lists must still be non-empty and the union must be
    exactly their union.
    """
    assert len(_INVERSE_FIXTURES) >= 5, "test_ballrt_inverse's fixture list shrank"
    assert len(_NAMESPACED_FIXTURES) >= 9, "test_ballrt_namespaced's list shrank"
    assert set(FIXTURES) == set(_INVERSE_FIXTURES) | set(_NAMESPACED_FIXTURES)
    assert len(FIXTURES) >= 14, (
        f"only {len(FIXTURES)} fixtures derived — the derivation broke, it is "
        "not that the suites shrank"
    )


@pytest.mark.parametrize("name", FIXTURES)
def test_reencoded_fixture_matches_the_original_on_the_reference_engine(
    name: str, reference_engine_runs: dict[str, _Comparison]
) -> None:
    """Ball -> Python -> Ball must not change what the REFERENCE ENGINE prints.

    Three legs, in the order that names the guilty side: the original agrees
    with its golden (the corpus is intact), the re-encoded program runs cleanly,
    and the two stdouts are byte-identical.
    """
    comparison = reference_engine_runs[name]
    assert not comparison.error, comparison.error

    original = comparison.original
    reencoded = comparison.reencoded
    assert original is not None and reencoded is not None

    assert original.exit_code == 0, (
        f"the ORIGINAL fixture {name} failed on the reference engine "
        f"(exit {original.exit_code}):\n{original.stderr}"
    )
    assert original.stdout.rstrip("\n") == comparison.golden.rstrip("\n"), (
        f"the ORIGINAL fixture {name} no longer matches its own golden — the "
        "corpus or the engine moved, not the encoder"
    )
    assert reencoded.exit_code == 0, (
        f"the RE-ENCODED {name} failed on the reference engine "
        f"(exit {reencoded.exit_code}) while the original ran clean:\n"
        f"{reencoded.stderr}"
    )
    assert reencoded.stdout == original.stdout, (
        f"Ball -> Python -> Ball changed what {name} prints on the reference "
        f"engine:\n--- original ---\n{original.stdout}\n--- re-encoded ---\n"
        f"{reencoded.stdout}"
    )


# ── The negative control: what this module can see that `ballrt` cannot ───────
#
# Both programs are the compiler's own emission shape. They differ only in that
# the second reads an ABSENT key under `std.null_coalesce` — an operator the
# reference engine evaluates EAGERLY, so the read really happens. `ballrt`
# answers `None` for that read (proto3-default tolerance,
# `python/runtime/ballrt/values.py`) and the coalesce hides it; the reference
# engine fails loud. `ballrt.cvt.json_decode` is how the map is built: the
# encoder does not read a Python dict literal, and this keeps the control inside
# the shapes it really inverts.

_CONTROL_ORIGINAL = '''import ballrt

row = ballrt.cvt.json_decode("{\\"lo\\": 7}")
print(ballrt.getfield(row, "lo"))
'''

_CONTROL_DIVERGENT = '''import ballrt

row = ballrt.cvt.json_decode("{\\"lo\\": 7}")
print(ballrt.null_coalesce(ballrt.getfield(row, "hi"), ballrt.getfield(row, "lo")))
'''


def test_the_reference_engine_sees_a_divergence_ballrt_cannot(tmp_path: Path) -> None:
    """Prove the instrument, before trusting its green.

    Leg 1 is the BLIND half: under ``python/compiler`` + ``ballrt`` the two
    programs print the same thing, so no assertion made on that runtime — every
    assertion the other round-trip suites make — can tell them apart.

    Leg 2 is this module: the reference engine does tell them apart, and names
    the absent field while doing it. A comparison that passed both legs
    vacuously (both empty, both failing) would fail here.
    """
    original = encode(_CONTROL_ORIGINAL)
    divergent = encode(_CONTROL_DIVERGENT)

    # Leg 1 — the blind half.
    assert _run_source(compile_program(original)) == "7\n"
    assert _run_source(compile_program(divergent)) == "7\n", (
        "the control no longer demonstrates the blind spot: `ballrt` must give "
        "the divergent program the SAME output as the original, or this module "
        "is not proving anything the other suites already prove"
    )

    # Leg 2 — the reference engine.
    dart = _require_dart()
    original_run = _run_on_reference_engine(
        dart, _write_program(original, tmp_path / "control_original.ball.json")
    )
    divergent_run = _run_on_reference_engine(
        dart, _write_program(divergent, tmp_path / "control_divergent.ball.json")
    )

    assert original_run.exit_code == 0, (
        f"the control's ORIGINAL must run clean on the reference engine:\n"
        f"{original_run.stderr}"
    )
    assert original_run.stdout == "7\n", original_run.stdout
    assert divergent_run.exit_code != 0, (
        "the reference engine accepted a read of an absent key — the control no "
        f"longer diverges, so this module's comparison proves nothing:\n"
        f"{divergent_run.stdout}"
    )
    assert divergent_run.stdout != original_run.stdout
    assert '"hi"' in divergent_run.stderr, (
        "the reference engine failed for some other reason than the absent "
        f"field this control injects:\n{divergent_run.stderr}"
    )
