#!/usr/bin/env python3
"""Self-test for tools/check_std_as_contract.py.

A gate nobody has watched FAIL is not a gate. Each case below copies the repo
into a scratch tree, breaks exactly one thing (re-introducing the #707
defect, one target at a time), and asserts the checker reports it — plus a
positive control proving the unmodified tree passes, so "always red" and
"always green" are both ruled out.

Run:  python tools/test/test_check_std_as_contract.py
"""

from __future__ import annotations

import pathlib
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parents[2]
CHECKER = REPO / "tools" / "check_std_as_contract.py"

# Only the files/trees the checker reads.
COPY_FILES = [
    "dart/engine/lib/engine_std.dart",
    "cpp/compiler/src/compiler.cpp",
    "rust/shared/src/runtime.rs",
    "go/runtime/dispatch.go",
    "csharp/shared/src/BallStd.cs",
    "ts/compiler/src/compiler.ts",
    "python/runtime/ballrt/selfhost.py",
]

_failures: list[str] = []


def _mkroot(tmp: pathlib.Path) -> pathlib.Path:
    root = tmp / "root"
    for rel in COPY_FILES:
        src = REPO / rel
        if not src.is_file():
            raise SystemExit(f"self-test: expected file {rel} to exist")
        dst = root / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
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


def case(name: str, mutate, expect_rc: int, expect_substr: str) -> None:
    with tempfile.TemporaryDirectory() as td:
        root = _mkroot(pathlib.Path(td))
        mutate(root)
        rc, out = _run(root)
        if rc != expect_rc:
            _failures.append(f"{name}: exit {rc}, expected {expect_rc}\n{out}")
        elif expect_substr not in out:
            _failures.append(f"{name}: output missing {expect_substr!r}\n{out}")
        else:
            print(f"  ok  {name}")


def main() -> int:
    print("check_std_as_contract self-test")

    # ── Positive control ─────────────────────────────────────────────────────
    case("unmodified repo passes", lambda root: None, 0,
         "every target's std.as is an unchecked identity")

    # ── Negative controls: re-introduce issue #707's exact defect, one target
    # at a time, and confirm each is caught by name. ──────────────────────────
    case(
        "rust ball_as panics on a mismatch (the #707 defect itself)",
        lambda root: _edit(
            root, "rust/shared/src/runtime.rs",
            "pub fn ball_as(value: BallValue, _type_name: &str) -> BallValue {\n    value\n}",
            "pub fn ball_as(value: BallValue, _type_name: &str) -> BallValue {\n"
            "    panic!(\"mismatch\")\n}"),
        1, "rust: std.as's implementation contains 'panic!'")
    case(
        "go AsType throws on a mismatch",
        lambda root: _edit(
            root, "go/runtime/dispatch.go",
            "func AsType(v Value, typeName string) Value { return v }",
            'func AsType(v Value, typeName string) Value { panic("mismatch") }'),
        1, "go: std.as's implementation contains 'panic('")
    case(
        "python as_type raises on a mismatch",
        lambda root: _edit(
            root, "python/runtime/ballrt/selfhost.py",
            "    return value\n\n\n# ── Proto oneof",
            "    raise ValueError('mismatch')\n\n\n# ── Proto oneof"),
        1, "python: std.as's implementation contains 'raise '")
    case(
        "csharp AsType throws on a mismatch",
        lambda root: _edit(
            root, "csharp/shared/src/BallStd.cs",
            "public static BallValue AsType(BallValue value, string typeName) => value;",
            'public static BallValue AsType(BallValue value, string typeName) => '
            'throw new Exception("mismatch");'),
        1, "csharp: std.as's implementation contains 'throw '")

    # ── Dart extractor: the registration line itself IS the contract, so
    # renaming the dispatch target (even to something else entirely benign)
    # must be caught — a silent "found nothing" would pass vacuously. ───────
    case(
        "dart 'as' no longer registered to _extractUnaryArg",
        lambda root: _edit(
            root, "dart/engine/lib/engine_std.dart",
            "'as': _extractUnaryArg,", "'as': _stdAsChecked,"),
        1, "no longer registers 'as' to _extractUnaryArg")

    if _failures:
        print("\nFAILED:", file=sys.stderr)
        for f in _failures:
            print(f"\n--- {f}", file=sys.stderr)
        return 1
    print("all self-test cases passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
