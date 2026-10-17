#!/usr/bin/env python3
"""Dart-dispatch drift guard for TS engine std-function overrides (#732).

WHY THIS EXISTS
----------------
`ts/engine/src/engine_setup.ts`'s `registerExtraStdFunctions` carries dozens of
hand-written std-function overrides that SHADOW the entry the COMPILED
self-hosted engine (`compiled_engine.ts`, generated from
`dart/engine/lib/engine.dart` / `dart/self_host/engine.ball.json`) registers
for the same base-function name — `register()` on a `StdHandler` is
last-write-wins, and `registerExtraStdFunctions` runs after the compiled
table is built (see the inline `// shadows` / `// override` comments this
file already carries, e.g. at `engine_setup.ts:569,699-700,828-829,…`).
Several of those overrides exist because the compiled engine's generic
dispatch cannot express the shape at all (async-callback composition,
BallFuture/BallGenerator unwrapping); PR #722 measured that ONE such override
(the error-rendering table) stayed byte-identical across a `dart/engine`
regen and gated exactly that one case
(`tools/check_error_rendering_tables.py`). Nothing enumerated the REST of the
overrides against their Dart source, so a change to
`dart/engine/lib/engine_std.dart`'s dispatch for `list_sort`, `map_put_if_absent`,
`std_time`, `to_string`, … can silently diverge from what the TS self-hosted
engine actually runs: the override wins, the TS regen gate
(`Ball Artifact Freshness` / `git diff --exit-code -- compiled_engine.ts`) is
untouched because it only diffs the COMPILED half, and conformance only
catches it if some fixture happens to exercise the exact input shape the two
now disagree on.

WHAT THIS DOES
---------------
1. Extracts every `name -> value` entry from `dart/engine/lib/engine_std.dart`'s
   `_buildStdDispatch()` map literal (the single source `dart/self_host/
   engine.ball.json` is compiled FROM — see `dart/compiler/tool/
   gen_engine_json.dart`), and every name `ts/engine/src/engine_setup.ts`'s
   `registerExtraStdFunctions` registers via `_r('name', ...)`.
2. The INTERSECTION of those two sets is the real, STRUCTURAL "shadow"
   inventory this issue's Definition of Done asks for — a name in both places
   is one where the TS override supersedes a Dart dispatch entry that exists
   for the same name, independent of any hand-curated line-number list (which
   rots the moment either file reformats).
3. For every name in that inventory, fingerprints the Dart entry's BEHAVIOUR:
   an inline closure is hashed by its (whitespace-normalised) body text; a
   TEAR-OFF (`'name': _stdFoo,` — about a third of entries point at a named
   top-level/private method rather than an inline closure) is resolved to
   THAT method's own body and hashed instead, so a change to `_stdFoo`'s
   implementation is visible even though the one-line map entry naming it
   never changes.
4. Compares the fingerprints against a COMMITTED snapshot
   (`tools/ts_engine_overrides_dart_snapshot.json`) and fails on any
   mismatch, any name newly in the intersection with no snapshot entry, or
   any snapshot entry whose name no longer shadows anything — each printing
   what to do next.

WHAT THIS DOES **NOT** DO (read before assuming more coverage than exists)
----------------------------------------------------------------------------
This is a fingerprint on the DART side only. It proves "dart/engine_std.dart's
implementation of this shadowed name changed shape since the snapshot was
last refreshed" — which is exactly the signal issue #732 asks for ("CI fails,
or at minimum flags, when a name in this inventory changes shape in the Dart
engine without the corresponding TS override being touched in the same PR").
It does NOT verify that `engine_setup.ts`'s override was ALSO updated to
match; refreshing the snapshot (`--update`) is the forcing function that
makes a human look at the diff and decide — update the override, or write
down in the PR why the shadowed behaviour still needs none of the Dart
change. A pure comment/whitespace edit to the Dart entry also trips this
(the fingerprint does not strip comments, deliberately — see the body-text
rule below), which is the same "false positives over blind spots" trade this
repo's other golden/snapshot gates make.

Usage:
  python3 tools/check_ts_engine_overrides_sync.py                # check
  python3 tools/check_ts_engine_overrides_sync.py --update        # refresh
  python3 tools/check_ts_engine_overrides_sync.py --self-test      # prove it bites
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SNAPSHOT_PATH = HERE / "ts_engine_overrides_dart_snapshot.json"

DISPATCH_HEADER_RE = re.compile(
    r"Map<String, FutureOr<Object\?> Function\(Object\?\)> _buildStdDispatch\(\) \{\s*return \{"
)
ENTRY_START_RE = re.compile(r"^      '([A-Za-z0-9_]+)':\s*(.*)$")
MAP_CLOSE_RE = re.compile(r"^    \};?\s*$")
# A bare method/function TEAR-OFF value: an identifier (optionally `_`-prefixed),
# an optional trailing comma, and an optional trailing `//` comment — never a
# call (`(`), which rules out `(i) => ...` closures.
TEAROFF_RE = re.compile(r"^(_?[A-Za-z][A-Za-z0-9_]*),?\s*(?://.*)?$")

REGISTER_FN_RE = re.compile(
    r"function registerExtraStdFunctions\([^)]*\)\s*:\s*void\s*\{"
)
CALL_RE = re.compile(r"_r\(\s*'([A-Za-z0-9_]+)'")

# Positive floor on the intersection size. Measured value is ~100; the floor
# sits well below it so ordinary churn (a declared name moving, a TS override
# deleted because the compiled handler is now correct — see .claude/rules/
# ts.md's #597/#616 lessons) never trips it, but a regex that stops matching
# does.
MIN_INTERSECTION = 60


class ExtractionError(Exception):
    pass


def extract_dart_dispatch_entries(dart_src: str) -> dict[str, str]:
    """name -> raw joined value text, straight from `_buildStdDispatch()`'s map.

    Walked line-by-line rather than brace-counted: every top-level entry in
    this map literal is formatted at EXACTLY 6 leading spaces (dart_format's
    own style for this file), so a line matching that indentation plus a
    quoted key is unambiguously a new entry, and everything before the next
    such line (or the map's own closing `};`) is that entry's value — even
    when the value is itself a multi-line closure whose own nested lines sit
    at 8+ spaces.
    """
    m = DISPATCH_HEADER_RE.search(dart_src)
    if not m:
        raise ExtractionError(
            "could not locate 'Map<String, FutureOr<Object?> Function(Object?)> "
            "_buildStdDispatch() { return {' — the extraction regex has stopped "
            "matching dart/engine/lib/engine_std.dart"
        )
    entries: dict[str, str] = {}
    cur_name: str | None = None
    cur_lines: list[str] = []
    for line in dart_src[m.end():].split("\n"):
        em = ENTRY_START_RE.match(line)
        if em:
            if cur_name is not None:
                entries[cur_name] = "\n".join(cur_lines)
            cur_name = em.group(1)
            cur_lines = [em.group(2)]
            continue
        if cur_name is not None:
            if MAP_CLOSE_RE.match(line):
                entries[cur_name] = "\n".join(cur_lines)
                cur_name = None
                break
            cur_lines.append(line)
    if cur_name is not None:
        raise ExtractionError("_buildStdDispatch()'s map literal never closed")
    return entries


def _skip_string(src: str, i: int) -> int | None:
    """If `src[i]` opens a Dart ' or " string, return the index just past its
    closing quote (honouring `\\`-escapes); otherwise None."""
    quote = src[i]
    if quote not in "'\"":
        return None
    j = i + 1
    while j < len(src):
        c = src[j]
        if c == "\\":
            j += 2
            continue
        if c == quote:
            return j + 1
        j += 1
    raise ExtractionError(f"unterminated string literal starting at offset {i}")


def resolve_method_body(dart_src: str, name: str) -> str | None:
    """The body of a top-level/private method or getter named [name], or None.

    Handles the two shapes `_buildStdDispatch()`'s tear-off VALUES point at:
    a brace body (`Foo _name(Bar i) { ... }`, with an optional `async`/
    `async*`/`sync*` modifier before the `{`) and an arrow body
    (`Foo _name(Bar i) => expr;`). Braces and the arrow body's terminating
    `;` are counted outside string literals only, so a `;` or `{`/`}` inside
    a message string (`throw BallRuntimeError('std.foo: {bad}');`) cannot
    end the scan early or late.
    """
    def_re = re.compile(
        r"^  (?:static )?[A-Za-z_][A-Za-z0-9_<>?, .]*\s+" + re.escape(name)
        + r"\([^)]*\)\s*(?:async\*?|sync\*?)?\s*(\{|=>)",
        re.MULTILINE,
    )
    dm = def_re.search(dart_src)
    if not dm:
        return None
    arrow = dm.group(1) == "=>"
    start = dm.end()
    i = start
    depth = 0 if arrow else 1
    while i < len(dart_src):
        c = dart_src[i]
        skipped = _skip_string(dart_src, i)
        if skipped is not None:
            i = skipped
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if not arrow and c == "}" and depth == 0:
                return dart_src[start:i]
        elif arrow and c == ";" and depth == 0:
            return dart_src[start:i]
        i += 1
    return None


def fingerprint_text(raw_value: str, dart_src: str) -> str:
    """The text whose hash is this name's fingerprint.

    A tear-off resolves to its target method's body (prefixed with the
    method's own name, so renaming the tear-off target is itself a visible
    change); anything else is the raw value text, stripped. An unresolvable
    tear-off is flagged rather than silently hashing the one-line reference
    (which would make the gate blind to exactly the case it exists for).
    """
    value = raw_value.strip()
    tm = TEAROFF_RE.match(value)
    if tm:
        target = tm.group(1)
        body = resolve_method_body(dart_src, target)
        if body is None:
            return f"UNRESOLVED_TEAROFF:{target}"
        return f"TEAROFF:{target}\n{body}"
    return value


def extract_ts_registered_names(ts_src: str) -> set[str]:
    m = REGISTER_FN_RE.search(ts_src)
    if not m:
        raise ExtractionError(
            "could not locate registerExtraStdFunctions(...): void { — the "
            "extraction regex has stopped matching ts/engine/src/engine_setup.ts"
        )
    depth = 1
    i = m.end()
    while depth > 0:
        if i >= len(ts_src):
            raise ExtractionError("registerExtraStdFunctions's body never closed")
        if ts_src[i] == "{":
            depth += 1
        elif ts_src[i] == "}":
            depth -= 1
        i += 1
    return set(CALL_RE.findall(ts_src[m.end():i]))


def compute_snapshot(dart_src: str, ts_src: str, min_intersection: int = MIN_INTERSECTION) -> dict[str, str]:
    """name -> sha256 hex digest, for every name BOTH files register."""
    dart_entries = extract_dart_dispatch_entries(dart_src)
    ts_names = extract_ts_registered_names(ts_src)
    inter = sorted(set(dart_entries) & ts_names)
    if len(inter) < min_intersection:
        raise ExtractionError(
            f"the TS-override / Dart-dispatch intersection is only "
            f"{len(inter)} names (floor: {min_intersection}) — one of the two "
            "extractions has stopped matching; fix it before trusting the "
            "drift check"
        )
    out: dict[str, str] = {}
    for name in inter:
        text = fingerprint_text(dart_entries[name], dart_src)
        out[name] = hashlib.sha256(text.encode("utf-8")).hexdigest()
    return out


def check(dart_src: str, ts_src: str, snapshot: dict[str, str],
          min_intersection: int = MIN_INTERSECTION) -> list[str]:
    """Returns a list of error messages; empty means the gate passes."""
    current = compute_snapshot(dart_src, ts_src, min_intersection)
    errors: list[str] = []

    new_names = sorted(set(current) - set(snapshot))
    if new_names:
        errors.append(
            f"{new_names} now shadow a dart/engine/lib/engine_std.dart dispatch "
            "entry but have no snapshot entry yet. Run "
            "`python3 tools/check_ts_engine_overrides_sync.py --update` and "
            "commit the result, after confirming the TS override at "
            "ts/engine/src/engine_setup.ts still matches the Dart entry's "
            "behaviour."
        )
    stale_names = sorted(set(snapshot) - set(current))
    if stale_names:
        errors.append(
            f"{stale_names} have a snapshot entry but no longer shadow anything "
            "(the TS override was removed, or the Dart entry was removed/"
            "renamed) — run --update to drop the stale entries."
        )
    changed = sorted(
        n for n in current
        if n in snapshot and snapshot[n] != current[n]
    )
    if changed:
        errors.append(
            f"{changed}: dart/engine/lib/engine_std.dart's dispatch entry "
            "changed shape since the snapshot was last refreshed. Review "
            "ts/engine/src/engine_setup.ts's override for each name — it may "
            "need the same fix — then run "
            "`python3 tools/check_ts_engine_overrides_sync.py --update` and "
            "commit the refreshed snapshot (issue #732)."
        )
    return errors


# ── Self-test: a gate nobody has watched fail is not a gate ────────────────


def _dart_fixture(entries_block: str, helpers_block: str = "") -> str:
    return (
        "class BallEngine {\n"
        "  Map<String, FutureOr<Object?> Function(Object?)> _buildStdDispatch() {\n"
        "    return {\n"
        f"{entries_block}"
        "    };\n"
        "  }\n"
        f"{helpers_block}"
        "}\n"
    )


def _ts_fixture(names: list[str]) -> str:
    calls = "\n".join(f"  _r('{n}', (i: any) => null);" for n in names)
    return (
        "function registerExtraStdFunctions(stdHandler: StdHandler, engine: any): void {\n"
        "  const _r = stdHandler.register.bind(stdHandler);\n"
        f"{calls}\n"
        "}\n"
    )


def _run_self_test() -> int:
    failures: list[str] = []

    dart_v1 = _dart_fixture(
        "      'add': _stdAdd,\n"
        "      'concat': (i) => 'left:right',\n",
        "\n  FutureOr<Object?> _stdAdd(Object? i) {\n"
        "    return i;\n"
        "  }\n",
    )
    dart_v2_changed_inline = _dart_fixture(
        "      'add': _stdAdd,\n"
        "      'concat': (i) => 'left-right',\n",  # behaviour changed
        "\n  FutureOr<Object?> _stdAdd(Object? i) {\n"
        "    return i;\n"
        "  }\n",
    )
    dart_v3_changed_tearoff_target = _dart_fixture(
        "      'add': _stdAdd,\n"
        "      'concat': (i) => 'left:right',\n",
        "\n  FutureOr<Object?> _stdAdd(Object? i) {\n"
        "    return _stdBinary(i, (a, b) => a + b);\n"  # tear-off target changed
        "  }\n",
    )
    dart_unresolved = _dart_fixture("      'add': _stdMissing,\n")

    ts_src = _ts_fixture(["add", "concat", "unshadowed_only_in_ts"])

    try:
        snap1 = compute_snapshot(dart_v1, ts_src, min_intersection=1)
    except ExtractionError as e:
        failures.append(f"compute_snapshot on a clean fixture should not raise: {e}")
        snap1 = {}

    if "unshadowed_only_in_ts" in snap1:
        failures.append("a name only TS registers must not appear in the intersection")
    if set(snap1) != {"add", "concat"}:
        failures.append(f"expected intersection {{'add', 'concat'}}, got {set(snap1)}")

    # 1. Unchanged Dart source against its own snapshot -> passes.
    errs = check(dart_v1, ts_src, snap1, min_intersection=1)
    if errs:
        failures.append(f"an unchanged Dart source should pass, got: {errs}")

    # 2. An inline closure's behaviour changed -> caught, naming 'concat'.
    errs = check(dart_v2_changed_inline, ts_src, snap1, min_intersection=1)
    if not any("concat" in e and "changed shape" in e for e in errs):
        failures.append(f"a changed inline closure should be reported, got: {errs}")
    if any("'add'" in e for e in errs if "changed shape" in e):
        failures.append("'add' did not change and must not be reported")

    # 3. A TEAR-OFF's TARGET method changed -> caught, naming 'add' (proves
    #    tear-off resolution, not just literal map-entry text, drives the hash).
    errs = check(dart_v3_changed_tearoff_target, ts_src, snap1, min_intersection=1)
    if not any("add" in e and "changed shape" in e for e in errs):
        failures.append(
            f"a changed TEAR-OFF TARGET should be reported even though the "
            f"one-line map entry naming it is unchanged, got: {errs}"
        )

    # 4. A brand-new shadowed name with no snapshot entry -> caught.
    ts_src_extra = _ts_fixture(["add", "concat", "new_shadow"])
    dart_with_new_shadow = _dart_fixture(
        "      'add': _stdAdd,\n"
        "      'concat': (i) => 'left:right',\n"
        "      'new_shadow': (i) => 1,\n",
        "\n  FutureOr<Object?> _stdAdd(Object? i) {\n"
        "    return i;\n"
        "  }\n",
    )
    errs = check(dart_with_new_shadow, ts_src_extra, snap1, min_intersection=1)
    if not any("new_shadow" in e and "no snapshot entry" in e for e in errs):
        failures.append(f"a new shadowed name should be reported, got: {errs}")

    # 5. A stale snapshot entry (name no longer shadows anything) -> caught.
    stale_snapshot = dict(snap1)
    stale_snapshot["long_gone"] = "deadbeef"
    errs = check(dart_v1, ts_src, stale_snapshot, min_intersection=1)
    if not any("long_gone" in e and "no longer shadow" in e for e in errs):
        failures.append(f"a stale snapshot entry should be reported, got: {errs}")

    # 6. An unresolvable tear-off must be a visible, distinct fingerprint
    #    (never silently equal to some other unresolved name), so a real
    #    drift there is still seen as a change rather than vanishing.
    snap_unresolved = compute_snapshot(dart_unresolved, _ts_fixture(["add"]), min_intersection=1)
    if snap_unresolved.get("add") is None:
        failures.append("an unresolved tear-off must still get a fingerprint")

    # 7. Positive floor: a below-floor intersection must fail loud.
    try:
        compute_snapshot(dart_v1, ts_src, min_intersection=99)
        failures.append("a below-floor intersection should raise ExtractionError")
    except ExtractionError:
        pass

    # 8. A vanished Dart dispatch header must fail loud, not pass vacuously.
    try:
        compute_snapshot("class Nothing {}\n", ts_src, min_intersection=1)
        failures.append("a missing _buildStdDispatch() should raise ExtractionError")
    except ExtractionError:
        pass

    # 9. A vanished TS registration function must fail loud too.
    try:
        compute_snapshot(dart_v1, "const x = 1;\n", min_intersection=1)
        failures.append("a missing registerExtraStdFunctions should raise ExtractionError")
    except ExtractionError:
        pass

    if failures:
        for f in failures:
            sys.stderr.write(f"SELF-TEST FAILURE: {f}\n")
        return 1
    print("check_ts_engine_overrides_sync.py: self-test passed (9 cases)")
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=str(ROOT), help="repo root (default: this script's repo)")
    ap.add_argument("--update", action="store_true", help="regenerate the committed snapshot")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv)

    if args.self_test:
        return _run_self_test()

    root = Path(args.root)
    dart_path = root / "dart" / "engine" / "lib" / "engine_std.dart"
    ts_path = root / "ts" / "engine" / "src" / "engine_setup.ts"
    if not dart_path.is_file():
        raise SystemExit(f"missing {dart_path}")
    if not ts_path.is_file():
        raise SystemExit(f"missing {ts_path}")

    dart_src = dart_path.read_text(encoding="utf-8")
    ts_src = ts_path.read_text(encoding="utf-8")

    if args.update:
        try:
            snapshot = compute_snapshot(dart_src, ts_src)
        except ExtractionError as e:
            raise SystemExit(f"ERROR: {e}")
        SNAPSHOT_PATH.write_text(
            json.dumps(snapshot, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        print(f"wrote {len(snapshot)} fingerprints to {SNAPSHOT_PATH}")
        return 0

    if not SNAPSHOT_PATH.is_file():
        raise SystemExit(
            f"missing {SNAPSHOT_PATH} — run with --update to create it"
        )
    snapshot = json.loads(SNAPSHOT_PATH.read_text(encoding="utf-8"))

    try:
        errors = check(dart_src, ts_src, snapshot)
    except ExtractionError as e:
        raise SystemExit(f"ERROR: {e}")

    if errors:
        for e in errors:
            sys.stderr.write(f"ERROR: {e}\n")
        return 1

    print(
        "check_ts_engine_overrides_sync.py: every name "
        "ts/engine/src/engine_setup.ts shadows in "
        "dart/engine/lib/engine_std.dart's dispatch still fingerprints "
        f"identically to the committed snapshot ({len(snapshot)} names)."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
