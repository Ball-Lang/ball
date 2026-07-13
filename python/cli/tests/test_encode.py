"""`ball encode`: Python -> Ball, validating the emitted .ball.json shape."""

from __future__ import annotations

import json
from pathlib import Path

from conftest import run_cli, run_python_source


def _write_py(tmp_path: Path, body: str) -> Path:
    p = tmp_path / "src.py"
    p.write_text(body, encoding="utf-8")
    return p


def test_encode_emits_type_enveloped_program(tmp_path: Path):
    src = _write_py(tmp_path, 'def main():\n    print("hi from encode")\n')
    out, err, code = run_cli("encode", str(src))
    assert code == 0, err
    program = json.loads(out)
    # A drop-in .ball.json: the Any @type envelope + a Program with a std module.
    assert program["@type"] == "type.googleapis.com/ball.v1.Program"
    assert program["name"]
    assert program["version"]
    module_names = {m["name"] for m in program["modules"]}
    assert "std" in module_names  # universal std, never a python_std


def test_encode_output_flag_writes_file(tmp_path: Path):
    src = _write_py(tmp_path, 'def main():\n    print("x")\n')
    dest = tmp_path / "out.ball.json"
    out, err, code = run_cli("encode", str(src), "-o", str(dest))
    assert code == 0, err
    assert out == ""
    assert json.loads(dest.read_text(encoding="utf-8"))["@type"].endswith("ball.v1.Program")


def test_encode_then_compile_then_run_round_trip(tmp_path: Path):
    """The CLAUDE.md bar: native behaviour == encode -> compile -> run."""
    src = _write_py(tmp_path, 'def main():\n    print("round trip works")\n')
    enc = tmp_path / "prog.ball.json"
    _, err, code = run_cli("encode", str(src), "-o", str(enc))
    assert code == 0, err
    compiled_out, err, code = run_cli("compile", str(enc))
    assert code == 0, err
    assert run_python_source(compiled_out).strip() == "round trip works"


def test_encode_missing_file_is_io_error_exit_3():
    _, err, code = run_cli("encode", "no_such_source.py")
    assert code == 3
    assert "could not read" in err


def test_encode_invalid_python_fails_loud_exit_2(tmp_path: Path):
    src = _write_py(tmp_path, "def f(:\n")  # a syntax error
    _, err, code = run_cli("encode", str(src))
    assert code == 2
    assert "encode:" in err
