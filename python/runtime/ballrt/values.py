"""Value model helpers: sets, argument messages, field / index access.

Ball values are native Python where possible (``int``/``float``/``str``/
``bool``/``None`` and insertion-ordered ``list``/``dict``). Two shapes need
dedicated support: Ball's insertion-ordered set (:class:`BallSet`, since
Python's ``set`` is unordered) and user-type instances, which the compiler
emits as ordinary Python classes so field access is attribute access and method
dispatch is Python's own.
"""

from __future__ import annotations

from . import ops


class BallSet:
    """An insertion-ordered set with Dart value-equality membership."""

    __slots__ = ("_items",)

    def __init__(self, items=None):
        self._items = []
        if items:
            for it in items:
                self.add(it)

    def add(self, value):
        if not self.contains(value):
            self._items.append(value)
        return value

    def remove(self, value):
        for i, it in enumerate(self._items):
            if ops.equals(it, value):
                del self._items[i]
                return True
        return False

    def contains(self, value):
        return any(ops.equals(it, value) for it in self._items)

    def __len__(self):
        return len(self._items)

    def __iter__(self):
        return iter(self._items)

    def __str__(self):
        return "{" + ", ".join(ops.to_str(x) for x in self._items) + "}"


NULL = None


# ── Argument messages (the packed input of a multi-parameter call) ───────────

def arg(input_msg, *names):
    """Read a named-or-positional field from a packed argument message.

    A single-parameter call is passed its value directly (not a message), so a
    non-dict ``input_msg`` is returned as-is (invariant #1).
    """
    if isinstance(input_msg, dict):
        for n in names:
            if n in input_msg:
                return input_msg[n]
        return None
    return input_msg


# ── First-class function application ─────────────────────────────────────────

def invoke(fn, argument):
    return fn(argument)


def call_fn(fn, argument):
    return fn(argument)


# ── Field access (fieldAccess node / assign to a field lvalue) ───────────────

_STR_PROPS = {"length", "isEmpty", "isNotEmpty"}


def getfield(obj, name):
    if obj is None:
        raise AttributeError(f"ball: field {name!r} on null")
    if isinstance(obj, str):
        if name == "length":
            return ops.utf16_length(obj)
        if name == "isEmpty":
            return len(obj) == 0
        if name == "isNotEmpty":
            return len(obj) > 0
        raise AttributeError(f"ball: unsupported string field {name!r}")
    if isinstance(obj, list):
        if name == "length":
            return len(obj)
        if name == "isEmpty":
            return len(obj) == 0
        if name == "isNotEmpty":
            return len(obj) > 0
        if name == "first":
            return obj[0]
        if name == "last":
            return obj[-1]
        if name == "reversed":
            return list(reversed(obj))
        raise AttributeError(f"ball: unsupported list field {name!r}")
    if isinstance(obj, dict):
        if name == "length":
            return len(obj)
        if name == "isEmpty":
            return len(obj) == 0
        if name == "isNotEmpty":
            return len(obj) > 0
        if name == "keys":
            return list(obj.keys())
        if name == "values":
            return list(obj.values())
        if name in obj:
            return obj[name]
        raise AttributeError(f"ball: unsupported map field {name!r}")
    if isinstance(obj, BallSet):
        if name == "length":
            return len(obj)
        if name == "isEmpty":
            return len(obj) == 0
        if name == "isNotEmpty":
            return len(obj) > 0
    return getattr(obj, name)


def setfield(obj, name, value):
    setattr(obj, name, value)
    return value


# ── Index access (std.index / std.assign to an index lvalue) ─────────────────

def index_get(target, key):
    if isinstance(target, (list, str)):
        return target[int(key)]
    if isinstance(target, dict):
        return target.get(key)
    raise TypeError(f"ball: cannot index {type(target).__name__}")


def index_set(target, key, value):
    if isinstance(target, list):
        target[int(key)] = value
        return value
    if isinstance(target, dict):
        target[key] = value
        return value
    raise TypeError(f"ball: cannot index-assign {type(target).__name__}")


# ── Iteration (for-in / spread) ──────────────────────────────────────────────

def iterate(value):
    if isinstance(value, list):
        return list(value)
    if isinstance(value, BallSet):
        return list(value)
    if isinstance(value, str):
        return list(value)
    if isinstance(value, dict):
        return list(value.keys())
    if value is None:
        return []
    return list(value)
