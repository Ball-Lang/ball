"""Top-level dispatch: usage, help, unknown command, exit-code contract."""

from __future__ import annotations

import re

from conftest import run_cli


def test_no_args_prints_usage_and_exits_2():
    out, err, code = run_cli()
    assert code == 2
    assert out == ""
    assert "Usage:" in err
    assert "run" in err and "compile" in err and "encode" in err and "check" in err


def test_help_prints_usage_to_stdout_and_exits_0():
    for flag in ("-h", "--help", "help"):
        out, err, code = run_cli(flag)
        assert code == 0, flag
        assert "Usage:" in out
        assert err == ""


def test_version_flag_prints_a_version_and_exits_0():
    # `--version` is a flag, not a `version` verb: in the sibling CLIs
    # `ball version <program>` is the self-hosted cli-core report about a Ball
    # PROGRAM, and porting those verbs here is still a follow-up (#496).
    for flag in ("--version", "-V"):
        out, err, code = run_cli(flag)
        assert code == 0, flag
        assert err == ""
        assert out.startswith("ball "), out
        assert "Python toolchain" in out
        # A version is reported either way: the installed distribution's, or the
        # explicit source-checkout marker — never an empty or missing field.
        assert re.search(r"ball \d+\.\d+\.\d+", out), out


def test_version_matches_the_installed_distribution_when_installed():
    import ball_cli

    installed = ball_cli._installed_version()
    out, _, code = run_cli("--version")
    assert code == 0
    if installed is None:
        assert ball_cli.SOURCE_VERSION in out
        assert "source checkout" in out
    else:
        assert installed in out


def test_unknown_command_exits_2_with_message():
    out, err, code = run_cli("frobnicate")
    assert code == 2
    assert "unknown command 'frobnicate'" in err
    assert "Usage:" in err  # usage follows the error


def test_exit_code_contract_documented_in_usage():
    out, _, _ = run_cli("--help")
    assert "0 success" in out
    assert "1 runtime error" in out
    assert "2 invalid program / usage" in out
    assert "3 I/O error" in out


def test_verb_help_exits_0():
    # Each verb's own -h routes through argparse's StreamParser -> HelpRequested.
    for verb in ("run", "compile", "encode", "check"):
        out, err, code = run_cli(verb, "-h")
        assert code == 0, verb
        assert verb in out
        assert err == ""


def test_missing_positional_is_usage_error_exit_2():
    for verb in ("run", "compile", "encode", "check"):
        _, err, code = run_cli(verb)
        assert code == 2, verb
        assert f"ball {verb}" in err  # argparse prog name in the diagnostic
