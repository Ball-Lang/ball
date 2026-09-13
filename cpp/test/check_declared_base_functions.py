#!/usr/bin/env python3
"""Declared-drift guard for the C++ compiler's base-module dispatchers (#607).

WHY THIS EXISTS
---------------
`cpp/compiler/src/compiler.cpp` implements base functions by HARDCODED NAME —
`if (fn == "thread_detach") ...` — and nothing ever compared those names against
the canonical declarations in `dart/shared/lib/std*.dart`. So
`compile_concurrency_call` grew three functions no module builder anywhere
declares (`thread_detach`, `unique_lock`, `atomic_fetch_add`): no encoder can
produce them, no engine implements them, they are absent from
`tests/conformance/std_coverage.json`, and the only thing that exercised them
was a C++-compiler-local unit test asserting on emitted source TEXT. That is the
same "implemented by hardcoded name but never declared" drift
`dart/shared/test/std_routed_declarations_test.dart` catches on the Dart side
(issue #505) — the C++ compiler had no equivalent, so #607 adds one.

The canonical inventory is `tests/conformance/std_coverage.json`, NOT
`dart/shared/std.json`: `gen_std.dart` serialises only `buildStdModule()`, so
`std.json` has no `std_concurrency` (nor `std_collections`, `std_io`, …) in it
at all, while `gen_std_coverage.dart` calls ALL EIGHT canonical builders. The
coverage file is regenerated and diffed by ci.yml's `ball-freshness` job, so it
cannot drift from the builders either.

WHAT IT ASSERTS
---------------
  1. Every base-function name a module-scoped `compile_*_call` dispatcher
     implements is DECLARED for that module by the canonical builders, or is
     named in the known-gaps file next to this script.
  2. The known-gaps file is a RATCHET, not a dumping ground: an entry that is
     now declared, or that the compiler no longer implements, is an error. The
     debt can only shrink.
  3. Positive floor: the extraction found a realistic number of names, and every
     mapped dispatcher yielded at least one. A regex that quietly stops matching
     would otherwise make every check above pass vacuously.

`compile_std_call`'s 25 undeclared names and two more (`std_collections`'s
`map_create`, `std_time`'s `timestamp_ms`) were already there when this guard
landed; they are frozen in the known-gaps file, MEASURED not assumed. Closing
one means declaring it in the relevant `dart/shared/lib/std*.dart` builder,
regenerating `std_coverage.json`, and deleting its line — deliberately not done
here, because each declaration ripples through every compiler, every engine and
the coverage inventory.

Two dispatchers are deliberately NOT module-scoped and so are not checked:
`compile_method_call` (method-style calls carry an EMPTY module and a `self`
field — there is no module whose declarations they could be compared against)
and `compile_cpp_std_call` (the legacy `cpp_std` module, which no builder
declares at all by design).

Usage:
  python3 cpp/test/check_declared_base_functions.py              # check
  python3 cpp/test/check_declared_base_functions.py --self-test  # prove it bites
"""

from __future__ import annotations

import json
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))

# `compile_<x>_call` -> the base module whose declarations it implements.
DISPATCHER_MODULES = {
    "compile_std_call": "std",
    "compile_collections_call": "std_collections",
    "compile_io_call": "std_io",
    "compile_convert_call": "std_convert",
    "compile_fs_call": "std_fs",
    "compile_time_call": "std_time",
    "compile_concurrency_call": "std_concurrency",
}

# Positive floor: the total number of implemented names the extraction must find
# across the mapped dispatchers. It stood at 247 when this guard landed; the
# floor is set well below that so ordinary churn never trips it, but a regex
# that stops matching does.
MIN_TOTAL_NAMES = 200

_DEF_RE = re.compile(r"^std::string CppCompiler::(compile_\w+_call)\(")
_FN_RE = re.compile(r'\bfn\s*==\s*"([A-Za-z0-9_]+)"')


def implemented_names(compiler_src: str) -> dict[str, set[str]]:
    """`compile_*_call` -> the base-function names its body tests for.

    A dispatcher body runs from its definition line to the next line that is
    exactly `}` at column 0 (this file's style: a function's closing brace is
    never indented, and every nested brace is). Brace COUNTING is not usable
    here — the emitted C++ these functions build is full of `{`/`}` inside
    string literals.
    """
    out: dict[str, set[str]] = {}
    current: str | None = None
    for line in compiler_src.splitlines():
        m = _DEF_RE.match(line)
        if m:
            current = m.group(1)
            out.setdefault(current, set())
            continue
        if current is None:
            continue
        if line == "}":
            current = None
            continue
        out[current].update(_FN_RE.findall(line))
    return out


