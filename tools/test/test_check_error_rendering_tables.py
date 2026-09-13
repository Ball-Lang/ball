#!/usr/bin/env python3
"""Self-test for tools/check_error_rendering_tables.py.

A gate nobody has watched FAIL is not a gate. Each case below copies the repo
into a scratch tree, breaks exactly one thing, and asserts the checker reports
that specific defect — plus a positive control proving the unmodified tree
passes, so "always red" and "always green" are both ruled out.

Run:  python tools/test/test_check_error_rendering_tables.py
"""

from __future__ import annotations

import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parents[2]
CHECKER = REPO / "tools" / "check_error_rendering_tables.py"

# Only the trees the checker reads — copying the whole repo would be minutes.
COPY = [
    "dart/engine/lib",
    "cpp/shared/include",
    "cpp/compiler/src",
    "rust/shared/src",
    "rust/compiler/src",
    "go/runtime",
    "go/compiler",
    "csharp/shared/src",
    "csharp/compiler/src",
    "ts/compiler/src",
    "ts/engine/src",
    "python/runtime/ballrt",
]

_failures: list[str] = []


def _mkroot(tmp: pathlib.Path) -> pathlib.Path:
    root = tmp / "root"
    for rel in COPY:
        src = REPO / rel
        if not src.is_dir():
            raise SystemExit(f"self-test: expected directory {rel} to exist")
        dst = root / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(src, dst)
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
    print("check_error_rendering_tables self-test")

    # ── Positive control ─────────────────────────────────────────────────────
    case("unmodified repo passes", lambda root: None, 0,
         "every raised Dart error name has a rendering entry")

    # ── Coverage: a raised name with no table entry (the #641 defect) ────────
    case(
        "csharp table missing a raised name",
        lambda root: _edit(root, "csharp/shared/src/BallValue.cs",
                           '"TypeError" => "",', ""),
        1, "csharp: raises ['TypeError'] but")
    case(
        "go table missing a raised name",
        lambda root: _edit(root, "go/runtime/ops.go",
                           'case "TypeError":', 'case "NotAnErrorName":'),
        1, "go: raises ['TypeError'] but")
    case(
        "ts table missing a raised name",
        lambda root: _edit(root, "ts/compiler/src/preamble.ts",
                           "TypeError: '',", ""),
        1, "ts: raises ['TypeError'] but")
    case(
        "rust table missing a raised name",
        lambda root: _edit(root, "rust/shared/src/value.rs",
                           '"TypeError" => "",', ""),
        1, "rust: raises ['TypeError'] but")

    # ── Agreement: an entry whose prefix disagrees with Dart ─────────────────
    case(
        "rust renders TypeError with a prefix Dart does not spell",
        lambda root: _edit(root, "rust/shared/src/value.rs",
                           '"TypeError" => "",', '"TypeError" => "TypeError",'),
        1, "renders 'TypeError' with prefix 'TypeError'")
    case(
        "go renders StateError with the wrong prefix",
        lambda root: _edit(root, "go/runtime/ops.go",
                           'prefix = "Bad state"', 'prefix = "StateError"'),
        1, "Dart spells 'Bad state'")

    # ── Closure: a brand-new raised name the contract has never heard of ─────
    case(
        "a new raised name fails until the contract learns it",
        lambda root: _edit(root, "rust/shared/src/runtime.rs",
                           'ball_throw_typed("StateError"',
                           'ball_throw_typed("BananaError"'),
        1, "which the cross-target contract does not know")

    # ── Floors: a silently-broken extractor must FAIL, not pass vacuously ────
    def _blank_rust_raises(root: pathlib.Path) -> None:
        path = root / "rust/shared/src/runtime.rs"
        path.write_text(
            re.sub(r"ball_throw_typed\(", "ball_throw_renamed(",
                   path.read_text(encoding="utf-8")),
            encoding="utf-8")
        path2 = root / "rust/shared/src/value.rs"
        path2.write_text(
            re.sub(r"ball_throw_typed\(", "ball_throw_renamed(",
                   path2.read_text(encoding="utf-8")),
            encoding="utf-8")

    case("no raise sites found is a failure, not a pass", _blank_rust_raises, 1,
         "raise-site extractor stopped matching")

    def _break_table_shape(root: pathlib.Path) -> None:
        # Re-quote every entry so the extractor's `name: 'prefix',` pattern
        # matches nothing. The table is still THERE and still correct — this is
        # the "my regex quietly stopped seeing it" failure mode, which must be a
        # red, not a silent 0-entry pass.
        path = root / "ts/compiler/src/preamble.ts"
        text = path.read_text(encoding="utf-8")
        for name, prefix in (("StateError", "Bad state"),
                             ("FormatException", "FormatException"),
                             ("RangeError", "RangeError"),
                             ("TypeError", "")):
            old = f"      {name}: '{prefix}',"
            if old not in text:
                raise SystemExit(f"self-test: table entry not found: {old!r}")
            text = text.replace(old, f'      {name}: "{prefix}",', 1)
        path.write_text(text, encoding="utf-8")

    case("an unparseable table is a failure, not a pass", _break_table_shape, 1,
         "table extractor stopped matching")

    if _failures:
        print("\nFAILED:", file=sys.stderr)
        for f in _failures:
            print(f"\n--- {f}", file=sys.stderr)
        return 1
    print("all self-test cases passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
