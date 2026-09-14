#!/usr/bin/env python3
"""Close the per-target Dart-error rendering tables (issue #641).

Every Ball runtime can raise a handful of *Dart built-in* error values — the
ones a Ball program's own ``on StateError catch`` / ``on TypeError catch``
clause is allowed to name. Each target then has to answer ONE question when the
program prints that caught value: what string does it read?

Four of the targets answer it from an explicit ``name -> prefix`` table
(``dart_error_to_string`` / ``dartErrorToString`` / ``DartErrorToString`` /
``__ball_err_prefix``). Those tables are only correct if they are CLOSED over
the names that target actually raises — and #616 left them open: every runtime
raised ``TypeError`` for a failed cast, and C#/Go/TS had no entry for it while
Rust had one with the WRONG rendering. The result was four different strings for
one program, and nothing in the repo could see it, because "the table is closed"
was prose in a doc comment rather than a test.

This script is that test. For every target it extracts

* **RAISED** — the Dart error names that target's runtime/compiler raise as a
  *Ball* throw (the value a compiled ``try`` can catch), and
* **RENDERED** — the names its rendering table covers, with the prefix each
  entry spells,

and then asserts four things:

1. **Closure** — ``RAISED ⊆ CANONICAL``. A runtime may not raise a Dart error
   name the cross-target contract has never heard of; adding one forces the
   contract (and every table) to learn it.
2. **Coverage** — ``RAISED ⊆ RENDERED`` per target. This is the assertion #641
   is about: C# raised ``TypeError`` and rendered it as the raw map form.
3. **Agreement** — every table entry's prefix equals the canonical one. A table
   may be a superset (C# renders ``RangeError`` without raising it), but it may
   never disagree.
4. **Literal-throw coverage** (#658) — ``LITERAL_THROWABLE ⊆ RENDERED`` per
   target. A runtime raise site is not the only way one of these values reaches
   a ``catch``: a user program's own ``throw StateError('boom')`` produces the
   same value from the COMPILER side, where nothing is "raised" for check 2 to
   see. That blind spot is how ``ArgumentError`` — a name Dart spells
   ``Invalid argument(s): …``, unlike all three of its siblings — sat in no
   target's table at all while every check above stayed green.

The OTHER half of #658 — that the ctor argument of such a throw reaches the
table under the key it reads (``message``, not the encoder's positional
``arg0``) — is deliberately NOT checked here. Each target already solves it in a
different, correct place (C++ renames in its compiler's throw lowering, Go and
the Dart engine alias it in ``std.throw`` itself), so a source-pattern check
would either demand one shape of all of them or rubber-stamp whatever each does.
Conformance fixture ``473_caught_user_thrown_builtin_error`` measures the
observable instead, on every engine and every compiled target in the matrix.

Each check carries a POSITIVE FLOOR (a minimum number of targets, raised names
and table entries) so a regex that silently stops matching fails loud instead of
passing vacuously.

Usage:
    python tools/check_error_rendering_tables.py [--root <repo root>] [--quiet]
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

# ── The cross-target contract ────────────────────────────────────────────────
#
# name -> the prefix Dart's own `toString()` puts in front of the message, or
# "" when Dart spells the message ALONE.
#
# Measured against the Dart SDK, never assumed (Dart 3.12.0):
#
#     StateError('No element').toString()   -> "Bad state: No element"
#     FormatException('bad').toString()     -> "FormatException: bad"
#     RangeError('oops').toString()         -> "RangeError: oops"
#     ArgumentError('nope').toString()      -> "Invalid argument(s): nope"
#     (42 as String)                        -> "type 'int' is not a subtype of
#                                               type 'String' in type cast"
#
# `TypeError` is the odd one out and the reason #641 exists: `_TypeError`'s
# `toString()` IS its message — there is no `TypeError: ` prefix — so a table
# that renders it like its three siblings is wrong in a way no amount of
# "add the missing entry" catches. `ArgumentError` is the second odd one and the
# reason #658 exists: its prefix is neither its own name nor empty but the fixed
# phrase `Invalid argument(s)`.
CANONICAL: dict[str, str] = {
    "StateError": "Bad state",
    "FormatException": "FormatException",
    "RangeError": "RangeError",
    "ArgumentError": "Invalid argument(s)",
    "TypeError": "",
}

# The built-in Dart errors a USER PROGRAM constructs and throws as a LITERAL —
# `throw StateError('boom')` — and then prints from its own catch body. Every
# explicit rendering table must cover all of them, whether or not that target's
# runtime ever raises one itself, because the value reaching `to_string` there
# comes from the COMPILER (a `messageCreation` the encoder produced), not from a
# raise site the RAISED extractor can see.
#
# `TypeError` is deliberately NOT in this set: `throw TypeError()` is not an
# idiom any encoder emits with a message argument, and the value every target
# actually renders under that name is the runtime-raised failed cast, which
# check 2 already covers.
LITERAL_THROWABLE: tuple[str, ...] = (
    "StateError", "FormatException", "RangeError", "ArgumentError",
)

# A target must raise at least this many distinct Dart error names, and a
# target that owns an explicit table must list at least this many entries.
# Floors, not equalities: they exist so a broken extractor is a FAILURE rather
# than a silent "0 raised, 0 rendered, all good".
MIN_RAISED_PER_TARGET = 1
MIN_TABLE_ENTRIES = len(LITERAL_THROWABLE)
MIN_TARGETS = 8
MIN_TABLE_TARGETS = 8


def _read(root: pathlib.Path, rel: str) -> str:
    """Read one source file, with escaped quotes normalised.

    Go's and C++'s compilers emit target source as Go/C++ string LITERALS, so a
    name they raise appears in their own source as ``NewMessage(\\"TypeError\\"``.
    Collapsing ``\\"`` to ``"`` (and ``\\'`` to ``'``) before matching is what
    makes those raise sites visible at all — without it the Go compiler's
    ``TypeError`` is invisible to every regex below, which is precisely how #641
    survived.
    """
    path = root / rel
    if not path.is_file():
        raise SystemExit(f"check_error_rendering_tables: missing source file {rel}")
    return path.read_text(encoding="utf-8").replace('\\"', '"').replace("\\'", "'")


def _files(root: pathlib.Path, *globs: str) -> list[str]:
    out: list[str] = []
    for g in globs:
        out.extend(sorted(str(p.relative_to(root).as_posix()) for p in root.glob(g)))
    if not out:
        raise SystemExit(f"check_error_rendering_tables: no files matched {globs!r}")
    return out


def _body(text: str, start: str, end: str, what: str) -> str:
    """The slice of `text` from the first `start` to the next `end` after it."""
    i = text.find(start)
    if i < 0:
        raise SystemExit(f"check_error_rendering_tables: could not locate {what}")
    j = text.find(end, i + len(start))
    if j < 0:
        raise SystemExit(f"check_error_rendering_tables: unterminated {what}")
    return text[i + len(start) : j]


def _body_opt(text: str, start: str, end: str) -> str:
    """`_body`, but an ABSENT table yields the empty string instead of exiting.

    Used where "this target owns no rendering table at all" is itself one of the
    defects under test (#658: the Dart reference engine had none), so it has to
    surface as the named failure below rather than as a parse abort. A table
    that is present but stops PARSING still trips the `MIN_TABLE_ENTRIES` floor.
    """
    i = text.find(start)
    if i < 0:
        return ""
    j = text.find(end, i + len(start))
    return "" if j < 0 else text[i + len(start) : j]


def _names(texts: list[str], pattern: str) -> set[str]:
    rx = re.compile(pattern, re.MULTILINE)
    found: set[str] = set()
    for t in texts:
        found.update(rx.findall(t))
    return found


def _dart_error_like(names: set[str]) -> set[str]:
    """Keep only names shaped like a Dart error/exception type."""
    return {n for n in names if re.fullmatch(r"[A-Z]\w*(?:Error|Exception)", n)}


class Target:
    def __init__(self, name: str, raised: set[str], table: dict[str, str] | None,
                 table_source: str | None, coverage_exempt: bool = False):
        self.name = name
        self.raised = raised
        self.table = table
        self.table_source = table_source
        # True only for a target whose THROWER carries the canonical string for
        # the names its table omits (C++, and the Dart reference engine, whose
        # `BallException` value reaches the catch variable verbatim). Agreement
        # still applies to the rows the table does hold — an exemption from
        # coverage is not an exemption from being right.
        self.coverage_exempt = coverage_exempt


def collect(root: pathlib.Path) -> list[Target]:
    targets: list[Target] = []

    # ── Dart (the reference engine) ──────────────────────────────────────────
    # A RUNTIME-raised error needs no table row: `_evalLazyTry` binds `e.value`
    # VERBATIM, so the thrower carries the canonical string — hence
    # `coverage_exempt`. A USER-thrown one does: `throw StateError('boom')`
    # reaches the catch variable as an ordinary `{__type__: 'main:StateError',
    # message: 'boom'}` instance map, and `_dartErrorPrefix` is what turns that
    # back into Dart's own `toString()`. Before #658 that arm returned the
    # MESSAGE — so the reference engine, the one every self-hosted engine is
    # compiled from, printed `boom` where Dart prints `Bad state: boom`.
    dart_src = [_read(root, f) for f in _files(root, "dart/engine/lib/*.dart")]
    dart_table_body = _body_opt(_read(root, "dart/engine/lib/engine_std.dart"),
                                "String? _dartErrorPrefix(", "\n}\n")
    targets.append(Target(
        "dart",
        _dart_error_like(_names(dart_src, r"BallException\(\s*'([A-Za-z_]\w*)'")),
        dict(re.findall(r"bare == '(\w+)'\) return '([^']*)';", dart_table_body)),
        "dart/engine/lib/engine_std.dart::_dartErrorPrefix",
        coverage_exempt=True,
    ))

    # ── C++ ──────────────────────────────────────────────────────────────────
    # C++ is the one target with BOTH shapes, so it gets a table AND is exempt
    # from the coverage check:
    #   - a LITERAL `throw StateError('boom')` keeps its ctor argument in
    #     `fields` and reaches `_ball_dart_error_to_string`'s name -> prefix
    #     table (#640), so those rows must AGREE with Dart like every sibling's;
    #   - a RUNTIME-raised one (`ball_cast_assert`'s `TypeError`) is built by the
    #     2-argument, no-`fields` ctor already carrying its canonical
    #     `toString()` string, and `ball_to_string(const BallException&)` returns
    #     `what()` verbatim — so the THROWER carries the string and no row is
    #     needed.
    # Modelling it as `table=` + `coverage_exempt=True` is what keeps the three
    # rows it does hold under the agreement check instead of unwatched, while not
    # demanding a `TypeError` row that would have no prefix to hold (#641).
    cpp_src = [_read(root, f) for f in
               _files(root, "cpp/shared/include/*.h", "cpp/compiler/src/compiler.cpp")]
    cpp_table_body = _body(_read(root, "cpp/shared/include/ball_emit_runtime.h"),
                           "inline std::string _ball_dart_error_to_string(",
                           "if (prefix == nullptr)",
                           "cpp _ball_dart_error_to_string")
    targets.append(Target(
        "cpp",
        _dart_error_like(_names(cpp_src, r"BallException\(\s*\"([A-Za-z_]\w*)\"")),
        dict(re.findall(r'bare == "(\w+)"\)\s*prefix = "([^"]*)"', cpp_table_body)),
        "cpp/shared/include/ball_emit_runtime.h::_ball_dart_error_to_string",
        coverage_exempt=True,
    ))

    # ── Rust ─────────────────────────────────────────────────────────────────
    rust_src = [_read(root, f) for f in
                _files(root, "rust/shared/src/*.rs", "rust/compiler/src/*.rs")]
    rust_raised = _dart_error_like(
        _names(rust_src, r"ball_throw_typed\(\s*\"([A-Za-z_]\w*)\""))
    rust_table_body = _body(_read(root, "rust/shared/src/value.rs"),
                            "fn dart_error_to_string(", "\n}\n",
                            "rust dart_error_to_string")
    targets.append(Target(
        "rust",
        rust_raised,
        dict(re.findall(r'"(\w+)" => "([^"]*)",', rust_table_body)),
        "rust/shared/src/value.rs::dart_error_to_string",
    ))

    # ── Go ───────────────────────────────────────────────────────────────────
    go_src = [_read(root, f) for f in
              _files(root, "go/runtime/*.go", "go/compiler/*.go")]
    go_raised = _dart_error_like(
        _names(go_src, r"dartError\(\s*\"([A-Za-z_]\w*)\"")
        | _names(go_src, r"NewMessage\(\s*\"([A-Za-z_]\w*)\""))
    go_table_body = _body(_read(root, "go/runtime/ops.go"),
                          "func dartErrorToString(", "\n}\n",
                          "go dartErrorToString")
    targets.append(Target(
        "go",
        go_raised,
        dict(re.findall(r'case "(\w+)":\s*\n\s*prefix = "([^"]*)"', go_table_body)),
        "go/runtime/ops.go::dartErrorToString",
    ))

    # ── C# ───────────────────────────────────────────────────────────────────
    cs_src = [_read(root, f) for f in
              _files(root, "csharp/shared/src/*.cs", "csharp/compiler/src/*.cs")]
    cs_raised = _dart_error_like(
        _names(cs_src, r"BallThrow\(\s*\"([A-Za-z_]\w*)\""))
    cs_table_body = _body(_read(root, "csharp/shared/src/BallValue.cs"),
                          "DartErrorToString(", "\n    }\n",
                          "csharp DartErrorToString")
    targets.append(Target(
        "csharp",
        cs_raised,
        dict(re.findall(r'"(\w+)" => "([^"]*)",', cs_table_body)),
        "csharp/shared/src/BallValue.cs::DartErrorToString",
    ))

    # ── TypeScript ───────────────────────────────────────────────────────────
    # The TS compiler raises a Dart error either as the tagged object literal
    # every emitted typed-`catch` guard tests (`{__type__: 'X', message: …}`) or
    # as a prefixed JS `Error`.
    ts_src = [_read(root, f) for f in
              _files(root, "ts/compiler/src/*.ts", "ts/engine/src/index.ts")]
    ts_raised = _dart_error_like(
        _names(ts_src, r"__type__'?\s*:\s*'([A-Za-z_]\w*)'")
        | _names(ts_src, r"new Error\('([A-Za-z_]\w*):"))
    ts_table_body = _body(_read(root, "ts/compiler/src/preamble.ts"),
                          "__ball_err_prefix: Record<string, string> = {", "};",
                          "ts __ball_err_prefix")
    targets.append(Target(
        "ts",
        ts_raised,
        dict(re.findall(r"(\w+): '([^']*)',", ts_table_body)),
        "ts/compiler/src/preamble.ts::__ball_err_prefix",
    ))

    # ── TypeScript, the ENGINE half ──────────────────────────────────────────
    # `ts/engine/src/engine_setup.ts` registers extra std functions that SHADOW
    # the compiled engine's own, `to_string` among them — so the self-hosted
    # engine never reaches `_ballToStringAsync`'s Dart-error arm and answers from
    # this hand-written `__bts` instead. That made it a SECOND rendering table
    # nobody was watching: it had no Dart-error arm at all, and a caught
    # `throw StateError('boom')` printed `{arg0: boom, message: boom}` — the
    # generic map form, which FILTERS every `__`-prefixed key, so even the type
    # tag was invisible in the output (issue #658). It is a table target like any
    # other now; `coverage_exempt` because the one name this file raises
    # (`FormatException`, from `int.parse`) it raises as a JS `Error` carrying its
    # own message.
    ts_engine_src = [_read(root, "ts/engine/src/engine_setup.ts")]
    ts_engine_table_body = _body_opt(
        ts_engine_src[0], "const __ball_err_prefix: Record<string, string> = {", "};")
    targets.append(Target(
        "ts-engine",
        _dart_error_like(_names(ts_engine_src, r"name:\s*'([A-Za-z_]\w*)'")),
        dict(re.findall(r"(\w+): '([^']*)',", ts_engine_table_body)),
        "ts/engine/src/engine_setup.ts::__bts",
        coverage_exempt=True,
    ))

    # ── Python ───────────────────────────────────────────────────────────────
    # Python's "table" is a class hierarchy rather than a name->prefix map, so
    # only closure + coverage apply here; the prefix each class spells is pinned
    # by python/compiler/tests/test_runtime.py.
    py_src = [_read(root, f) for f in _files(root, "python/runtime/ballrt/*.py")]
    py_raised = _dart_error_like(
        _names(py_src, r"from \.dart_errors import ([A-Za-z_]\w*)")
        | _names(py_src, r"from \.selfhost import ([A-Za-z_]\w*)"))
    py_rendered = _dart_error_like(
        _names([_read(root, "python/runtime/ballrt/dart_errors.py")],
               r"^class ([A-Za-z_]\w*)")
        | _names([_read(root, "python/runtime/ballrt/selfhost.py")],
                 r"^class ([A-Za-z_]\w*)"))
    targets.append(Target(
        "python", py_raised, {n: None for n in py_rendered},  # type: ignore[misc]
        "python/runtime/ballrt/{dart_errors,selfhost}.py",
    ))

    return targets


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=".", help="repo root (default: cwd)")
    ap.add_argument("--quiet", action="store_true", help="only print on failure")
    args = ap.parse_args(argv)

    root = pathlib.Path(args.root).resolve()
    targets = collect(root)
    failures: list[str] = []
    lines: list[str] = []

    if len(CANONICAL) < 5:
        failures.append("CANONICAL lost an entry — the contract itself is the floor")

    unlisted = sorted(set(LITERAL_THROWABLE) - set(CANONICAL))
    if unlisted:
        failures.append(
            f"LITERAL_THROWABLE names {unlisted}, which CANONICAL does not spell a "
            "prefix for")

    if len(targets) < MIN_TARGETS:
        failures.append(
            f"scanned {len(targets)} targets, floor is {MIN_TARGETS} — an extractor "
            "was dropped")

    table_targets = 0
    for t in targets:
        rendered = sorted(t.table) if t.table is not None else []
        lines.append(
            f"  {t.name:<7} raises {sorted(t.raised)}"
            + ("  (thrower carries the string)" if t.table is None
               else f"  renders {rendered}"
                    + ("  [+ thrower carries the rest]" if t.coverage_exempt else ""))
        )

        if len(t.raised) < MIN_RAISED_PER_TARGET:
            failures.append(
                f"{t.name}: found {len(t.raised)} raised Dart error names, floor is "
                f"{MIN_RAISED_PER_TARGET} — the raise-site extractor stopped matching")

        unknown = sorted(t.raised - set(CANONICAL))
        if unknown:
            failures.append(
                f"{t.name}: raises {unknown}, which the cross-target contract does not "
                "know. Add it to CANONICAL (with the prefix Dart's own toString() "
                "spells, measured against the SDK) and to EVERY rendering table.")

        if t.table is None:
            continue
        table_targets += 1

        if len(t.table) < MIN_TABLE_ENTRIES:
            failures.append(
                f"{t.name}: rendering table {t.table_source} parsed to "
                f"{len(t.table)} entries, floor is {MIN_TABLE_ENTRIES} — the table "
                "extractor stopped matching")

        missing = [] if t.coverage_exempt else sorted(t.raised - set(t.table))
        if missing:
            failures.append(
                f"{t.name}: raises {missing} but {t.table_source} has no entry for "
                "it, so a caught one prints this target's raw value form instead of "
                "Dart's toString(). THIS is the 'table not closed' defect (#641).")

        # ── 4. Literal-throw coverage (#658) ─────────────────────────────────
        # Unconditional: `coverage_exempt` exempts a target from covering what
        # its own RUNTIME raises (the thrower carries that string), and says
        # nothing about a value a user program constructed itself.
        unrendered = sorted(set(LITERAL_THROWABLE) - set(t.table))
        if unrendered:
            failures.append(
                f"{t.name}: {t.table_source} has no entry for {unrendered}, which a "
                "user program can `throw` as a literal built-in error and then "
                "print. THIS is the 'table open on the literal-throw side' defect "
                "(#658).")

        for name, prefix in sorted(t.table.items()):
            if prefix is None:  # python: prefix pinned by its own unit test
                continue
            if name not in CANONICAL:
                failures.append(
                    f"{t.name}: {t.table_source} renders {name!r}, which is not in the "
                    "cross-target contract")
            elif prefix != CANONICAL[name]:
                failures.append(
                    f"{t.name}: {t.table_source} renders {name!r} with prefix "
                    f"{prefix!r}; Dart spells {CANONICAL[name]!r}"
                    + (" (no prefix at all — its toString() IS its message)"
                       if CANONICAL[name] == "" else ""))

    if table_targets < MIN_TABLE_TARGETS:
        failures.append(
            f"parsed {table_targets} explicit rendering tables, floor is "
            f"{MIN_TABLE_TARGETS}")

    if failures or not args.quiet:
        print("Dart-error rendering tables:")
        print("\n".join(lines))
        print(f"  contract: {CANONICAL}")
        print(f"  literal-throwable: {list(LITERAL_THROWABLE)}")
        print(f"  {len(targets)} targets, {table_targets} explicit tables")

    if failures:
        print("\nFAIL:", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        return 1

    print("OK: every raised Dart error name has a rendering entry, and every entry "
          "agrees with Dart.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
