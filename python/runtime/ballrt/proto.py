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

The five discriminators are enumerated (each needs its own variant list, which is
not derivable from the function name). Presence checks are NOT enumerated: any
``ball_proto`` presence check the encoder can emit — ``hasBody``, ``hasHttp``,
``hasFieldAccess``, … — is served by the module-level ``__getattr__`` below,
which derives the field name from the function name and caches the result. The
twelve the self-hosted ENGINE reaches are still defined explicitly, purely as the
zero-indirection fast path for the hottest calls.

Enumerating them was a latent bug (issue #570): ``python/compiler`` emits
``ballrt.proto.<fn>(obj)`` for whatever ``ball_proto`` function a program calls,
so the first Ball program to need a thirteenth — ``cli_core``'s ``treeReport``,
which calls ``hasHttp``/``hasFile``/``hasGit``/``hasRegistry``/``hasInline`` —
died with ``AttributeError: module 'ballrt.proto' has no attribute 'hasHttp'``.
Go never had the bug because ``go/compiler`` emits a generic
``ballrt.HasField(obj, "http")``.

The wider ball_proto surface (``getField``/``getStructField``/…) is still not
implemented here: no compiled Ball program in this repo reaches it, and an
unknown name fails loud with an ``AttributeError`` naming what is missing rather
than silently answering.
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


# ── Generic presence checks ──────────────────────────────────────────────────

def __getattr__(name):
    """Serve any ``has<Field>`` presence check not defined explicitly above.

    ``hasHttp`` -> ``_has(obj, "http")``, ``hasFieldAccess`` -> ``_has(obj,
    "fieldAccess")``: the proto3 jsonName is the suffix with its first letter
    lowered, which is exactly how ball_proto names these functions
    (``dart/shared/lib/ball_proto.dart``).

    The generated function is cached into the module globals, so a hot call site
    pays this lookup once and then resolves as fast as an explicit def. Anything
    that is not a ``has<Field>`` raises ``AttributeError`` naming the missing
    function — a compiled program reaching an unimplemented ball_proto function
    must fail loud, never read as "absent".
    """
    if name.startswith("has") and len(name) > 3 and name[3].isupper():
        field = name[3].lower() + name[4:]

        def presence(obj, _field=field):
            return _has(obj, _field)

        presence.__name__ = name
        presence.__qualname__ = name
        presence.__doc__ = f'ball_proto presence check for the "{field}" field.'
        globals()[name] = presence
        return presence
    raise AttributeError(
        f"module {__name__!r} has no attribute {name!r}: the ball_proto access pattern "
        f"{name!r} is not implemented in python/runtime (see ballrt/proto.py)"
    )
