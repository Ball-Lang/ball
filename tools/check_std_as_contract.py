#!/usr/bin/env python3
"""Close `std.as`'s cross-target behavioral contract (issue #707).

`value as T` — the EXPRESSION, as opposed to the cast PATTERN
`tools/check_error_rendering_tables.py` already closes a table for (issue
#641) — is an UNCHECKED IDENTITY on this repo's canonical contract: every
reference implementation hands the value back unchanged, never inspecting
`type_name` at all. The Dart reference engine's own dispatch
(`dart/engine/lib/engine_std.dart`) registers `'as'` to the same
argument-returning `_extractUnaryArg` helper `spread`/`null_spread`/`await`/
`paren` share, and Python's `ballrt.selfhost.as_type`, Go's
`ballrt.AsType`, C#'s `BallStd.AsType`, TypeScript's compiler `"as"` case and
C++'s compiler `"as"` dispatch all do the same: return the operand, full
stop.

Rust's compiled `ball_as` used to PANIC on a mismatch instead, which no
sibling target does at all — every one of them just returns the value,
unconditionally, with no exception of any kind. The panic was *catchable* by
an enclosing Ball `try` (Rust's `catch_unwind` recovers any panic, typed or
not) but only as an untyped payload, never a typed `TypeError`; with no
enclosing `try` — the ordinary case, since every sibling target needs
none — it unwound straight out of the compiled `fn main()` and crashed the
whole process, on Rust alone, while a Ball program doing the identical cast
was silently accepted everywhere else. That is a real cross-target
behavioral divergence (a "wrong answer" class, not cosmetic), and this script
is the sibling CLOSED-SET check #641 asked for: for every target it extracts
the source that implements `std.as` and asserts it contains none of a
FORBIDDEN set of throw/panic/raise tokens — the plain, structural proof that
the value flows through unchanged on every path, whatever the runtime type.

Conformance fixture `481_as_expression_identity` is one OBSERVABLE half,
running on every engine/compiler in the matrix, but it wraps the cast in a
`try`/`catch` (real Dart's own `as` is a checked cast, so the golden needs
one) whose `catch` arm prints the SAME text the `try` arm would have on
success — so it cannot by itself tell a panic `catch_unwind` recovered apart
from the fix, only the value identity once caught by either means. The
Rust-only `rust/compiler/tests/as_expression_identity.rs`'s
`as_on_a_mismatched_type_never_panics_with_no_enclosing_try` is the other
observable half, built with no `try` anywhere so a pre-fix panic has nothing
to catch; this script is the structural one, the same division
`check_error_rendering_tables.py` draws for the cast PATTERN's rendering
tables.

Usage:
    python tools/check_std_as_contract.py [--root <repo root>] [--quiet]
"""

from __future__ import annotations

import argparse
import pathlib
import sys

# Any one of these found inside an `as`-implementation's body means SOME path
# can abort/throw instead of returning the value as-is — the exact defect
# issue #707 closed for Rust.
FORBIDDEN_TOKENS: tuple[str, ...] = (
    "panic!", "panic(", "throw ", "throw(", "raise ", ".Panic", "Panic(",
    "ball_throw", "BallThrow", "dartError", "BallRuntimeError",
)

# A target must be found for the check to mean anything; a floor (not an
# equality) so a dropped extractor fails loud instead of passing vacuously.
MIN_TARGETS = 6


def _read(root: pathlib.Path, rel: str) -> str:
    path = root / rel
    if not path.is_file():
        raise SystemExit(f"check_std_as_contract: missing source file {rel}")
    return path.read_text(encoding="utf-8")


def _slice(text: str, start: str, end: str, what: str) -> str:
    """The slice of `text` from `start` to the next `end` after it (inclusive
    of `start`, exclusive of `end`) — the function/dispatch-arm body."""
    i = text.find(start)
    if i < 0:
        raise SystemExit(
            f"check_std_as_contract: could not locate {what} "
            f"(start marker {start!r} not found)")
    j = text.find(end, i + len(start))
    if j < 0:
        raise SystemExit(f"check_std_as_contract: unterminated {what}")
    return text[i:j]


