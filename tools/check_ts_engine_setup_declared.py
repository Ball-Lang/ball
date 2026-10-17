#!/usr/bin/env python3
"""Declared-drift guard for the TS engine's hand-written std overrides (#817).

WHY THIS EXISTS
---------------
`ts/engine/src/engine_setup.ts`'s `registerExtraStdFunctions` registers base
functions on `StdHandler` by HARDCODED NAME (`_r('foo', (i) => ...)`), and
nothing ever compared those names against the canonical declarations in
`dart/shared/lib/std*.dart`. So the registry grew a plural
`string_from_char_codes` arm that no builder declares, no encoder in the repo
emits, and the Dart reference engine never dispatches — unreachable in both
directions, and exercised only by six tests that called the handler directly
(`h.call("string_from_char_codes", ...)`), so they passed whether or not any
*program* could ever reach it. This is the same "implemented by hardcoded name
but the builder never declares it" class as issue #505 (Dart), #607 (C++) and
#743 (Python, the identical `string_from_char_codes` arm — deleted there for
the same reason). TS had no equivalent closed-set gate; #817 adds one.

The canonical inventory is `tests/conformance/std_coverage.json` (built from
ALL EIGHT canonical `buildStd*Module()` builders — `dart/shared/std.json`
alone has only `buildStdModule()`), regenerated and diffed by ci.yml's
`Ball Artifact Freshness` job, so it cannot itself drift from the builders.

`StdHandler.register(name, fn)` is a FLAT, module-less namespace — one handler
serves all eight `std*` modules by function name alone
(`dart/engine/lib/engine_types.dart`'s `StdModuleHandler._dispatch` is the same
shape) — so this gate checks a registered name against the declared set
UNION'd across every module, never against one module in particular.

WHAT THIS ASSERTS
------------------
1. Every name `registerExtraStdFunctions` registers via `_r(...)` is DECLARED
   by some canonical builder (present in `std_coverage.json`, any module), or
   is named in `declared_ts_engine_overrides_known_gaps.txt` next to this
   script.
2. That known-gaps file is a RATCHET, not a dumping ground: an entry that is
   now declared, or that the registry no longer registers, is an error — the
   debt can only shrink, never grow quietly.
3. Positive floor: the extraction found a realistic number of `_r(...)` calls.
   A regex that quietly stops matching would otherwise make every check above
   pass vacuously.

The known-gaps file freezes the drift that already existed when this gate was
written, MEASURED by running the check with an empty list, never assumed —
see that file's own header for the count and names. Closing an entry means
either declaring the name in the relevant `dart/shared/lib/std*.dart` builder
(then regenerating `std_coverage.json` — see CLAUDE.md) and deleting its line,
or proving nothing anywhere needs it and deleting both the registration and
its line, the way #817 did for `string_from_char_codes` itself.

Usage:
  python3 tools/check_ts_engine_setup_declared.py              # check
  python3 tools/check_ts_engine_setup_declared.py --self-test  # prove it bites
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent

REGISTER_FN_RE = re.compile(
    r"function registerExtraStdFunctions\([^)]*\)\s*:\s*void\s*\{"
)
CALL_RE = re.compile(r"_r\(\s*'([A-Za-z0-9_]+)'")

# Positive floor on the number of `_r(...)` registrations the extraction must
# find. Measured value is ~135; the floor sits well below it so ordinary
# churn never trips it, but a regex that stops matching does.
MIN_REGISTRATIONS = 80


def extract_registered_names(ts_src: str) -> set[str]:
    """Every name `_r('<name>', ...)` inside `registerExtraStdFunctions`'s body.

    The function body is located by brace-depth counting from its opening
    `{` (never by indentation), because unlike the Dart dispatch map this
    function's own statements are not consistently indented leaf expressions —
    several wrap multi-line closures of their own.
    """
    m = REGISTER_FN_RE.search(ts_src)
    if not m:
        raise SystemExit(
            "check_ts_engine_setup_declared: could not locate "
            "registerExtraStdFunctions(...): void { in the given source — the "
            "extraction regex has stopped matching"
        )
    depth = 1
    i = m.end()
    while depth > 0:
        if i >= len(ts_src):
            raise SystemExit(
                "check_ts_engine_setup_declared: registerExtraStdFunctions's "
                "body never closed"
            )
        if ts_src[i] == "{":
            depth += 1
        elif ts_src[i] == "}":
            depth -= 1
        i += 1
    body = ts_src[m.end():i]
    return set(CALL_RE.findall(body))


def declared_names(coverage_path: Path) -> set[str]:
    with coverage_path.open(encoding="utf-8") as f:
        coverage = json.load(f)
    return {entry["name"] for entry in coverage["functions"]}


def read_known_gaps(path: Path) -> set[str]:
    entries: set[str] = set()
    if not path.is_file():
        return entries
    with path.open(encoding="utf-8") as f:
        for raw in f:
            line = raw.split("#", 1)[0].strip()
            if line:
                entries.add(line)
    return entries


def check(
    engine_setup_path: Path,
    coverage_path: Path,
    gaps_path: Path,
    min_registrations: int = MIN_REGISTRATIONS,
) -> list[str]:
    """Returns a list of error messages; empty means the gate passes."""
    errors: list[str] = []
    ts_src = engine_setup_path.read_text(encoding="utf-8")
    registered = extract_registered_names(ts_src)

    if len(registered) < min_registrations:
        errors.append(
            f"extracted only {len(registered)} _r(...) registrations from "
            f"registerExtraStdFunctions (floor: {min_registrations}). The "
            "extraction has stopped matching; fix it before trusting the "
            "drift check below."
        )
        return errors

    declared = declared_names(coverage_path)
    gaps = read_known_gaps(gaps_path)

    undeclared = sorted(n for n in registered if n not in declared and n not in gaps)
    if undeclared:
        errors.append(
            "registered but NOT declared by any canonical std*.dart builder "
            f"(and not in {gaps_path.name}): {undeclared}. Either declare the "
            "name in the relevant dart/shared/lib/std*.dart builder and "
            "regenerate tests/conformance/std_coverage.json (see CLAUDE.md), "
            "or delete the dead registration from engine_setup.ts (issue #817)."
        )

    live_gaps = {n for n in gaps if n in registered and n not in declared}
    stale_gaps = sorted(gaps - live_gaps)
    if stale_gaps:
        errors.append(
            f"{gaps_path.name} lists {stale_gaps} as known gaps, but each is "
            "now either declared by a canonical builder or no longer "
            "registered by engine_setup.ts — the ratchet only shrinks, so "
            "delete these lines rather than leaving them to rot as a passing "
            "exemption."
        )

    return errors


# ── Self-test: a gate nobody has watched fail is not a gate ────────────────


def _run_self_test() -> int:
    import tempfile

    failures: list[str] = []

    def write(tmp: Path, name: str, content: str) -> Path:
        p = tmp / name
        p.write_text(content, encoding="utf-8")
        return p

    ts_good = """
