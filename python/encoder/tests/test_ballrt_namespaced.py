"""The NAMESPACED runtime helpers ``ballrt.<ns>.<name>(...)`` (issue #690).

``python/compiler`` does not put every base call under a flat ``ballrt.<name>``.
Three modules are emitted through a namespace object instead
(``python/runtime/ballrt/__init__.py``):

* ``std_collections`` -> ``ballrt.col.<name>`` (``compiler.collections_expr``),
* ``std_convert``     -> ``ballrt.cvt.<name>`` (``compiler.convert_expr``),
* ``ball_proto``      -> ``ballrt.proto.<name>`` (``compiler.base_expr``).

``encoder.encode_call`` only recognised the flat ``ballrt.<name>`` shape, so a
namespaced call fell through to the generic "any other method call" arm and the
whole fixture died with ``method call .list_push(...) is not supported``. That
was the single largest remaining blocker on the ``python-roundtrip`` row: 62 of
the corpus's fixtures emit at least one ``ballrt.col.*`` call, and for 27 of them
it is the ONLY thing standing between the fixture and a clean round trip.

The guards here are the same two kinds ``test_ballrt_inverse.py`` uses for the
flat table, derived the same way — from the sources of truth, never from a list
kept beside the table:

* **Closed-set membership.** ``python/runtime``'s namespace object crossed with
  that module's own Ball declaration (``dart/shared/lib/std_collections.dart`` /
  ``std_convert.dart`` for the two builder modules, ``dart/shared/ball_proto.json``
  for ``ball_proto``). A helper in both MUST have an inverse; a helper the
  runtime exposes but no module declares MUST NOT (there is no base function to
  encode it as).
* **Field shape.** Each inverse's argument fields must be real fields of the
  input type that module DECLARES for that function, in declaration order — so a
  typo, a wrong-type mapping, or an invented field name fails here rather than
  reaching the Dart reference engine as a call it silently reads as null.

plus whole-fixture round trips (Ball -> Python -> Ball -> Python -> run,
byte-compared against the fixture's own golden) for one fixture per shape.
"""

from __future__ import annotations

import importlib.util
import inspect
import io
import json
import re
from contextlib import redirect_stdout
from pathlib import Path

import ballrt
import pytest
from ball_compiler.compiler import compile_program
from ball_encoder import ballrt_calls as rt
from ball_encoder.encoder import EncodeError, encode

ROOT = Path(__file__).resolve().parents[3]
FIXTURES = ROOT / "tests" / "conformance"
STD_COLLECTIONS_DART = ROOT / "dart" / "shared" / "lib" / "std_collections.dart"
STD_CONVERT_DART = ROOT / "dart" / "shared" / "lib" / "std_convert.dart"
BALL_PROTO_JSON = ROOT / "dart" / "shared" / "ball_proto.json"


# ── The Ball declarations, read from the builders ────────────────────────────
# `std.json` is generated for `std` only; `std_collections` / `std_convert`
# declare their functions and their input TYPES in their own Dart builders, so
# those files are the inventory. Two shapes are read: `_fn('<name>',
# '<InputType>', …)` and `_type('<InputType>', [_…Field('<field>', n), …])`.

_FN_DECL = re.compile(r"_fn\(\s*'([a-z_0-9]+)'\s*,\s*'([A-Za-z0-9]*)'", re.S)
_TYPE_DECL = re.compile(r"_type\(\s*'([A-Za-z0-9]+)'\s*,\s*\[(.*?)\]\s*\)", re.S)
_FIELD_DECL = re.compile(r"_\w*[Ff]ield\(\s*'([a-z_0-9]+)'")


def _declared(builder: Path) -> tuple[dict[str, str], dict[str, list[str]]]:
    """``({function: input type}, {input type: [field, …]})`` for one builder."""
    src = builder.read_text(encoding="utf-8")
    types = {m.group(1): _FIELD_DECL.findall(m.group(2)) for m in _TYPE_DECL.finditer(src)}
    functions = {m.group(1): m.group(2) for m in _FN_DECL.finditer(src)}
    return functions, types