def collect(root: pathlib.Path) -> dict[str, str]:
    """target name -> the source slice implementing `std.as`'s identity."""
    bodies: dict[str, str] = {}

    # ── Rust: ball_as (issue #707's own fix — the ONE target this script
    # exists to keep honest) ──
    bodies["rust"] = _slice(
        _read(root, "rust/shared/src/runtime.rs"),
        "pub fn ball_as(", "\n}\n", "rust ball_as")

    # ── Go: AsType ──
    bodies["go"] = _slice(
        _read(root, "go/runtime/dispatch.go"),
        "func AsType(", "\n", "go AsType")

    # ── Python: as_type ──
    bodies["python"] = _slice(
        _read(root, "python/runtime/ballrt/selfhost.py"),
        "def as_type(", "\n\n", "python as_type")

    # ── C#: BallStd.AsType ──
    bodies["csharp"] = _slice(
        _read(root, "csharp/shared/src/BallStd.cs"),
        "public static BallValue AsType(", "\n", "csharp AsType")

    # ── TypeScript: the compiler's "as" dispatch case — `as` never reaches a
    # RUNTIME helper on this target at all; it is a compile-time identity
    # (the expression compiles straight through to its operand). ──
    bodies["ts"] = _slice(
        _read(root, "ts/compiler/src/compiler.ts"),
        'case "as":', "\n", 'ts "as" case')

    # ── C++: the compiler's "as" dispatch (the same compile-time identity
    # shape as TypeScript). ──
    bodies["cpp"] = _slice(
        _read(root, "cpp/compiler/src/compiler.cpp"),
        'if (fn == "as")', "\n", 'cpp "as" dispatch')

    # ── Dart (the reference engine): `'as'` is registered to
    # `_extractUnaryArg`, the SAME shared, argument-returning helper
    # `spread`/`null_spread`/`await`/`paren` use — asserted by the
    # REGISTRATION LINE, not by re-reading `_extractUnaryArg`'s own body:
    # as long as `'as'` names that one shared helper, it answers the operand
    # and nothing else, so the registration line IS the contract.
    dart_std = _read(root, "dart/engine/lib/engine_std.dart")
    if "'as': _extractUnaryArg" not in dart_std:
        raise SystemExit(
            "check_std_as_contract: dart/engine/lib/engine_std.dart no "
            "longer registers 'as' to _extractUnaryArg — update this "
            "checker's Dart extractor to match the new dispatch")
    bodies["dart"] = "'as': _extractUnaryArg"

    return bodies


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=".", help="repo root (default: cwd)")
    ap.add_argument("--quiet", action="store_true", help="only print on failure")
    args = ap.parse_args(argv)

    root = pathlib.Path(args.root).resolve()
    bodies = collect(root)
    failures: list[str] = []
    lines: list[str] = []

    if len(bodies) < MIN_TARGETS:
        failures.append(
            f"collected {len(bodies)} targets, floor is {MIN_TARGETS} — an "
            "extractor was dropped")

    for name, body in sorted(bodies.items()):
        hit = next((tok for tok in FORBIDDEN_TOKENS if tok in body), None)
        lines.append(
            f"  {name:<7} "
            + (f"FORBIDDEN TOKEN {hit!r}" if hit else "identity, no throw/panic"))
        if hit:
            failures.append(
                f"{name}: std.as's implementation contains {hit!r} — every "
                "target's `value as T` must be an UNCHECKED IDENTITY (issue "
                "#707); a throw/panic here is the exact cross-target "
                "divergence that issue closed")

    if failures or not args.quiet:
        print("std.as cross-target contract (UNCHECKED IDENTITY, issue #707):")
        print("\n".join(lines))

    if failures:
        print("\nFAIL:", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        return 1

    print("OK: every target's std.as is an unchecked identity, matching the "
          "Dart reference engine.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
