"""``ball_proto`` access patterns — the protobuf-compatibility layer the
self-hosted engine reads its already-deserialized target program through.

These base functions (``isBase: true``, no body — invariant #3) operate on the
canonical proto3-JSON view the engine loader produces: a tree of
insertion-ordered ``dict``s keyed by camelCase jsonNames, with oneofs
represented by which variant key is present. Semantics match
``dart/shared/lib/ball_proto.dart`` (the authoritative definition) and the Go
sibling ``go/runtime/proto.go`` exactly: a discriminator returns the first
present (non-null) variant key in declaration order, or ``"notSet"``; a presence
check follows the proto3 rule that an absent key / explicit null / empty string /
empty list/map all read as not-present (but a numeric 0 / bool false do not).

The self-hosted engine reaches exactly these 17 (5 discriminators + 12 presence
checks); the wider ball_proto surface (getField/getStructField/…) is not part of
the compiled engine program, so it is intentionally not implemented here.
"""

from __future__ import annotations

# Oneof variant keys of each discriminated message, in ball_proto.dart's check
# order (first present key wins). Canonical proto3 jsonNames (camelCase).
_EXPR = ("call", "literal", "reference", "fieldAccess", "messageCreation", "block", "lambda")
_LITERAL = ("intValue", "doubleValue", "stringValue", "boolValue", "bytesValue", "listValue")
_STMT = ("let", "expression")
_VALUE_KIND = ("nullValue", "numberValue", "stringValue", "boolValue", "structValue", "listValue")
_SOURCE = ("http", "file", "git", "registry", "inline")


def _which(obj, variants):
    if isinstance(obj, dict):
        for v in variants:
            if obj.get(v) is not None:
                return v
    return "notSet"


def _has(obj, field):
    if not isinstance(obj, dict):
        return False
    v = obj.get(field)
    if v is None:
        return False
    if isinstance(v, (str, list, dict)):
        return len(v) != 0
    return True


# ── Oneof discriminators ─────────────────────────────────────────────────────

def whichExpr(obj):
    return _which(obj, _EXPR)


def whichValue(obj):
    return _which(obj, _LITERAL)


def whichStmt(obj):
    return _which(obj, _STMT)


def whichKind(obj):
    return _which(obj, _VALUE_KIND)


def whichSource(obj):
    return _which(obj, _SOURCE)


# ── Presence checks ──────────────────────────────────────────────────────────

def hasBody(obj):
    return _has(obj, "body")


def hasBoolValue(obj):
    return _has(obj, "boolValue")


def hasCall(obj):
    return _has(obj, "call")


def hasDescriptor(obj):
    return _has(obj, "descriptor")


def hasInput(obj):
    return _has(obj, "input")


def hasListValue(obj):
    return _has(obj, "listValue")


def hasMetadata(obj):
    return _has(obj, "metadata")


def hasNumberValue(obj):
    return _has(obj, "numberValue")


def hasObject(obj):
    return _has(obj, "object")


def hasResult(obj):
    return _has(obj, "result")


def hasStringValue(obj):
    return _has(obj, "stringValue")


def hasStructValue(obj):
    return _has(obj, "structValue")
