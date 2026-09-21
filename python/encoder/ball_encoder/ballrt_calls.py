"""Recognizing the Ball Python runtime's own dispatch helpers (``ballrt.*``).

``python/runtime`` is an ordinary importable package, so ``ballrt.add(a, b)`` is
a perfectly normal thing to find in hand-written Python — but the reason this
module exists is the ROUND-TRIP leg (issue #642): ``python/compiler`` emits every
Ball base-function call as exactly one of these helpers, and the encoder used to
refuse all of them (``method call .print_(...) is not supported``), so not one of
the conformance fixtures could survive Ball -> Python -> Ball. The leg measured a
flat 0 and its CI row went green on it.

Every entry below is the exact INVERSE of one line in
``python/compiler/ball_compiler/compiler.py``'s base-call dispatch: the helper's
name, the base function it is the emission of, and that base function's input
field for each positional argument (a base call's input is always a message
keyed by field name — ``{left, right}``, ``{value}``, …). Keep the two in step.
A helper the compiler emits but this table does not name is NOT silently
mis-encoded: it fails loud (issue #55 doctrine), which is why the table is
deliberately restricted to helpers whose shape is unambiguous:

* fixed arity, every argument a real expression — helpers the compiler calls
  with a ``None`` placeholder for an omitted optional argument
  (``string_substring``, ``to_string_as_exponential``) are left out rather than
  guessed at;
* a ``std`` base function ``dart/shared/std.json`` actually declares (the
  canonical base-function inventory) — ``print_error`` and
  ``string_from_char_codes`` are not in it, so they are not here either;
* a fixed input shape — ``invoke`` is declared, but its ``InvokeInput`` is
  variadic (a call's arguments are the input's remaining fields), so it is not
  of this table's one-field-per-positional-argument shape.

Several shapes ARE exact inverses without being one ``std`` call over expression
arguments, and live below as named constants (handled in
``encoder.encode_ballrt_call``): ``getfield`` lands on a ``fieldAccess`` NODE,
``setfield``/``index_set`` on a ``std.assign`` over the matching l-value,
``is_type``/``as_type`` on ``std.is``/``std.as`` whose ``type`` field is a bare
type NAME, ``brk``/``cont`` on ``std.break``/``std.continue`` whose operand is a
label STRING, ``rethrow`` on an input-less ``std.rethrow``, and
``truthy``/``iterate`` on their operand unchanged.

``python/encoder/tests/test_ballrt_inverse.py`` is the drift guard: every
``UnaryInput`` base function in ``std.json`` whose ``ballrt`` helper carries the
same spelling MUST appear here, derived from those two files rather than from a
list kept beside this one (issue #690).

``if`` is not here at all: the compiler emits it as a native Python ``if``,
which the encoder already reads back from that syntax. The loop and ``try``
lowerings are *shaped*, not named — a ``while True:`` whose body carries the
break/continue trap, or a ``try:`` whose handler names one of the flow
exceptions below — so their recognisers live in ``encoder.encode_while`` /
``encoder.encode_try``; only the names they match on are here (issue #690).
"""

from __future__ import annotations

# The module alias `python/compiler` gives the runtime in every program it emits
# (`import ballrt`).
RUNTIME_MODULE = "ballrt"

# The entry wrapper: `if __name__ == "__main__": ballrt.run_entry(main)`. It is
# not a base call, and the encoder's existing `__main__`-guard handling already
# drops the guard when the file declares its own `main`, so it never needs an
# encoding of its own.
ENTRY_WRAPPER = "run_entry"

# Helpers that are adapters, not operations: each encodes back to its single
# operand unchanged, because the Ball semantics the compiler needed the adapter
# for are implicit in the node that consumes it.
#
# * `truthy(x)` coerces to a Python bool at a condition site; Ball performs that
#   coercion implicitly wherever a condition is evaluated (`std.and`, `std.if`,
#   …).
# * `iterate(xs)` is the runtime's uniform iteration view (a Map iterates its
#   values, a Set its elements); `std.for_in` / `std.spread` iterate a
#   collection natively, so the adapter has no Ball spelling of its own.
PASSTHROUGH = frozenset({"truthy", "iterate"})

# Kept as a name of its own: the arity check below reports it, and it is the one
# passthrough that predates the set.
TRUTHY = "truthy"

