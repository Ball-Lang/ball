"""Declared-drift guard for the Python compiler's base-module dispatch (#743).

WHY THIS EXISTS
---------------
``python/compiler/ball_compiler/compiler.py`` implements base functions by
HARDCODED NAME — ``if fn == "sink_write": …``, ``if fn in table_2: …`` — and
nothing ever compared those names against the canonical declarations in
``dart/shared/lib/std*.dart``. So the dispatcher grew an arm for
``string_from_char_codes`` (plural): no builder declares it, no encoder in the
repo emits it, the Dart reference engine does not dispatch it, and no fixture
can reach it. It was invisible to this package's pytest suite, to the
conformance corpus and to ``check_encoder_completeness.dart`` alike — the exact
"implemented by hardcoded name but never declared" drift that
``dart/shared/test/std_routed_declarations_test.dart`` catches on the Dart side
(issue #505) and ``cpp/test/check_declared_base_functions.py`` on the C++ side
(issue #607). Python had no equivalent; #743 adds one.

The canonical inventory is ``tests/conformance/std_coverage.json``, NOT
``dart/shared/std.json``: ``gen_std.dart`` serialises only ``buildStdModule()``,
so ``std.json`` contains no ``std_collections``/``std_convert`` at all, while
``gen_std_coverage.dart`` calls ALL EIGHT canonical builders. Both files are
regenerated and diffed by ci.yml's ``Ball Artifact Freshness`` job, so neither
can drift from the builders — and :func:`test_inventory_agrees_with_std_json`
pins the two against each other so a stale artifact cannot mute this gate.

WHAT THIS ASSERTS
-----------------
1. Every dispatch site in the compiler that tests a base-function NAME belongs
   to a dispatcher this file maps to a module, or is explicitly excluded with a
   reason — so a new dispatcher cannot appear unnoticed (the extraction is
   derived from the source, never from a hand-listed name set).
2. Every name a module-scoped dispatcher implements is DECLARED for that module
   by the canonical builders, or is named in
   ``declared_base_functions_known_gaps.txt`` next to this file.
3. That known-gaps file is a RATCHET, not a dumping ground: an entry that is now
   declared, or that the compiler no longer implements, fails. The debt can only
   shrink.
4. Positive floor: the extraction found a realistic number of names, and every
   mapped dispatcher yielded at least one. An AST walk that quietly stops
   matching would otherwise make every check above pass vacuously.

The negative controls at the bottom prove the gate bites, on fixture sources
rather than on the real compiler.
"""

from __future__ import annotations

import ast
import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]
COMPILER_SRC = ROOT / "python" / "compiler" / "ball_compiler" / "compiler.py"
COVERAGE_JSON = ROOT / "tests" / "conformance" / "std_coverage.json"
STD_JSON = ROOT / "dart" / "shared" / "std.json"
KNOWN_GAPS = Path(__file__).resolve().parent / "declared_base_functions_known_gaps.txt"

# Compiler method -> the base modules whose declarations its `fn` names may
# belong to, PRIMARY FIRST (the primary is what a known-gaps key names).
#
# `base_expr` is the fall-through: it delegates a handful of modules to their own
# dispatchers and then serves EVERY remaining universal module from one body, so
# `std_io.print_error` and `std.print` both land in it. Its module tuple is
# therefore DERIVED — every module the canonical inventory knows, minus the ones
# its own source delegates away — rather than listed here where it would rot.
SINGLE_MODULE_DISPATCHERS = {
    "run": "std",  # statement-shaped std calls: if/for/while/try/assign/…
    "value": "std",  # the same set, in expression position
    "emit_map_element": "std",  # spread / collection_if / collection_for
    "base_flow_expr": "std",  # return / break / continue / throw / rethrow
    "collections_expr": "std_collections",
    "convert_expr": "std_convert",
}
FALLTHROUGH_DISPATCHER = "base_expr"
FALLTHROUGH_PRIMARY_MODULE = "std"