def declared_names(coverage_path: str) -> dict[str, set[str]]:
    """`module` -> declared base-function names, from the canonical inventory."""
    with open(coverage_path, encoding="utf-8") as f:
        coverage = json.load(f)
    out: dict[str, set[str]] = {}
    for entry in coverage["functions"]:
        out.setdefault(entry["module"], set()).add(entry["name"])
    return out


def read_known_gaps(path: str) -> set[str]:
    entries: set[str] = set()
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.split("#", 1)[0].strip()
            if line:
                entries.add(line)
    return entries


def check(
    compiler_path: str,
    coverage_path: str,
    gaps_path: str,
    dispatchers: dict[str, str] | None = None,
    min_total: int | None = None,
) -> list[str]:
    """Returns a list of error messages; empty means the gate passes."""
    dispatchers = DISPATCHER_MODULES if dispatchers is None else dispatchers
    min_total = MIN_TOTAL_NAMES if min_total is None else min_total
    errors: list[str] = []
    with open(compiler_path, encoding="utf-8") as f:
        implemented = implemented_names(f.read())
    declared = declared_names(coverage_path)
    gaps = read_known_gaps(gaps_path)

    # -- 3. Positive floor, FIRST: a vacuous extraction must never read as a
    # clean bill of health.
    total = 0
    for dispatcher, module in sorted(dispatchers.items()):
        names = implemented.get(dispatcher)
        if not names:
            errors.append(
                "dispatcher %s yielded NO base-function names - it was renamed, "
                "removed, or the extraction stopped matching. Fix the "
                "extraction (or this table) rather than deleting the gate."
                % dispatcher
            )
            continue
        total += len(names)
    if total < min_total:
        errors.append(
            "extracted only %d implemented base-function names across the "
            "mapped dispatchers (floor: %d). The extraction has stopped "
            "matching; fix it before trusting the drift check."
            % (total, min_total)
        )
    if errors:
        return errors

    # -- 1. Implemented but not declared.
    undeclared: list[str] = []
    live_gaps: set[str] = set()
    for dispatcher, module in sorted(dispatchers.items()):
        for name in sorted(implemented[dispatcher]):
            if name in declared.get(module, set()):
                continue
            key = "%s.%s" % (module, name)
            if key in gaps:
                live_gaps.add(key)
            else:
                undeclared.append("%s (%s)" % (key, dispatcher))
    if undeclared:
        errors.append(
            "IMPLEMENTED BUT NOT DECLARED - cpp/compiler/src/compiler.cpp "
            "dispatches these base functions by hardcoded name, but no "
            "dart/shared/lib/std*.dart builder declares them, so they are "
            "absent from tests/conformance/std_coverage.json, unreachable by "
            "every encoder, and implemented by no engine:\n  "
            + "\n  ".join(undeclared)
            + "\nEither delete the dispatch arm, or DECLARE the function in the "
            "canonical builder and regenerate the inventory "
            "(`cd dart/shared && dart run bin/gen_std.dart` plus "
            "`cd dart/encoder && dart run bin/gen_std_coverage.dart`). Adding a "
            "line to cpp/test/declared_base_functions_known_gaps.txt is NOT an "
            "option for a new name - that file is a frozen ratchet (issue "
            "#607)."
        )

    # -- 2. The known-gaps file is a ratchet.
    stale = sorted(gaps - live_gaps)
    if stale:
        errors.append(
            "STALE KNOWN GAPS - these entries are no longer live drift (the "
            "function is now declared, or the compiler no longer implements "
            "it). Delete them so the debt can only shrink:\n  "
            + "\n  ".join(stale)
        )
    return errors


# ── self-test ───────────────────────────────────────────────────────────────

_FAKE_COMPILER = '''\
namespace ball {

std::string CppCompiler::compile_std_call(const std::string& fn,
                                            const ball::ir::FunctionCall& call) {
    if (fn == "add") { return "a + b"; }
    if (fn == "cascade") { return "{ a; }"; }
    return "";
}

std::string CppCompiler::compile_concurrency_call(const std::string& fn,
                                            const ball::ir::FunctionCall& call) {
    if (fn == "thread_spawn") { return "spawn"; }
%s
    return "";
}

}  // namespace ball
'''

