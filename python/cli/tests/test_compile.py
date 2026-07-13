"""`ball compile`: Ball -> Python, proven by running the emitted module."""

from __future__ import annotations

from pathlib import Path

from conftest import fixture, run_cli, run_python_source


def test_compile_hello_world_to_stdout_then_run():
    out, err, code = run_cli("compile", fixture("examples", "hello_world", "hello_world.ball.json"))
    assert code == 0, err
    assert "import ballrt" in out
    # The emitted source actually runs and prints the greeting.
    assert run_python_source(out).strip() == "Hello, World!"


def test_compile_output_flag_writes_file(tmp_path: Path):
    dest = tmp_path / "out.py"
    out, err, code = run_cli(
        "compile", fixture("examples", "hello_world", "hello_world.ball.json"), "-o", str(dest))
    assert code == 0, err
    assert out == ""  # nothing on stdout when -o is given
    source = dest.read_text(encoding="utf-8")
    assert run_python_source(source).strip() == "Hello, World!"


def test_compile_flags_interspersed_with_positional(tmp_path: Path):
    # `-o out input` and `input -o out` must both parse (argparse handles it).
    dest = tmp_path / "out.py"
    _, err, code = run_cli(
        "compile", "-o", str(dest), fixture("examples", "hello_world", "hello_world.ball.json"))
    assert code == 0, err
    assert dest.exists()


def test_compile_missing_file_is_io_error_exit_3():
    _, err, code = run_cli("compile", "does_not_exist.ball.json")
    assert code == 3
    assert "could not read" in err


def test_compile_bad_json_is_invalid_exit_2(tmp_path: Path):
    bad = tmp_path / "bad.ball.json"
    bad.write_text("{ not json", encoding="utf-8")
    _, err, code = run_cli("compile", str(bad))
    assert code == 2
    assert "not valid JSON" in err


def test_compile_unsupported_base_fn_fails_loud_exit_2(tmp_path: Path):
    prog = _program_with_unknown_base()
    p = tmp_path / "uncompilable.ball.json"
    p.write_text(prog, encoding="utf-8")
    _, err, code = run_cli("compile", str(p))
    assert code == 2
    assert "compile:" in err


def _program_with_unknown_base() -> str:
    import json

    return json.dumps({
        "@type": "type.googleapis.com/ball.v1.Program",
        "name": "uncompilable", "version": "1.0.0",
        "entryModule": "main", "entryFunction": "main",
        "modules": [
            {"name": "std", "functions": [{"name": "definitely_not_a_base_fn", "isBase": True}]},
            {"name": "main", "functions": [{"name": "main", "body": {
                "call": {"module": "std", "function": "definitely_not_a_base_fn"}}}]},
        ],
    })
