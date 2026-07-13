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
    pass


class IndexError(Error):  # noqa: A001 — Dart's IndexError, not Python's
    pass
