"""The ``ball info``/``validate``/``tree``/``version`` golden-parity gate (#570).

The Python sibling of ``go/cli/cli_core_parity_test.go``,
``rust/cli/tests/cli_core_parity.rs`` and
``dart/cli/test/cli_core_parity_test.dart``.

The reports are not computed by Python code: they come from
``dart/shared/lib/cli_core.dart`` compiled through the Ball → Python compiler
(``python -m ball_cli.regen``, or the wheel's compile-on-first-use bootstrap), so
this gate proves the compiled functions produce BYTE-IDENTICAL text to the
reference Dart CLI. The goldens live once, at ``tests/cli_core_goldens/``, and are
shared with the Go gate — see that directory's README.md.

Everything runs in-process through :func:`ball_cli.run` (``conftest.run_cli``),
so stdout is a ``StringIO``: no console newline translation, and the byte
comparison is exact on every platform.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import pytest
from conftest import ROOT, cli_core_available, run_cli

# A fresh checkout has neither the generated ball_cli/compiled_cli.py nor any
# Ball source to compile, so these comparisons have nothing to run — exactly the
# state ci.yml's pre-regen "CLI tests" step is in, where the point is to exercise
# the CLI's honest-failure paths (test_cli_core_bootstrap.py). Skip there rather
# than fail; BALL_REQUIRE_CLI_CORE=1 (set by the post-regen parity step) turns
# the skip back into a failure, so the regen step silently not running cannot
# reduce this gate to a no-op — the mechanism python/engine's
# BALL_REQUIRE_SELFHOST_SOURCE already uses.
if not cli_core_available():
    if os.environ.get("BALL_REQUIRE_CLI_CORE"):
        raise RuntimeError(
            "BALL_REQUIRE_CLI_CORE is set but no CLI core is available: neither "
            "python/cli/ball_cli/compiled_cli.py nor a Ball source "
            "(dart/self_host/cli.ball.json / ball_cli/_clicore/*.gz) exists.\n"
            "Run: cd dart && dart run compiler/tool/gen_cli_json.dart"
            " && cd ../python/cli && python -m ball_cli.regen"
        )
    pytest.skip(
        "no self-hosted CLI core available (run `python -m ball_cli.regen`)",
        allow_module_level=True,
    )

#: The same varied slice every other target's parity gate uses.
GOLDEN_FIXTURES = (
    "100_complex_control_flow",
    "101_simple_class",
    "111_cascade_operator",
    "116_map_iteration",
    "118_set_operations",
)

#: `version` takes no program and is asserted directly against the compiled
#: function below, exactly as the Rust and Dart gates do.
GOLDEN_VERBS = ("info", "validate", "tree")

GOLDEN_DIR = ROOT / "tests" / "cli_core_goldens"


def _golden(fixture: str, verb: str) -> str:
    """Read a golden as BYTES and decode — never text mode, which would collapse
    a semantic lone ``\\r`` (see .claude/rules/python.md)."""
    path = GOLDEN_DIR / f"{fixture}.{verb}.txt"
    raw = path.read_bytes()
    assert raw, f"golden {path} is empty — the comparison would be vacuous"
    assert b"\r" not in raw, (
        f"golden {path} contains a CR; .gitattributes pins tests/cli_core_goldens/*.txt "
        "to eol=lf — re-checkout or regenerate it"
    )
    return raw.decode("utf-8")


@pytest.mark.parametrize("fixture", GOLDEN_FIXTURES)
@pytest.mark.parametrize("verb", GOLDEN_VERBS)
def test_cli_core_verb_matches_dart_golden(fixture: str, verb: str) -> None:
    program = str(ROOT / "tests" / "conformance" / f"{fixture}.ball.json")
    stdout, stderr, code = run_cli(verb, program)
    assert code == 0, f"{verb} {fixture} exit={code} stderr={stderr!r}"
    assert stdout == _golden(fixture, verb), f"{verb} diverged from the Dart CLI on {fixture}"


def test_every_golden_is_present_and_non_empty() -> None:
    """Positive floor: the parametrised cases above can only prove something if
    the golden set actually exists at the expected size."""
    found = sorted(p.name for p in GOLDEN_DIR.glob("*.txt"))
    expected = sorted(f"{f}.{v}.txt" for f in GOLDEN_FIXTURES for v in GOLDEN_VERBS)
    assert found == expected, f"golden set drifted: {found!r} != {expected!r}"
    assert len(found) >= 1


def test_version_verb_prints_the_portable_cli_core_line() -> None:
    """``ball version`` prints ``ball <version>`` — cli_core.versionLine's whole
    logic, asserted against the compiled function rather than a golden file
    (mirroring the Rust and Dart gates)."""
    from ball_cli import __version__
    from ball_cli.cli_core import reports

    stdout, stderr, code = run_cli("version")
    assert code == 0, stderr
    assert stdout == f"ball {__version__}\n"

    checked = 0
    for v in ("0.1.0", "1.0.0", "0.3.0+6"):
        assert reports().versionLine(v) == f"ball {v}"
        checked += 1
    assert checked >= 1


def test_version_flag_and_version_verb_are_different_and_both_work() -> None:
    """``--version`` is this toolchain's banner; ``version`` is the portable
    line. Both exist on purpose (as they do for Rust's clap) — a regression that
    collapsed one into the other would silently change published behavior."""
    flag_out, _, flag_code = run_cli("--version")
    verb_out, _, verb_code = run_cli("version")
    assert flag_code == 0 and verb_code == 0
    assert "Python toolchain" in flag_out
    assert "Python toolchain" not in verb_out
    assert verb_out.startswith("ball ")


def test_version_verb_rejects_a_positional_argument() -> None:
    _, _, code = run_cli("version", "some-program.ball.json")
    assert code == 2


def test_validate_reports_an_invalid_program_and_exits_2(tmp_path: Path) -> None:
    """cli_core's own ``Invalid: N error(s) found`` report, on stderr, exit 2 —
    the CLI's invalid-program code (see commands/validate.py for why it is not
    Dart's generic 1)."""
    path = tmp_path / "invalid.ball.json"
    path.write_text(
        json.dumps(
            {
                "@type": "type.googleapis.com/ball.v1.Program",
                "name": "bad",
                "version": "1.0.0",
                "entryModule": "",
                "entryFunction": "",
                "modules": [],
            }
        ),
        encoding="utf-8",
    )

    stdout, stderr, code = run_cli("validate", str(path))
    assert code == 2, stderr
    assert stdout == ""
    for want in ("Invalid: 2 error(s) found", "Missing entry_module", "Missing entry_function"):
        assert want in stderr


@pytest.mark.parametrize("verb", GOLDEN_VERBS)
def test_load_failures_are_reported_before_the_cli_core(verb: str, tmp_path: Path) -> None:
    """A missing file is still an I/O error (3) and a malformed program a parse
    error (2) — the cli-core resolution must not mask either."""
    missing = tmp_path / "absent.ball.json"
    _, _, code = run_cli(verb, str(missing))
    assert code == 3

    bad = tmp_path / "not-json.ball.json"
    bad.write_text("{not json", encoding="utf-8")
    _, _, code = run_cli(verb, str(bad))
    assert code == 2


def test_usage_lists_every_portable_verb() -> None:
    """The local half of the cross-CLI verb-set parity gate
    (tools/check_cli_verb_parity.py), which scrapes exactly this text."""
    stdout, _, code = run_cli("--help")
    assert code == 0
    for verb in ("run", "compile", "encode", "check", "info", "validate", "tree", "version"):
        assert f"\n  {verb}" in stdout, f"usage does not list {verb!r}:\n{stdout}"