function registerExtraStdFunctions(stdHandler: StdHandler, engine: any): void {
  const _r = stdHandler.register.bind(stdHandler);
  _r('list_push', (i: any) => null);
  _r('list_pop', (i: any) => null);
  _r('string_from_char_code', (i: any) => null);
}
""".strip()
    ts_phantom = """
function registerExtraStdFunctions(stdHandler: StdHandler, engine: any): void {
  const _r = stdHandler.register.bind(stdHandler);
  _r('list_push', (i: any) => null);
  _r('list_pop', (i: any) => null);
  _r('string_from_char_codes', (i: any) => null);
}
""".strip()
    ts_vanished_fn = "const x = 1;\n"

    coverage = {
        "functions": [
            {"module": "std_collections", "name": "list_push"},
            {"module": "std_collections", "name": "list_pop"},
            {"module": "std", "name": "string_from_char_code"},
        ]
    }

    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        coverage_path = write(tmp, "std_coverage.json", json.dumps(coverage))

        # 1. Clean source, empty gaps file -> passes.
        good_path = write(tmp, "engine_setup.ts", ts_good)
        empty_gaps = write(tmp, "gaps.txt", "")
        errs = check(good_path, coverage_path, empty_gaps, min_registrations=1)
        if errs:
            failures.append(f"clean source should pass, got: {errs}")

        # 2. A phantom (undeclared) registration with no known-gaps entry
        #    MUST be caught.
        phantom_path = write(tmp, "engine_setup_phantom.ts", ts_phantom)
        errs = check(phantom_path, coverage_path, empty_gaps, min_registrations=1)
        if not any("string_from_char_codes" in e for e in errs):
            failures.append(
                f"an undeclared registration should be reported, got: {errs}"
            )

        # 3. The SAME phantom, but frozen in the known-gaps file -> passes
        #    (that is what the ratchet is FOR).
        frozen_gaps = write(tmp, "gaps_frozen.txt", "string_from_char_codes\n")
        errs = check(phantom_path, coverage_path, frozen_gaps, min_registrations=1)
        if errs:
            failures.append(
                f"a name frozen in the known-gaps file should pass, got: {errs}"
            )

        # 4. A known-gaps entry that is now DECLARED (or no longer registered)
        #    must be rejected — the ratchet only shrinks.
        stale_gaps = write(tmp, "gaps_stale.txt", "list_push\n")
        errs = check(good_path, coverage_path, stale_gaps, min_registrations=1)
        if not any("list_push" in e and "ratchet" in e for e in errs):
            failures.append(f"a now-declared known gap should be rejected, got: {errs}")

        stale_gaps2 = write(tmp, "gaps_stale2.txt", "never_registered_name\n")
        errs = check(good_path, coverage_path, stale_gaps2, min_registrations=1)
        if not any("never_registered_name" in e for e in errs):
            failures.append(
                f"a known gap for a name no longer registered should be "
                f"rejected, got: {errs}"
            )

        # 5. Positive floor: an extractor that finds nothing must fail loud,
        #    not pass vacuously.
        vanished_path = write(tmp, "engine_setup_vanished.ts", ts_vanished_fn)
        try:
            check(vanished_path, coverage_path, empty_gaps, min_registrations=1)
            failures.append(
                "a source with no registerExtraStdFunctions at all should "
                "raise SystemExit, not return normally"
            )
        except SystemExit:
            pass

        few_path = write(tmp, "engine_setup_few.ts", ts_good)
        errs = check(few_path, coverage_path, empty_gaps, min_registrations=99)
        if not any("floor" in e for e in errs):
            failures.append(f"a below-floor extraction should fail, got: {errs}")

    if failures:
        for f in failures:
            sys.stderr.write(f"SELF-TEST FAILURE: {f}\n")
        return 1
    print("check_ts_engine_setup_declared.py: self-test passed (6 cases)")
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=str(ROOT), help="repo root (default: this script's repo)")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv)

    if args.self_test:
        return _run_self_test()

    root = Path(args.root)
    engine_setup_path = root / "ts" / "engine" / "src" / "engine_setup.ts"
    coverage_path = root / "tests" / "conformance" / "std_coverage.json"
    gaps_path = HERE / "declared_ts_engine_overrides_known_gaps.txt"

    if not engine_setup_path.is_file():
        raise SystemExit(f"missing {engine_setup_path}")
    if not coverage_path.is_file():
        raise SystemExit(f"missing {coverage_path}")

    errors = check(engine_setup_path, coverage_path, gaps_path)
    if errors:
        for e in errors:
            sys.stderr.write(f"ERROR: {e}\n")
        return 1

    registered = extract_registered_names(engine_setup_path.read_text(encoding="utf-8"))
    gaps = read_known_gaps(gaps_path)
    print(
        "check_ts_engine_setup_declared.py: every name "
        "registerExtraStdFunctions registers is declared by a canonical "
        f"std*.dart builder (or is a frozen, still-live known gap) "
        f"(extracted {len(registered)} registrations, {len(gaps)} frozen "
        f"gaps, floor {MIN_REGISTRATIONS})."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