def _namespace_functions(namespace: object) -> set[str]:
    """Every public function the runtime exposes as ``ballrt.<ns>.<name>``.

    ``inspect.isfunction`` and not ``callable``: the collections namespace also
    exports the ``BallSet`` CLASS, which is a value type, not a base-call
    helper."""
    return {
        name for name in dir(namespace)
        if not name.startswith("_") and inspect.isfunction(getattr(namespace, name))
    }


def _is_ordered_subsequence(fields: tuple[str, ...], declared: list[str]) -> bool:
    it = iter(declared)
    return all(f in it for f in fields)


# ── Closed-set membership ────────────────────────────────────────────────────

@pytest.mark.parametrize(
    "namespace_key, builder, floor",
    [("col", STD_COLLECTIONS_DART, 40), ("cvt", STD_CONVERT_DART, 6)],
)
def test_every_declared_namespaced_helper_has_an_inverse(
    namespace_key: str, builder: Path, floor: int
) -> None:
    """A closed set: the runtime exposes ``ballrt.<ns>.<f>`` AND the module
    declares base function ``<f>`` => the encoder must be able to read it back.

    Derived from the runtime module crossed with that module's Ball builder, so
    it closes over what the compiler CAN emit rather than over what today's
    fixtures happen to use."""
    module_name, table = rt.NAMESPACES[namespace_key]
    declared, _ = _declared(builder)
    exposed = _namespace_functions(getattr(ballrt, namespace_key))
    mappable = sorted(exposed & set(declared))
    assert len(mappable) >= floor, (
        f"only {len(mappable)} helpers found for ballrt.{namespace_key} — the "
        "derivation broke, it is not that the runtime shrank"
    )
    missing = [name for name in mappable if name not in table]
    assert not missing, (
        f"these {module_name} base functions have a ballrt.{namespace_key} helper "
        f"but no inverse in ball_encoder/ballrt_calls.py: {missing}"
    )


@pytest.mark.parametrize(
    "namespace_key, builder", [("col", STD_COLLECTIONS_DART), ("cvt", STD_CONVERT_DART)]
)
def test_namespaced_inverse_fields_are_declared_input_fields(
    namespace_key: str, builder: Path
) -> None:
    """Every argument field an inverse names must be a field of the input type
    the module DECLARES for that function, in declaration order.

    An invented field name is not a loud failure anywhere downstream — the
    engine simply reads it as absent — so the declaration is what pins it."""
    module_name, table = rt.NAMESPACES[namespace_key]
    declared, types = _declared(builder)
    wrong: dict[str, str] = {}
    for helper, fields in sorted(table.items()):
        input_type = declared.get(helper)
        if input_type is None:
            wrong[helper] = f"{module_name} declares no base function of that name"
            continue
        declared_fields = types.get(input_type)
        if declared_fields is None:
            wrong[helper] = f"undeclared input type {input_type!r}"
            continue
        if not _is_ordered_subsequence(fields, declared_fields):
            wrong[helper] = (
                f"fields {fields} are not an ordered subset of "
                f"{input_type}{declared_fields}"
            )
    assert not wrong, wrong


def test_a_runtime_only_helper_has_no_inverse() -> None:
    """A ``ballrt.col`` function no Ball module declares must NOT be mapped —
    there is no base function to encode it as, so it has to fail loud.

    Derived (runtime MINUS declaration), not spelled: today that is exactly
    ``list_is_not_empty``, which lives in ``python/runtime`` alone."""
    declared, _ = _declared(STD_COLLECTIONS_DART)
    undeclared = sorted(_namespace_functions(ballrt.col) - set(declared))
    assert undeclared, (
        "the derivation broke: every ballrt.col function is declared, so this "
        "test can no longer observe anything"
    )
    _, table = rt.NAMESPACES["col"]
    mapped = [name for name in undeclared if name in table]
    assert not mapped, (
        "these ballrt.col helpers have an inverse but no std_collections "
        f"declaration to encode them as: {mapped}"
    )