# ── Shapes that are NOT one std base call over expression arguments ──────────
# Each is still the exact inverse of one `python/compiler` line; it just lands
# on an Expression node other than `call`, or on a call whose operand is a bare
# string rather than an encodable expression. Handled explicitly in
# `encoder.encode_ballrt_call` rather than through HELPERS.

#: `ballrt.getfield(obj, "name")` — the emission of a `fieldAccess` expression.
FIELD_GET = "getfield"
#: `ballrt.setfield(obj, "name", v)` — an assignment whose l-value is a
#: `fieldAccess`.
FIELD_SET = "setfield"
#: `ballrt.index_set(target, key, v)` — an assignment whose l-value is the
#: `std.index` call the compiler recognises as an index l-value.
INDEX_SET = "index_set"
#: `ballrt.is_type(v, "T")` / `ballrt.as_type(v, "T")` — `std.is` / `std.as`,
#: whose `type` field is a TYPE NAME string, not an expression. (`is_not` has no
#: helper of its own: the compiler emits `not ballrt.is_type(...)`, which reads
#: back as `std.not` over `std.is` — the same test.)
TYPE_OPS = {"is_type": "is", "as_type": "as"}

# ── The statement lowerings' vocabulary (issue #690) ─────────────────────────
# `python/compiler` emits a Python `try:` for four distinct reasons, and only
# one of them is a Ball `std.try` (`compiler.run_try`): the other three are the
# loop-body break/continue trap (`_loop_body`, `run_forin`), the
# `except ballrt.BallReturn` function-body wrapper (`emit_body`), and that
# wrapper's value-less constructor form. `encoder.encode_try` tells them apart
# by the exception class each handler names, so the names live here beside the
# rest of the inverse table rather than as literals buried in the recogniser.
#
# `python/encoder/tests/test_ballrt_inverse.py` closes them against
# `python/runtime`: a rename there would otherwise turn every recogniser into a
# silent no-match, quietly putting the whole corpus back to
# `unsupported statement Try`.

#: `except ballrt.BallBreak as _brk:` / `except ballrt.BallContinue as _cnt:` —
#: the trap that turns a Ball `break`/`continue` back into Python's own.
FLOW_BREAK = "BallBreak"
FLOW_CONTINUE = "BallContinue"
#: `except ballrt.BallReturn as _r:` — the function-body return wrapper.
FLOW_RETURN = "BallReturn"
#: `except ballrt.BallThrow as _ex:` — the ONE shape that is a real `std.try`.
FLOW_THROW = "BallThrow"
#: `ballrt.flow._caught` — the rethrow stack a compiled catch pushes the caught
#: value onto for the duration of the handler, popped in its own `finally`.
FLOW_MODULE = "flow"
CAUGHT_STACK = "_caught"
#: `ballrt.stack_trace_of(_ex)` — the compiler's spelling of a `catch (e, st)`
#: clause's SECOND binding, which reads back as the clause's `stack_trace` field.
STACK_TRACE_OF = "stack_trace_of"
#: `ballrt.catch_matches(_ex.value, "<Type>")` — the TEST of one typed
#: `on <Type> catch` clause in the compiler's dispatch chain (issue #724). It is
#: a recognised SHAPE, not a `HELPERS` entry: it has no `std` base function of
#: its own, and what it reads back as is the clause's `type` FIELD.
CATCH_MATCHES = "catch_matches"

#: `ballrt.brk(label)` / `ballrt.cont(label)` -> `std.break` / `std.continue`.
#: The operand is a label STRING, not an expression — and the compiler always
#: passes one, EMPTY for an unlabelled jump, which reads back as no input at all
#: (the shape `dart/encoder` produces for a label-less `break`).
LABEL_OPS = {"brk": "break", "cont": "continue"}
#: `ballrt.rethrow()` -> `std.rethrow`, the one flow function with no input.
RETHROW = "rethrow"

_UNARY = ("value",)
_BINARY = ("left", "right")

