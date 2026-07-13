"""Top-level dispatch: usage, help, unknown command, exit-code contract."""

from __future__ import annotations

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