def test_every_proto_helper_has_a_unary_obj_inverse() -> None:
    """``ball_proto`` ships as a generated module declaration, so its closed set
    is read from ``dart/shared/ball_proto.json``: every ``ballrt.proto`` function
    it declares with the single parameter ``obj`` must be mapped."""
    declaration = json.loads(BALL_PROTO_JSON.read_text(encoding="utf-8"))
    unary_obj = {
        f["name"] for f in declaration["functions"]
        if [p["name"] for p in (f.get("metadata") or {}).get("params", [])] == ["obj"]
    }
    exposed = _namespace_functions(ballrt.proto)
    mappable = sorted(exposed & unary_obj)
    assert len(mappable) >= 17, (
        f"only {len(mappable)} unary ball_proto helpers found — the derivation broke"
    )
    missing = [name for name in mappable if name not in rt.PROTO_HELPERS]
    assert not missing, (
        "these ball_proto access patterns have a ballrt.proto helper but no "
        f"inverse in ball_encoder/ballrt_calls.py: {missing}"
    )
    undeclared = sorted(exposed - unary_obj)
    assert not [n for n in undeclared if n in rt.PROTO_HELPERS], (
        "a ballrt.proto helper whose declaration is not unary-over-`obj` must "
        f"not be mapped: {undeclared}"
    )


# ── Behavioural: the Ball node the encoder really produces ───────────────────

def _encode_body(body: str) -> dict:
    program = encode(f"import ballrt\n\ndef main(_input=None):\n{body}")
    main = next(f for m in program["modules"] for f in m.get("functions", [])
                if f.get("name") == "main")
    return main["body"]


def _last_call(body: str) -> dict:
    statements = _encode_body(body)["block"]["statements"]
    return statements[-1]["expression"]["call"]


def _fields(call: dict) -> list[tuple[str, dict]]:
    message = call.get("input")
    if message is None:
        return []
    return [(f["name"], f["value"]) for f in message["messageCreation"]["fields"]]


def test_a_collection_helper_encodes_into_std_collections() -> None:
    call = _last_call('    ballrt.col.list_push(_input, 1)\n')
    assert (call["module"], call["function"]) == ("std_collections", "list_push")
    names = [name for name, _ in _fields(call)]
    assert names == ["list", "value"]


def test_a_callback_helper_uses_the_declared_callback_field() -> None:
    """``list_find``'s declared input is ``ListCallbackInput{list, callback}``,
    NOT the ``value`` field the compiler also accepts on the way in — encoding
    it back under ``value`` would hand the engine a call with no callback."""
    call = _last_call('    ballrt.col.list_find(_input, _input)\n')
    assert (call["module"], call["function"]) == ("std_collections", "list_find")
    assert [name for name, _ in _fields(call)] == ["list", "callback"]


def test_a_convert_helper_encodes_into_std_convert() -> None:
    call = _last_call('    ballrt.cvt.json_encode(_input)\n')
    assert (call["module"], call["function"]) == ("std_convert", "json_encode")
    assert [name for name, _ in _fields(call)] == ["value"]


def test_a_proto_helper_encodes_into_ball_proto_over_obj() -> None:
    call = _last_call('    ballrt.proto.whichExpr(_input)\n')
    assert (call["module"], call["function"]) == ("ball_proto", "whichExpr")
    assert [name for name, _ in _fields(call)] == ["obj"]


def test_set_create_encodes_into_std_not_std_collections() -> None:
    """``ballrt.col.set_create`` is the ONE namespaced helper whose inverse
    leaves its namespace's module: ``python/compiler`` emits it from BOTH
    ``std.set_create`` (what `dart/encoder` produces, and all 34 of the corpus's
    set literals) and ``std_collections.set_create``, and only the ``std``
    spelling is engine-proven, so that is the preimage chosen."""
    call = _last_call('    ballrt.col.set_create(_input)\n')
    assert (call["module"], call["function"]) == ("std", "set_create")
    assert [name for name, _ in _fields(call)] == ["elements"]


