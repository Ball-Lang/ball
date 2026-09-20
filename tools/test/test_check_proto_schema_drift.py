#!/usr/bin/env python3
"""Self-test for tools/check_proto_schema_drift.py.

A gate nobody has watched FAIL is not a gate. Each case below copies the two
files the checker reads into a scratch tree, breaks exactly one thing, and
asserts the checker reports that specific defect — plus positive controls
proving the unmodified tree passes and that a schema keyword STRICTER than the
proto (a `pattern` on a string field) is not a false red. "Always red" and
"always green" are both ruled out.

Run:  python tools/test/test_check_proto_schema_drift.py
"""

from __future__ import annotations

import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parents[2]
CHECKER = REPO / "tools" / "check_proto_schema_drift.py"
PROTO_REL = "proto/ball/v1/ball.proto"
SCHEMA_REL = "ball.schema.json"

_passed = 0
_failures: list[str] = []


def _mkroot(tmp: pathlib.Path) -> pathlib.Path:
    root = tmp / "root"
    (root / "proto" / "ball" / "v1").mkdir(parents=True)
    shutil.copy2(REPO / PROTO_REL, root / PROTO_REL)
    shutil.copy2(REPO / SCHEMA_REL, root / SCHEMA_REL)
    return root


def _run(root: pathlib.Path) -> tuple[int, str]:
    proc = subprocess.run(
        [sys.executable, str(CHECKER), "--root", str(root)],
        capture_output=True, text=True, encoding="utf-8", errors="replace")
    return proc.returncode, proc.stdout + proc.stderr


def _edit(root: pathlib.Path, rel: str, old: str, new: str) -> None:
    path = root / rel
    text = path.read_text(encoding="utf-8")
    if old not in text:
        raise SystemExit(f"self-test: anchor not found in {rel}: {old!r}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def _edit_schema(root: pathlib.Path, mutate) -> None:
    path = root / SCHEMA_REL
    doc = json.loads(path.read_text(encoding="utf-8"))
    mutate(doc["$defs"])
    path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")


def case(name: str, mutate, expect_rc: int, expect_substr: str) -> None:
    global _passed
    with tempfile.TemporaryDirectory() as td:
        root = _mkroot(pathlib.Path(td))
        mutate(root)
        rc, out = _run(root)
        if rc != expect_rc:
            _failures.append(f"{name}: exit {rc}, expected {expect_rc}\n{out}")
        elif expect_substr not in out:
            _failures.append(f"{name}: output missing {expect_substr!r}\n{out}")
        else:
            _passed += 1
            print(f"  ok  {name}")


def main() -> int:
    print("check_proto_schema_drift self-test")

    # ── Positive controls ────────────────────────────────────────────────────
    case("unmodified repo passes", lambda root: None, 0,
         "ball.schema.json is in sync with ball.proto")

    def _add_pattern(root: pathlib.Path) -> None:
        def m(defs):
            defs["CallSite"]["properties"]["module"]["pattern"] = "^[a-z_]+$"
        _edit_schema(root, m)

    case("a schema keyword stricter than the proto is not drift", _add_pattern, 0,
         "ball.schema.json is in sync with ball.proto")

    # ── The #609 defect, from both directions ────────────────────────────────
    def _drop_resolved_module(root: pathlib.Path) -> None:
        def m(defs):
            del defs["CallSite"]["properties"]["resolvedModule"]
        _edit_schema(root, m)

    case("a proto field missing from the schema is drift", _drop_resolved_module, 1,
         "CallSite.resolvedModule: declared in ball.proto, missing from $defs/CallSite")

    case(
        "a NEW proto field with no schema edit is drift",
        lambda root: _edit(root, PROTO_REL,
                           "  string resolved_module = 5;",
                           "  string resolved_module = 5;\n\n  string audit_note = 6;"),
        1, "CallSite.auditNote: declared in ball.proto")

    # ── The other three shapes of drift ──────────────────────────────────────
    def _add_unknown_property(root: pathlib.Path) -> None:
        def m(defs):
            defs["CallSite"]["properties"]["legacySpelling"] = {"type": "string"}
        _edit_schema(root, m)

    case("a schema property with no proto field is drift", _add_unknown_property, 1,
         "CallSite.legacySpelling: in $defs/CallSite but not in ball.proto")

    def _retype_property(root: pathlib.Path) -> None:
        def m(defs):
            defs["CallSite"]["properties"]["calleeModule"] = {"type": "boolean"}
        _edit_schema(root, m)

    case("a property whose JSON type contradicts the proto is drift", _retype_property, 1,
         "CallSite.calleeModule: shape mismatch")

    def _drop_def(root: pathlib.Path) -> None:
        def m(defs):
            del defs["CallSite"]
        _edit_schema(root, m)

    case("a message with no $defs entry at all is drift", _drop_def, 1,
         "CallSite: message has no $defs/CallSite")

    def _break_enum(root: pathlib.Path) -> None:
        def m(defs):
            defs["ModuleEncoding"]["enum"].remove("MODULE_ENCODING_JSON")
        _edit_schema(root, m)

    case("an enum value missing from the schema is drift", _break_enum, 1,
         "ModuleEncoding: enum mismatch")

    # ── Fake-green controls: the reader must never silently read nothing ─────
    case(
        "an unreadable proto line is an error, not a skipped field",
        lambda root: _edit(root, PROTO_REL,
                           "  string resolved_module = 5;",
                           "  reserved 6 to 9;\n  string resolved_module = 5;"),
        2, "unrecognised line in message CallSite")

    def _truncate_proto(root: pathlib.Path) -> None:
        (root / PROTO_REL).write_text(
            'syntax = "proto3";\n'
            "package ball.v1;\n"
            "\n"
            "message CallSite {\n"
            "  string module = 1;\n"
            "}\n",
            encoding="utf-8",
        )

    case("reading far fewer declarations than measured is a failure, not a pass",
         _truncate_proto, 2, "measured floor")

    case("a missing schema file is an error, not a pass",
         lambda root: (root / SCHEMA_REL).unlink(), 2, "not found")

    total = _passed + len(_failures)
    print(f"\nResults: {_passed} passed, {len(_failures)} failed, {total} total")
    if total < 11:
        print(f"error: expected at least 11 self-test cases, ran {total}", file=sys.stderr)
        return 1
    if _failures:
        print("\nFAILED:", file=sys.stderr)
        for failure in _failures:
            print(f"\n--- {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
