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
  canonical base-function inventory) — ``print_error`` and ``invoke`` are not in
  it, so they are not here either;
* no type-name string operands (``is_type``/``as_type`` take a Python string
  literal, not an encodable expression).

Statement-shaped lowerings (``if``/``for``/``while``/``try``) are not here at
all: the compiler emits them as native Python statements, which the encoder
already reads back from that syntax.
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

# `ballrt.truthy(x)` coerces to a Python bool at a condition site. Ball performs
# that coercion implicitly wherever a condition is evaluated (`std.and`,
# `std.if`, …), so it encodes back to its operand unchanged.
TRUTHY = "truthy"

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
    "compare_to": ("compare_to", _BINARY),
    "index_get": ("index", ("target", "index")),
    "type_of": ("type_of", _UNARY),
    "string_contains": ("string_contains", ("value", "search")),
    "string_starts_with": ("string_starts_with", ("value", "prefix")),
    "string_ends_with": ("string_ends_with", ("value", "suffix")),
    "string_index_of": ("string_index_of", ("value", "search")),
    "string_last_index_of": ("string_last_index_of", ("value", "search")),
    "string_split": ("string_split", ("value", "separator")),
    "string_replace": ("string_replace", ("value", "from", "to")),
    "string_replace_all": ("string_replace_all", ("value", "from", "to")),
    "string_code_unit_at": ("string_code_unit_at", ("value", "index")),
    "string_runes": ("string_runes", _UNARY),
    "string_pad_left": ("string_pad_left", ("value", "width", "padding")),
    "string_pad_right": ("string_pad_right", ("value", "width", "padding")),
    "to_string_as_fixed": ("to_string_as_fixed", ("value", "digits")),
    "to_string_as_precision": ("to_string_as_precision", ("value", "precision")),
    # ── Math ─────────────────────────────────────────────────────────────────
    "math_pow": ("math_pow", ("base", "exponent")),
    "math_min": ("math_min", _BINARY),
    "math_max": ("math_max", _BINARY),
    "math_clamp": ("math_clamp", ("value", "lower", "upper")),
    "math_gcd": ("math_gcd", _BINARY),
    "math_is_finite": ("math_is_finite", _UNARY),
    "math_is_infinite": ("math_is_infinite", _UNARY),
}