# Methods whose `fn` is NOT a base-module function name, with the reason. They
# are excluded from the module check but still have to EXIST: assertion 1 fails
# if one is renamed away, so the exclusion cannot rot into a blind spot.
NOT_MODULE_SCOPED = {
    # Method-style calls carry an EMPTY module and a `self` field; `toString`,
    # `hashCode`, `noSuchMethod` and `identical` are Dart-SDK members, not std
    # base functions, so there is no module to compare them against. The same
    # carve-out `cpp/test/check_declared_base_functions.py` makes for
    # `compile_method_call`.
    "value_call": "module-less Dart-SDK method surface",
    # `dart.math` / `dart.io` are STUB modules no builder declares by design;
    # `pow`/`atan2` here are Dart library functions, not std base functions.
    "stub_call": "dart.math / dart.io stub bridge",
}

# Positive floor on the per-dispatcher name count summed across the mapped
# dispatchers. The current measurement is not frozen in prose (a number in a
# comment rots); `test_report` prints it on every run. The floor sits well below
# it so ordinary churn never trips it, but an AST walk that stops matching does.
MIN_TOTAL_NAMES = 150


# ── extraction ──────────────────────────────────────────────────────────────


def _string_keys(node: ast.AST) -> list[str]:
    """The string constants of a set/list/tuple display, or a dict's keys."""
    if isinstance(node, ast.Dict):
        return [k.value for k in node.keys if isinstance(k, ast.Constant) and isinstance(k.value, str)]
    if isinstance(node, (ast.Set, ast.List, ast.Tuple)):
        return [e.value for e in node.elts if isinstance(e, ast.Constant) and isinstance(e.value, str)]
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id in ("frozenset", "set"):
        if node.args:
            return _string_keys(node.args[0])
    return []


def _name_bindings(scope: ast.AST) -> dict[str, list[str]]:
    """Names bound to a literal dict/set/list/tuple anywhere inside [scope]."""
    out: dict[str, list[str]] = {}
    for node in ast.walk(scope):
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            keys = _string_keys(node.value)
            if keys:
                out[node.targets[0].id] = keys
    return out


def dispatched_names(source: str) -> dict[str, set[str]]:
    """Function name -> the base-function names its body dispatches on.

    A dispatch site is any of:

    * ``fn == "name"`` / ``fn != "name"``
    * ``fn in ("a", "b")`` (or a set/list display)
    * ``fn in TABLE`` / ``TABLE[fn]`` where ``TABLE`` is a dict or set literal
      bound in the same function or at module level.

    Only functions with at least one such site appear in the result, so the set
    of dispatchers is DERIVED from the compiler source rather than listed here.
    """
    tree = ast.parse(source)
    module_bindings: dict[str, list[str]] = {}
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            keys = _string_keys(node.value)
            if keys:
                module_bindings[node.targets[0].id] = keys

    out: dict[str, set[str]] = {}
    for fnode in [n for n in ast.walk(tree) if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))]:
        local = _name_bindings(fnode)

        def resolve(ident: str) -> list[str]:
            return local.get(ident, module_bindings.get(ident, []))

        names: set[str] = set()
        for node in ast.walk(fnode):
            if isinstance(node, ast.Compare) and isinstance(node.left, ast.Name) and node.left.id == "fn":
                for op, comp in zip(node.ops, node.comparators):
                    if isinstance(op, (ast.Eq, ast.NotEq)):
                        if isinstance(comp, ast.Constant) and isinstance(comp.value, str):
                            names.add(comp.value)
                    elif isinstance(op, (ast.In, ast.NotIn)):
                        if isinstance(comp, ast.Name):
                            names.update(resolve(comp.id))
                        else:
                            names.update(_string_keys(comp))
            if (
                isinstance(node, ast.Subscript)
                and isinstance(node.value, ast.Name)
                and isinstance(node.slice, ast.Name)
                and node.slice.id == "fn"
            ):
                names.update(resolve(node.value.id))
        if names:
            out[fnode.name] = names
    return out


def delegated_modules(source: str, dispatcher: str) -> set[str]:
    """The module names [dispatcher] hands off to another dispatcher.

    Read as every ``mod == "<name>"`` comparison inside its body — the shape
    ``base_expr`` uses to peel `std_collections`/`std_convert`/`ball_proto` off
    before serving everything else itself.
    """
    tree = ast.parse(source)
    out: set[str] = set()
    for fnode in [n for n in ast.walk(tree) if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))]:
        if fnode.name != dispatcher:
            continue
        for node in ast.walk(fnode):
            if isinstance(node, ast.Compare) and isinstance(node.left, ast.Name) and node.left.id == "mod":
                for op, comp in zip(node.ops, node.comparators):
                    if isinstance(op, ast.Eq) and isinstance(comp, ast.Constant) and isinstance(comp.value, str):
                        out.add(comp.value)
    return out


