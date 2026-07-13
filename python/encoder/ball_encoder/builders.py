"""Low-level constructors for the seven Ball Expression node types + statements.

These produce the **raw proto3-JSON dict view** (camelCase keys — ``entryModule``,
``typeName``, ``messageCreation`` …) that the Ball → Python compiler
(``python/compiler``) consumes directly via its loader. Keeping the AST-walking
code in :mod:`ball_encoder.encoder` reading as a direct source→Ball mapping is the
Python analog of ``go/encoder/builders.go`` and the free helpers at the bottom of
``rust/encoder/src/lib.rs``.

Two shape conventions worth stating once:

* ``int64`` literals are emitted as JSON **strings** (``"2"``), the canonical
  proto3-JSON form for 64-bit integers, so the ``.ball.json`` a front-end writes
  is a drop-in every loader (Dart/TS/Go/…) accepts. The Python compiler reads
  both ``int`` and ``str`` (``int(lit["intValue"])``), so this is lossless.
* Default-valued scalars (``0``, ``false``, ``""``) are always emitted
  explicitly, never omitted. The compiler distinguishes "an int literal 0" from
  "an unset (null) literal" purely by the *presence* of the ``intValue`` key, so
  the dict view must carry it.
"""

from __future__ import annotations

# ── Literals ─────────────────────────────────────────────────────────────────


def int_lit(v: int) -> dict:
    return {"literal": {"intValue": str(int(v))}}


def double_lit(v: float) -> dict:
    return {"literal": {"doubleValue": float(v)}}


def string_lit(v: str) -> dict:
    return {"literal": {"stringValue": v}}


def bool_lit(v: bool) -> dict:
    return {"literal": {"boolValue": bool(v)}}


def null_lit() -> dict:
    """The unset ``Literal.value`` oneof — Ball null."""
    return {"literal": {}}


def list_lit(elements: list[dict]) -> dict:
    return {"literal": {"listValue": {"elements": elements}}}


# ── Reference / field access ─────────────────────────────────────────────────


def ref(name: str) -> dict:
    return {"reference": {"name": name}}


def field_access(obj: dict, field: str) -> dict:
    return {"fieldAccess": {"object": obj, "field": field}}


# ── Message creation (base-call argument packing + typed constructions) ───────


def _field_values(fields: list[tuple[str, dict]]) -> list[dict]:
    return [{"name": name, "value": value} for name, value in fields]


def args_message(*fields: tuple[str, dict]) -> dict:
    """An anonymous (empty ``typeName``) message_creation — the shape every base
    function's input uses to pack its named arguments (left/right,
    condition/then/else …)."""
    return {"messageCreation": {"typeName": "", "fields": _field_values(list(fields))}}


def named_message(type_name: str, fields: list[tuple[str, dict]]) -> dict:
    """A typed message_creation (non-empty ``typeName``)."""
    return {"messageCreation": {"typeName": type_name, "fields": _field_values(fields)}}


# ── Calls ────────────────────────────────────────────────────────────────────


def call(module: str, function: str, input_expr: dict | None) -> dict:
    c: dict = {"module": module, "function": function}
    if input_expr is not None:
        c["input"] = input_expr
    return {"call": c}


def std_call(function: str, input_expr: dict | None) -> dict:
    return call("std", function, input_expr)


def std_binary(function: str, left: dict, right: dict) -> dict:
    return std_call(function, args_message(("left", left), ("right", right)))


def std_unary(function: str, value: dict) -> dict:
    return std_call(function, args_message(("value", value)))


def if_call(condition: dict, then: dict, else_branch: dict | None) -> dict:
    fields = [("condition", condition), ("then", then)]
    if else_branch is not None:
        fields.append(("else", else_branch))
    return std_call("if", args_message(*fields))


# ── Blocks / statements ──────────────────────────────────────────────────────


def let_stmt(name: str, value: dict) -> dict:
    return {"let": {"name": name, "value": value}}


def expr_stmt(e: dict) -> dict:
    return {"expression": e}


def block_expr(statements: list[dict], result: dict | None = None) -> dict:
    blk: dict = {"statements": statements}
    if result is not None:
        blk["result"] = result
    return {"block": blk}


def lambda_expr(fn: dict) -> dict:
    """Wrap an anonymous FunctionDefinition (name "") as a Ball lambda."""
    return {"lambda": fn}


# ── Metadata (cosmetic — invariant #2) ───────────────────────────────────────


def func_metadata(params: list[str]) -> dict:
    """A FunctionDefinition.metadata Struct carrying ``kind`` and the load-bearing
    ``params`` list (``[{"name": …}, …]``).

    ``params`` is the one piece the Python compiler actually reads (it drives the
    parameter prologue: a single param is bound ``p = _input``; 2+ params are read
    ``p = ballrt.arg(_input, "p", "argN")``), so it MUST reflect every declared
    parameter name in order. Everything else metadata could carry is cosmetic."""
    m: dict = {"kind": "function"}
    if params:
        m["params"] = [{"name": p} for p in params]
    return m
