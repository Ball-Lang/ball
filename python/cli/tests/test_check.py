"""`ball check`: structural validation + the opt-in --compile dry run."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from conftest import fixture, run_cli

# ── Command-level behaviour ──────────────────────────────────────────────────


def test_check_valid_program_prints_summary_exit_0():
    out, err, code = run_cli("check", fixture("examples", "hello_world", "hello_world.ball.json"))
    assert code == 0, err
    assert 'Valid: "hello_world"' in out
    assert "module(s)" in out and "function(s)" in out


@pytest.mark.parametrize("name", [
    "100_complex_control_flow", "101_simple_class", "103_abstract_class", "112_named_constructors",
])
def test_check_accepts_representative_valid_fixtures(name: str):
    # Includes OOP fixtures whose constructors/abstract methods have metadata but
    # no body — the rule must not reject those.
    _, err, code = run_cli("check", fixture("tests", "conformance", f"{name}.ball.json"))
    assert code == 0, err


def test_check_rejects_structurally_invalid_exit_2(tmp_path: Path):
    bad = tmp_path / "broken.ball.json"
    bad.write_text(json.dumps({
        "@type": "type.googleapis.com/ball.v1.Program",
        "name": "broken", "version": "1.0.0",
        "modules": [{}],  # no entry point, one unnamed module
    }), encoding="utf-8")
    _, err, code = run_cli("check", str(bad))
    assert code == 2
    assert "invalid program" in err
    assert "missing entry_module" in err
    assert "missing entry_function" in err
    assert "has no name" in err


def test_check_missing_file_is_io_error_exit_3():
    _, err, code = run_cli("check", "no_such.ball.json")
    assert code == 3
    assert "could not read" in err


def test_check_compile_flag_catches_uncompilable(tmp_path: Path):
    # Structurally sound (a body is present) but calls an unknown base fn: passes
    # the structural checks, fails the --compile dry run.
    prog = tmp_path / "uncompilable.ball.json"
    prog.write_text(json.dumps({
        "@type": "type.googleapis.com/ball.v1.Program",
        "name": "uncompilable", "version": "1.0.0",
        "entryModule": "main", "entryFunction": "main",
        "modules": [
            {"name": "std", "functions": [{"name": "definitely_not_a_base_fn", "isBase": True}]},
            {"name": "main", "functions": [{"name": "main", "body": {
                "call": {"module": "std", "function": "definitely_not_a_base_fn"}}}]},
        ],
    }), encoding="utf-8")

    _, _, code = run_cli("check", str(prog))
    assert code == 0  # structural checks pass without --compile
    _, err, code = run_cli("check", "--compile", str(prog))
    assert code == 2
    assert "does not compile to Python" in err


# ── validate_structure unit coverage (each rule) ─────────────────────────────


def _well_formed() -> dict:
    return {
        "name": "t", "version": "1.0.0",
        "entryModule": "main", "entryFunction": "main",
        "modules": [{"name": "main", "functions": [{"name": "main", "body": {"block": {}}}]}],
    }


def test_validate_structure_accepts_well_formed():
    from ball_cli.commands.check import validate_structure

    assert validate_structure(_well_formed()) == []


def test_validate_structure_flags_each_rule():
    from ball_cli.commands.check import validate_structure

    missing_entry = _well_formed()
    missing_entry["entryModule"] = ""
    assert any("missing entry_module" in p for p in validate_structure(missing_entry))

    bad_entry_fn = _well_formed()
    bad_entry_fn["entryFunction"] = "ghost"
    assert any("entry function" in p for p in validate_structure(bad_entry_fn))

    bad_entry_mod = _well_formed()
    bad_entry_mod["entryModule"] = "ghost"
    assert any("entry module" in p for p in validate_structure(bad_entry_mod))

    dup = _well_formed()
    dup["modules"].append(dup["modules"][0])
    assert any("duplicate module name" in p for p in validate_structure(dup))

    unnamed = _well_formed()
    unnamed["modules"][0]["name"] = ""
    assert any("has no name" in p for p in validate_structure(unnamed))

    bodiless = _well_formed()
    del bodiless["modules"][0]["functions"][0]["body"]
    assert any("no body or metadata" in p for p in validate_structure(bodiless))


def test_validate_structure_allows_metadata_only_function():
    """A non-base function with metadata but no body (a constructor) is valid."""
    from ball_cli.commands.check import validate_structure

    prog = _well_formed()
    ctor = {"name": "Point.new", "metadata": {"kind": "constructor"}}
    prog["modules"][0]["functions"].append(ctor)
    assert validate_structure(prog) == []


def test_validate_structure_allows_base_function_without_body():
    from ball_cli.commands.check import validate_structure

    prog = _well_formed()
    prog["modules"].append({"name": "std", "functions": [{"name": "add", "isBase": True}]})
    assert validate_structure(prog) == []