def dispatcher_modules(source: str, declared: dict[str, set[str]]) -> dict[str, tuple[str, ...]]:
    """The full dispatcher -> modules map, with the fall-through's set derived."""
    out: dict[str, tuple[str, ...]] = {k: (v,) for k, v in SINGLE_MODULE_DISPATCHERS.items()}
    delegated = delegated_modules(source, FALLTHROUGH_DISPATCHER)
    rest = sorted(set(declared) - delegated - {FALLTHROUGH_PRIMARY_MODULE})
    out[FALLTHROUGH_DISPATCHER] = (FALLTHROUGH_PRIMARY_MODULE,) + tuple(rest)
    return out


def declared_names(coverage_path: Path) -> dict[str, set[str]]:
    """module -> declared base-function names, from the canonical inventory."""
    coverage = json.loads(coverage_path.read_text(encoding="utf-8"))
    out: dict[str, set[str]] = {}
    for entry in coverage["functions"]:
        out.setdefault(entry["module"], set()).add(entry["name"])
    return out


def read_known_gaps(path: Path) -> set[str]:
    entries: set[str] = set()
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if line:
            entries.add(line)
    return entries


def check(
    source: str,
    declared: dict[str, set[str]],
    gaps: set[str],
    dispatchers: dict[str, tuple[str, ...]],
    excluded: dict[str, str],
    min_total: int,
) -> list[str]:
    """Returns a list of error messages; empty means the gate passes."""
    errors: list[str] = []
    dispatched = dispatched_names(source)

    # -- 4. Positive floor FIRST: a vacuous extraction must never read as a
    # clean bill of health.
    for name in sorted(dispatchers):
        if not dispatched.get(name):
            errors.append(
                "dispatcher %s() yielded NO base-function names - it was renamed, "
                "removed, or the AST walk stopped matching. Fix the extraction "
                "(or this table) rather than deleting the gate." % name
            )
    for name in sorted(excluded):
        if name not in dispatched:
            errors.append(
                "excluded dispatcher %s() no longer dispatches on `fn` - it was "
                "renamed or removed. Drop its NOT_MODULE_SCOPED entry (or fix the "
                "name) so the exclusion cannot rot into a blind spot." % name
            )
    total = sum(len(dispatched.get(name, set())) for name in dispatchers)
    if total < min_total:
        errors.append(
            "extracted only %d dispatched base-function names across the mapped "
            "dispatchers (floor: %d). The extraction has stopped matching; fix it "
            "before trusting the drift check." % (total, min_total)
        )
    if errors:
        return errors

    # -- 1. Every dispatch site is accounted for.
    unmapped = sorted(set(dispatched) - set(dispatchers) - set(excluded))
    if unmapped:
        errors.append(
            "UNMAPPED DISPATCHER(S) - these compiler functions test base-function "
            "names but this gate does not know which module they belong to:\n  "
            + "\n  ".join(unmapped)
            + "\nAdd each to SINGLE_MODULE_DISPATCHERS with its base module, or to "
            "NOT_MODULE_SCOPED with the reason its `fn` is not a base-function "
            "name."
        )

    # -- 2. Dispatched but not declared.
    undeclared: list[str] = []
    live_gaps: set[str] = set()
    for dispatcher, modules in sorted(dispatchers.items()):
        for name in sorted(dispatched[dispatcher]):
            if any(name in declared.get(module, set()) for module in modules):
                continue
            key = "%s.%s" % (modules[0], name)
            if key in gaps:
                live_gaps.add(key)
            else:
                undeclared.append("%s (%s)" % (key, dispatcher))
    if undeclared:
        errors.append(
            "DISPATCHED BUT NOT DECLARED - python/compiler/ball_compiler/"
            "compiler.py dispatches these base functions by hardcoded name, but no "
            "dart/shared/lib/std*.dart builder declares them, so they are absent "
            "from tests/conformance/std_coverage.json, unreachable by every "
            "encoder, and implemented by no engine:\n  "
            + "\n  ".join(sorted(set(undeclared)))
            + "\nEither delete the dispatch arm, or DECLARE the function in the "
            "canonical builder and regenerate the inventory (`cd dart/shared && "
            "dart run bin/gen_std.dart` plus `cd dart/encoder && dart run "
            "bin/gen_std_coverage.dart`). Adding a line to "
            "python/compiler/tests/declared_base_functions_known_gaps.txt is NOT "
            "an option for a new name - that file is a frozen ratchet (issue "
            "#743)."
        )

    # -- 3. The known-gaps file is a ratchet.
    stale = sorted(gaps - live_gaps)
    if stale:
        errors.append(
            "STALE KNOWN GAPS - these entries are no longer live drift (the "
            "function is now declared, or the compiler no longer dispatches it). "
            "Delete them so the debt can only shrink:\n  " + "\n  ".join(stale)
        )
    return errors