_FAKE_COVERAGE = {
    "functions": [
        {"module": "std", "name": "add"},
        {"module": "std_concurrency", "name": "thread_spawn"},
    ]
}


def _run_self_test() -> int:
    failures: list[str] = []
    with tempfile.TemporaryDirectory() as tmp:
        coverage = os.path.join(tmp, "std_coverage.json")
        with open(coverage, "w", encoding="utf-8") as f:
            json.dump(_FAKE_COVERAGE, f)

        def write(compiler_extra: str, gap_lines: list[str]) -> tuple[str, str]:
            comp = os.path.join(tmp, "compiler.cpp")
            with open(comp, "w", encoding="utf-8") as f:
                f.write(_FAKE_COMPILER % compiler_extra)
            gaps = os.path.join(tmp, "gaps.txt")
            with open(gaps, "w", encoding="utf-8") as f:
                f.write("\n".join(gap_lines) + "\n")
            return comp, gaps

        fake_dispatchers = {
            "compile_std_call": "std",
            "compile_concurrency_call": "std_concurrency",
        }

        def run(comp, gaps, min_total=2):
            return check(
                comp,
                coverage,
                gaps,
                dispatchers=fake_dispatchers,
                min_total=min_total,
            )

        # (a) clean tree, with the pre-existing `std.cascade` drift frozen.
        comp, gaps = write("", ["std.cascade"])
        errs = run(comp, gaps)
        if errs:
            failures.append("clean tree should pass, got: %s" % errs)

        # (b) a NEW undeclared name must fail.
        comp, gaps = write(
            '    if (fn == "thread_detach") { return "detach"; }',
            ["std.cascade"],
        )
        errs = run(comp, gaps)
        if not any("IMPLEMENTED BUT NOT DECLARED" in e for e in errs):
            failures.append("a new undeclared name should fail, got: %s" % errs)

        # (c) a stale gap entry (the name is gone) must fail.
        comp, gaps = write("", ["std.cascade", "std_concurrency.unique_lock"])
        errs = run(comp, gaps)
        if not any("STALE KNOWN GAPS" in e for e in errs):
            failures.append("a stale gap entry should fail, got: %s" % errs)

        # (d) a gap entry naming a now-DECLARED function must fail.
        comp, gaps = write("", ["std.cascade", "std.add"])
        errs = run(comp, gaps)
        if not any("STALE KNOWN GAPS" in e for e in errs):
            failures.append(
                "a gap entry for a declared function should fail, got: %s" % errs
            )

        # (e) the positive floor must bite when the extraction goes vacuous.
        comp, gaps = write("", ["std.cascade"])
        errs = run(comp, gaps, min_total=1000)
        if not any("extracted only" in e for e in errs):
            failures.append("the positive floor should bite, got: %s" % errs)

        # (f) a dispatcher that yields nothing at all must fail.
        errs = check(
            comp,
            coverage,
            gaps,
            dispatchers={"compile_renamed_call": "std"},
            min_total=0,
        )
        if not any("yielded NO base-function names" in e for e in errs):
            failures.append("a vanished dispatcher should fail, got: %s" % errs)

    if failures:
        for f in failures:
            sys.stderr.write("SELF-TEST FAILURE: %s\n" % f)
        return 1
    print("check_declared_base_functions.py: self-test passed (6 cases)")
    return 0


def main(argv: list[str]) -> int:
    if "--self-test" in argv:
        return _run_self_test()
    errors = check(
        os.environ.get(
            "BALL_CPP_COMPILER_SRC",
            os.path.join(ROOT, "cpp", "compiler", "src", "compiler.cpp"),
        ),
        os.environ.get(
            "BALL_STD_COVERAGE",
            os.path.join(ROOT, "tests", "conformance", "std_coverage.json"),
        ),
        os.environ.get(
            "BALL_CPP_DECLARED_KNOWN_GAPS",
            os.path.join(HERE, "declared_base_functions_known_gaps.txt"),
        ),
    )
    if errors:
        for e in errors:
            sys.stderr.write("ERROR: %s\n" % e)
        return 1
    print(
        "check_declared_base_functions.py: every base function the C++ "
        "compiler dispatches is declared by the canonical builders (or is a "
        "frozen, still-live known gap)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
