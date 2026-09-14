"""Dart exception/error value types raised by runtime ops.

When a runtime op fails the way a Dart core operation would — `int.parse` on
non-numeric input (`FormatException`), an out-of-range index (`RangeError`) — the
thrown value must satisfy the interpreted program's *typed* catch
(`on FormatException` / `on RangeError`). Type matching resolves by class name
(and its supertypes), so these mirror Dart's hierarchy: `FormatException` is an
`Exception`; `RangeError`/`ArgumentError`/`StateError` are `Error`s. They are
deliberately **not** Python `Exception` subclasses — a Ball throw is carried by
`BallThrow`; these are its *payload*.
"""

from __future__ import annotations


class Exception:  # noqa: A001 — intentionally Dart's Exception, not Python's
    def __init__(self, message=""):
        self.message = message

    def toString(self):
        return f"{type(self).__name__}: {self.message}"

    def __str__(self):
        return self.toString()


class Error:
    def __init__(self, message=""):
        self.message = message

    def toString(self):
        return f"{type(self).__name__}: {self.message}"

    def __str__(self):
        return self.toString()


class FormatException(Exception):
    pass


class RangeError(Error):
    pass


class ArgumentError(Error):
    # Dart does NOT spell this one `<Type>: <message>` — `ArgumentError('nope')`
    # reads `Invalid argument(s): nope` (measured against the SDK 3.12.0, issue
    # #658). The inherited `Error.toString` produced `ArgumentError: nope`, which
    # no other target spells either; the cross-target contract lives in
    # `tools/check_error_rendering_tables.py` and every target's table agrees
    # with this string.
    def toString(self):
        return f"Invalid argument(s): {self.message}"

    def __str__(self):
        return self.toString()


class IndexError(Error):  # noqa: A001 — Dart's IndexError, not Python's
    pass


# ── Constructors for a USER-thrown built-in error ───────────────────────────
#
# A Ball program's own `throw FormatException('bad')` reaches the compiler as a
# `messageCreation` for a type with no `TypeDefinition`. Before #658 only
# `StateError` had a factory, so the other three compiled to an anonymous dict
# `{arg0: 'bad'}` — which printed as `{arg0: bad}`, answered `null` for
# `.message`, and, having no class at all, matched EVERY typed `on T catch`
# clause it met (fixture 473's `on StateError` clause caught a FormatException).
# Constructing the real class fixes all three at once, because `is_type` matches
# by class name over the MRO.


def make_format_exception(message=""):
    return FormatException(message)


def make_range_error(message=""):
    return RangeError(message)


def make_argument_error(message=""):
    return ArgumentError(message)