#: ``ballrt.<name>`` -> ``(std base function, input field per positional arg)``.
HELPERS: dict[str, tuple[str, tuple[str, ...]]] = {
    # ── I/O ──────────────────────────────────────────────────────────────────
    "print_": ("print", ("message",)),
    # ── Arithmetic / bitwise / comparison (compiler table_2) ─────────────────
    "add": ("add", _BINARY),
    "subtract": ("subtract", _BINARY),
    "multiply": ("multiply", _BINARY),
    "intdiv": ("divide", _BINARY),
    "divide_double": ("divide_double", _BINARY),
    "modulo": ("modulo", _BINARY),
    "bitwise_and": ("bitwise_and", _BINARY),
    "bitwise_or": ("bitwise_or", _BINARY),
    "bitwise_xor": ("bitwise_xor", _BINARY),
    "left_shift": ("left_shift", _BINARY),
    "right_shift": ("right_shift", _BINARY),
    "unsigned_right_shift": ("unsigned_right_shift", _BINARY),
    "equals": ("equals", _BINARY),
    "not_equals": ("not_equals", _BINARY),
    "less_than": ("less_than", _BINARY),
    "greater_than": ("greater_than", _BINARY),
    "null_coalesce": ("null_coalesce", _BINARY),
    "lte": ("lte", _BINARY),
    "gte": ("gte", _BINARY),
    # ── Unary (compiler table_1) ─────────────────────────────────────────────
    "negate": ("negate", _UNARY),
    "not_": ("not", _UNARY),
    "bitwise_not": ("bitwise_not", _UNARY),
    "to_int": ("to_int", _UNARY),
    "to_double": ("to_double", _UNARY),
    "null_check": ("null_check", _UNARY),
    # ── Strings & conversion ─────────────────────────────────────────────────
    "to_str": ("to_string", _UNARY),
    "length": ("length", _UNARY),
    "concat": ("concat", _BINARY),
    "compare_to": ("compare_to", ("value", "other")),
    "index_get": ("index", ("target", "index")),
    "type_of": ("type_of", _UNARY),
    "string_contains": ("string_contains", _BINARY),
    "string_starts_with": ("string_starts_with", _BINARY),
    "string_ends_with": ("string_ends_with", _BINARY),
    "string_index_of": ("string_index_of", _BINARY),
    "string_last_index_of": ("string_last_index_of", _BINARY),
    "string_split": ("string_split", _BINARY),
    "string_replace": ("string_replace", ("value", "from", "to")),
    "string_replace_all": ("string_replace_all", ("value", "from", "to")),
    "string_code_unit_at": ("string_code_unit_at", ("target", "index")),
    "string_runes": ("string_runes", _UNARY),
    "string_pad_left": ("string_pad_left", ("value", "width", "padding")),
    "string_pad_right": ("string_pad_right", ("value", "width", "padding")),
    "to_string_as_fixed": ("to_string_as_fixed", ("value", "digits")),
    "to_string_as_precision": ("to_string_as_precision", ("value", "precision")),
    "string_to_upper": ("string_to_upper", _UNARY),
    "string_to_lower": ("string_to_lower", _UNARY),
    "string_trim": ("string_trim", _UNARY),
    "string_trim_start": ("string_trim_start", _UNARY),
    "string_trim_end": ("string_trim_end", _UNARY),
    "string_is_empty": ("string_is_empty", _UNARY),
    # Its OWN base function, never `not string_is_empty(...)`: a delegating
    # receiver sees WHICH member the source asked for (issue #674), so the
    # inverse must land back on the same name the compiler emitted.
    "string_is_not_empty": ("string_is_not_empty", _UNARY),
    "string_to_int": ("string_to_int", _UNARY),
    "string_to_double": ("string_to_double", _UNARY),
    "string_from_char_code": ("string_from_char_code", _UNARY),
    "string_length": ("string_length", _UNARY),
    # ── Flow ─────────────────────────────────────────────────────────────────
    # `ballrt.throw(v)` is the emission of `std.throw {value}` — an ordinary
    # unary base call, not a statement lowering (`rethrow` takes no operand and
    # `std.rethrow` has no input, so it is not of this shape).
    "throw": ("throw", _UNARY),
    # `ballrt.ret(v)` is `std.return {value}`. The compiler always passes an
    # operand — a value-less Ball `return` emits `ballrt.ret(None)`, which reads
    # back as `std.return` over a null literal: the same program.
    "ret": ("return", _UNARY),
    # ── Math ─────────────────────────────────────────────────────────────────
    "math_abs": ("math_abs", _UNARY),
    "math_floor": ("math_floor", _UNARY),
    "math_ceil": ("math_ceil", _UNARY),
    "math_round": ("math_round", _UNARY),
    "math_sqrt": ("math_sqrt", _UNARY),
    "math_trunc": ("math_trunc", _UNARY),
    "math_sign": ("math_sign", _UNARY),
    "round_to_double": ("round_to_double", _UNARY),
    "floor_to_double": ("floor_to_double", _UNARY),
    "ceil_to_double": ("ceil_to_double", _UNARY),
    "truncate_to_double": ("truncate_to_double", _UNARY),
    "math_pow": ("math_pow", _BINARY),
    "math_min": ("math_min", _BINARY),
    "math_max": ("math_max", _BINARY),
    "math_clamp": ("math_clamp", ("value", "min", "max")),
    "math_gcd": ("math_gcd", _BINARY),
    "math_is_finite": ("math_is_finite", _UNARY),
    "math_is_infinite": ("math_is_infinite", _UNARY),
}