def test_an_empty_set_create_encodes_to_no_input_at_all() -> None:
    """``ballrt.col.set_create(None)`` is what the compiler emits for a set
    literal with no elements — literally the token ``None``, not a value_field
    lookup — so its inverse is an INPUT-LESS ``std.set_create``."""
    call = _last_call('    ballrt.col.set_create(None)\n')
    assert (call["module"], call["function"]) == ("std", "set_create")
    assert "input" not in call, call


def test_an_unknown_namespaced_helper_fails_loud() -> None:
    with pytest.raises(EncodeError) as excinfo:
        encode("import ballrt\n\ndef main(_input=None):\n"
               "    return ballrt.col.list_teleport(_input)\n")
    assert "ballrt.col.list_teleport()" in str(excinfo.value)


def test_an_unknown_namespace_fails_loud() -> None:
    with pytest.raises(EncodeError) as excinfo:
        encode("import ballrt\n\ndef main(_input=None):\n"
               "    return ballrt.nope.thing(_input)\n")
    assert "ballrt.nope" in str(excinfo.value)


def test_a_namespaced_helper_called_with_the_wrong_arity_fails_loud() -> None:
    with pytest.raises(EncodeError) as excinfo:
        encode("import ballrt\n\ndef main(_input=None):\n"
               "    return ballrt.col.list_push(_input)\n")
    assert "expects 2 argument(s), got 1" in str(excinfo.value)


# ── Whole-fixture round trips ────────────────────────────────────────────────

def _compile_fixture(name: str) -> str:
    program = json.loads((FIXTURES / f"{name}.ball.json").read_text(encoding="utf-8"))
    program.pop("@type", None)
    return compile_program(program)


def _golden(name: str) -> str:
    """Read as BYTES with only CRLF normalised — text mode would collapse a
    semantic lone ``\\r`` on both sides."""
    raw = (FIXTURES / f"{name}.expected_output.txt").read_bytes()
    return raw.decode("utf-8").replace("\r\n", "\n")


def _run_source(source: str) -> str:
    module = importlib.util.module_from_spec(
        importlib.util.spec_from_loader("<ball_ns_roundtrip>", loader=None)
    )
    exec(compile(source, "<ball_ns_roundtrip>", "exec"), module.__dict__)
    match = re.search(r"ballrt\.run_entry\((\w+)\)", source)
    entry = module.__dict__.get(match.group(1)) if match else module.__dict__.get("main")
    assert entry is not None, "compiled program declares no entry function"
    buf = io.StringIO()
    try:
        with redirect_stdout(buf):
            ballrt.run_entry(entry)
    except SystemExit:
        pass
    return buf.getvalue()


# One fixture per namespaced shape. Each is an `encode-error` on the
# `python-roundtrip` row today whose ONLY blocker is a `ballrt.col.*` /
# `ballrt.cvt.*` call, so each becomes a PASS with this inverse and with nothing
# else.
ROUND_TRIP_FIXTURES = [
    "126_flatten_nested_list",   # ballrt.col.list_push
    "129_unique_elements",       # ballrt.col.set_create + list_contains + list_push
    "384_list_filter_where",     # ballrt.col.list_filter — the callback field
    "385_list_insert_at_index",  # ballrt.col.list_insert — three fields
    "386_list_concat_addall",    # ballrt.col.list_concat
    "392_empty_set_literal",     # ballrt.col.set_create(None) — the input-less form
    "463_list_find_no_match",    # ballrt.col.list_find — callback, and it throws
    "190_utf8_encode_decode",    # ballrt.cvt.utf8_encode / utf8_decode
    "191_base64_encode_decode",  # ballrt.cvt.base64_encode / base64_decode
]


@pytest.mark.parametrize("name", ROUND_TRIP_FIXTURES)
def test_fixture_round_trips_through_the_python_encoder(name: str) -> None:
    assert _run_source(compile_program(encode(_compile_fixture(name)))) == _golden(name)