def _check_real_tree(min_total: int = MIN_TOTAL_NAMES) -> list[str]:
    source = COMPILER_SRC.read_text(encoding="utf-8")
    declared = declared_names(COVERAGE_JSON)
    return check(
        source,
        declared,
        read_known_gaps(KNOWN_GAPS),
        dispatcher_modules(source, declared),
        NOT_MODULE_SCOPED,
        min_total,
    )


# ── the gate ────────────────────────────────────────────────────────────────


def test_every_dispatched_base_function_is_declared():
    errors = _check_real_tree()
    assert not errors, "\n\n".join(errors)


def test_inventory_agrees_with_std_json():
    """`std_coverage.json` and `std.json` must describe the same `std` module.

    This gate reads the coverage inventory (the only one covering all eight
    universal modules). Pinning its `std` half against `dart/shared/std.json`
    means a stale regeneration of either artifact fails here instead of silently
    shrinking the declared set this gate measures against.
    """
    coverage_std = declared_names(COVERAGE_JSON).get("std", set())
    std_json = {f["name"] for f in json.loads(STD_JSON.read_text(encoding="utf-8"))["functions"]}
    assert len(std_json) > 100, "std.json declares only %d functions - it is stale or truncated" % len(std_json)
    assert coverage_std == std_json, (
        "tests/conformance/std_coverage.json and dart/shared/std.json disagree about the "
        "`std` module: only in coverage=%s, only in std.json=%s. Regenerate both "
        "(`cd dart/shared && dart run bin/gen_std.dart`; `cd dart/encoder && dart run "
        "bin/gen_std_coverage.dart`)." % (sorted(coverage_std - std_json), sorted(std_json - coverage_std))
    )


def test_fallthrough_modules_are_derived():
    """The fall-through dispatcher's module set must come from real delegations.

    If the `mod == "…"` extraction stops matching, `base_expr` would be measured
    against EVERY declared module at once and a real phantom could hide behind a
    same-named declaration in an unrelated module.
    """
    source = COMPILER_SRC.read_text(encoding="utf-8")
    delegated = delegated_modules(source, FALLTHROUGH_DISPATCHER)
    assert len(delegated) >= 2, (
        "%s() delegates no module at all (found: %s) - the `mod == ...` extraction "
        "has stopped matching." % (FALLTHROUGH_DISPATCHER, sorted(delegated))
    )
    modules = dispatcher_modules(source, declared_names(COVERAGE_JSON))[FALLTHROUGH_DISPATCHER]
    assert modules[0] == FALLTHROUGH_PRIMARY_MODULE
    for peeled in delegated:
        assert peeled not in modules, "%s is delegated away but still measured against" % peeled


def test_report(capsys):
    """Positive floor, reported: the measurement this gate rests on."""
    source = COMPILER_SRC.read_text(encoding="utf-8")
    dispatched = dispatched_names(source)
    mapped = dispatcher_modules(source, declared_names(COVERAGE_JSON))
    total = sum(len(dispatched.get(name, set())) for name in mapped)
    assert total >= MIN_TOTAL_NAMES
    with capsys.disabled():
        print(
            "\ntest_declared_base_functions: %d dispatched names across %d mapped "
            "dispatchers (floor %d), %d known gaps."
            % (total, len(mapped), MIN_TOTAL_NAMES, len(read_known_gaps(KNOWN_GAPS)))
        )


def test_string_from_char_code_singular_is_still_dispatched():
    """The DECLARED singular must survive the plural's removal.

    `String.fromCharCode(n)` and `StringBuffer.writeCharCode(n)` (#630) both
    encode to `std.string_from_char_code`, which fixtures 140_caesar_cipher and
    466_string_sink execute. Deleting the phantom plural must not take the real
    singular with it.
    """
    dispatched = dispatched_names(COMPILER_SRC.read_text(encoding="utf-8"))
    assert "string_from_char_code" in dispatched["base_expr"]