# ── Namespaced helpers: `ballrt.<ns>.<name>(...)` (issue #690) ───────────────
# Not every base call is a flat `ballrt.<name>`. Three of the compiler's modules
# dispatch through a namespace object that `python/runtime/ballrt/__init__.py`
# re-exports, and `encode_call` reads the receiver to tell them apart:
#
#   ballrt.col.<name>    -> std_collections  (compiler.collections_expr)
#   ballrt.cvt.<name>    -> std_convert      (compiler.convert_expr)
#   ballrt.proto.<name>  -> ball_proto       (compiler.base_expr)
#
# Unlike `HELPERS`, the base function is ALWAYS spelled the same as the helper
# (the compiler emits `ballrt.col.{rt}` where `rt` is the Ball function's own
# name), so an entry records only the input FIELD per positional argument.
#
# Those field names are read from each module's OWN Ball declaration, never from
# the aliases `python/compiler` happens to accept on the way in. That matters:
# `value_field(f, 'value', 'callback')` takes either spelling, but `list_find`'s
# declared input is `ListCallbackInput{list, callback}` — encoding its predicate
# back under `value` hands the engine a call whose callback field is simply
# absent. This is #690's `math_clamp` lesson on the namespaced half, and
# `python/encoder/tests/test_ballrt_namespaced.py` closes it against
# `dart/shared/lib/std_collections.dart` / `std_convert.dart` (which declare
# both the functions and their input types) and `dart/shared/ball_proto.json`.

_LIST = ("list",)
_LIST_INDEX = ("list", "index")
_LIST_VALUE = ("list", "value")
_LIST_CALLBACK = ("list", "callback")
_MAP = ("map",)
_MAP_KEY = ("map", "key")
_SET = ("set",)
_SET_VALUE = ("set", "value")

#: ``ballrt.col.<name>`` -> the ``std_collections`` input fields, in order.
#: ``ListInput{list, index, value}``, ``ListCallbackInput{list, callback}``,
#: ``ListSliceInput{list, start, end}``, ``MapInput{map, key, value}``,
#: ``StringJoinInput{list, separator}``, ``SetInput{set, value}`` and
#: ``SetBinaryInput{left, right}`` are the declared shapes.
COLLECTION_HELPERS: dict[str, tuple[str, ...]] = {
    # ── Lists ────────────────────────────────────────────────────────────────
    "list_get": _LIST_INDEX,
    "list_length": _LIST,
    "list_is_empty": _LIST,
    "list_first": _LIST,
    "list_last": _LIST,
    "list_contains": _LIST_VALUE,
    "list_index_of": _LIST_VALUE,
    "list_reverse": _LIST,
    "list_concat": _LIST_VALUE,
    "list_slice": ("list", "start", "end"),
    # `list_take`/`list_drop` carry a COUNT, and `ListInput` declares no field of
    # that name; `value` is the one the Dart reference engine reads first
    # (`m['value'] ?? m['index']`).
    "list_take": _LIST_VALUE,
    "list_drop": _LIST_VALUE,
    "list_push": _LIST_VALUE,
    "list_pop": _LIST,
    "list_insert": ("list", "index", "value"),
    "list_remove_at": _LIST_INDEX,
    "list_set": ("list", "index", "value"),
    "list_clear": _LIST,
    "list_map": _LIST_CALLBACK,
    "list_filter": _LIST_CALLBACK,
    "list_all": _LIST_CALLBACK,
    "list_any": _LIST_CALLBACK,
    "list_find": _LIST_CALLBACK,
    # A comparator-less sort compiles to `ballrt.col.list_sort(xs, None)` (the
    # compiler's absent-field placeholder), which reads back as a null
    # `callback` — exactly what the engine's `cb == null` natural-sort arm
    # expects.
    "list_sort": _LIST_CALLBACK,
    "list_join": ("list", "separator"),
    "list_to_list": _LIST,
    # ── Maps ─────────────────────────────────────────────────────────────────
    "map_get": _MAP_KEY,
    "map_set": ("map", "key", "value"),
    "map_delete": _MAP_KEY,
    "map_contains_key": _MAP_KEY,
    "map_contains_value": ("map", "value"),
    "map_keys": _MAP,
    "map_values": _MAP,
    "map_length": _MAP,
    "map_is_empty": _MAP,
    "map_put_if_absent": ("map", "key", "value"),
    # ── Sets ─────────────────────────────────────────────────────────────────
    "set_add": _SET_VALUE,
    "set_remove": _SET_VALUE,
    "set_contains": _SET_VALUE,
    "set_length": _SET,
    "set_is_empty": _SET,
    "set_to_list": _SET,
    "set_union": _BINARY,
    "set_intersection": _BINARY,
    "set_difference": _BINARY,
}