# ── negative controls: prove the gate bites ─────────────────────────────────

_FAKE_SOURCE = '''\
class Compiler:
    def base_expr(self, call):
        mod, fn = call.get("module", ""), call.get("function", "")
        if fn == "add":
            return "a + b"
        if fn in ("is", "is_not"):
            return "t"
        table = {"negate": "negate"}
        if fn in table:
            return table[fn]
%s
        return self.fail("unsupported")

    def collections_expr(self, fn, f):
        if fn == "list_push":
            return "push"
        return self.fail("unsupported")

    def value_call(self, call):
        fn = call.get("function", "")
        if fn == "toString":
            return "str"
        return ""
'''

_FAKE_DECLARED = {
    "std": {"add", "is", "is_not", "negate"},
    "std_collections": {"list_push"},
}
_FAKE_DISPATCHERS = {"base_expr": ("std", "std_io"), "collections_expr": ("std_collections",)}
_FAKE_EXCLUDED = {"value_call": "module-less Dart-SDK method surface"}


def _run_fake(extra: str = "", gaps: set[str] | None = None, min_total: int = 2, **kw) -> list[str]:
    return check(
        kw.get("source", _FAKE_SOURCE % extra),
        kw.get("declared", _FAKE_DECLARED),
        set() if gaps is None else gaps,
        kw.get("dispatchers", _FAKE_DISPATCHERS),
        kw.get("excluded", _FAKE_EXCLUDED),
        min_total,
    )


def test_control_clean_tree_passes():
    assert _run_fake() == []


def test_control_new_undeclared_name_fails():
    errors = _run_fake('        if fn == "string_from_char_codes":\n            return "x"')
    assert any("DISPATCHED BUT NOT DECLARED" in e for e in errors)
    assert any("std.string_from_char_codes" in e for e in errors)


def test_control_undeclared_name_inside_a_table_fails():
    """A phantom hidden in a dict literal must be found, not only an `fn ==` arm."""
    src = (_FAKE_SOURCE % "").replace('{"negate": "negate"}', '{"negate": "negate", "phantom": "phantom"}')
    errors = _run_fake(source=src)
    assert any("std.phantom" in e for e in errors)


def test_control_a_secondary_module_declaration_counts():
    """A fall-through dispatcher's name may be declared by any module it serves."""
    declared = dict(_FAKE_DECLARED)
    declared["std_io"] = {"print_error"}
    errors = _run_fake('        if fn == "print_error":\n            return "e"', declared=declared)
    assert errors == []


def test_control_a_delegated_module_declaration_does_not_count():
    """…but a module the dispatcher delegates away must not silence a phantom."""
    errors = _run_fake('        if fn == "list_push":\n            return "p"')
    assert any("std.list_push" in e for e in errors)


def test_control_known_gap_silences_only_that_name():
    assert _run_fake('        if fn == "ghost":\n            return "x"', gaps={"std.ghost"}) == []


def test_control_stale_gap_fails():
    errors = _run_fake(gaps={"std.gone"})
    assert any("STALE KNOWN GAPS" in e for e in errors)


def test_control_gap_for_a_now_declared_function_fails():
    errors = _run_fake(gaps={"std.add"})
    assert any("STALE KNOWN GAPS" in e for e in errors)


def test_control_positive_floor_bites():
    errors = _run_fake(min_total=1000)
    assert any("extracted only" in e for e in errors)


def test_control_vanished_dispatcher_fails():
    errors = _run_fake(dispatchers={"renamed_expr": ("std",)})
    assert any("yielded NO base-function names" in e for e in errors)


def test_control_vanished_exclusion_fails():
    errors = _run_fake(excluded={"renamed_call": "gone"})
    assert any("no longer dispatches on `fn`" in e for e in errors)


def test_control_unmapped_dispatcher_fails():
    errors = _run_fake(excluded={})
    assert any("UNMAPPED DISPATCHER" in e for e in errors)


@pytest.mark.parametrize("path", [COMPILER_SRC, COVERAGE_JSON, STD_JSON, KNOWN_GAPS])
def test_control_inputs_exist(path):
    assert path.is_file(), "%s is missing - the gate cannot run" % path