#: ``ballrt.cvt.<name>`` -> the ``std_convert`` input fields. Every one of the
#: six declares a single ``value``.
CONVERT_HELPERS: dict[str, tuple[str, ...]] = {
    "json_encode": _UNARY,
    "json_decode": _UNARY,
    "utf8_encode": _UNARY,
    "utf8_decode": _UNARY,
    "base64_encode": _UNARY,
    "base64_decode": _UNARY,
}

#: ``ballrt.proto.<name>`` — the ``ball_proto`` access patterns the runtime
#: exposes. Every one is declared unary over ``obj`` in
#: ``dart/shared/ball_proto.json``, so the table is a set plus that one field.
PROTO_INPUT = ("obj",)
PROTO_HELPERS: frozenset[str] = frozenset({
    "hasBody", "hasBoolValue", "hasCall", "hasDescriptor", "hasInput",
    "hasListValue", "hasMetadata", "hasNumberValue", "hasObject", "hasResult",
    "hasStringValue", "hasStructValue",
    "whichExpr", "whichKind", "whichSource", "whichStmt", "whichValue",
})

#: ``ballrt.<ns>`` -> ``(Ball module, that namespace's inverse table)``.
NAMESPACES: dict[str, tuple[str, dict[str, tuple[str, ...]]]] = {
    "col": ("std_collections", COLLECTION_HELPERS),
    "cvt": ("std_convert", CONVERT_HELPERS),
    "proto": ("ball_proto", {name: PROTO_INPUT for name in sorted(PROTO_HELPERS)}),
}

#: The namespace `set_create` is reached through, and its helper name.
#:
#: `set_create` is the ONE namespaced helper whose inverse leaves its
#: namespace's module. `python/compiler` emits `ballrt.col.set_create` from BOTH
#: `std.set_create` (`base_expr`) and `std_collections.set_create`
#: (`collections_expr`) — identical text from two preimages. `std` is the one
#: chosen: it is what `dart/encoder` produces for a set literal (all 34 of the
#: conformance corpus's `set_create` calls are `std.set_create {elements}`) and
#: therefore the spelling the Dart reference engine is proven to run.
#: Its argument shape is special too — the compiler writes the literal token
#: `None` when the literal has no elements at all, so that form's inverse is an
#: INPUT-LESS call rather than one carrying a null `elements`.
COLLECTIONS_NAMESPACE = "col"
SET_CREATE = "set_create"
SET_CREATE_MODULE = "std"
SET_CREATE_ELEMENTS = "elements"

#: Per namespace, the helpers handled EXPLICITLY in
#: ``encoder.encode_ballrt_namespaced_call`` rather than through that
#: namespace's table — the namespaced analogue of ``FIELD_GET`` & co. One shape,
#: one home: a name here must not also appear in the table, where the generic
#: arm would encode it as a plain call into the namespace's own module.
EXPLICIT_NAMESPACED: dict[str, frozenset[str]] = {
    COLLECTIONS_NAMESPACE: frozenset({SET_CREATE}),
}
