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


class BallValue:
    """Root of the engine's runtime value hierarchy (``ball_value.dart``).

    A stub/abstract base: the self-hosted engine declares its internal classes
    (``_FlowSignal``, ``BallGenerator``, …) as ``extends BallValue``, but the
    scalar wrappers (BallInt/BallDouble/…) are *not* materialised — their
    constructors return the raw Python value (see ``selfhost.ball_*``), so
    arithmetic never sees a wrapper. Only :class:`BallMap` is a real subclass,
    because ``BallObject`` (a live class instance) extends it."""

    __slots__ = ()


class BallMap(BallValue):
    """The engine's map value (``ball_value.dart``). Backs ``BallObject`` (a Ball
    class instance), whose methods read/write the inherited ``entries`` map and
    override ``operator []=`` (emitted as ``__op_set_index__``).

    ``entries`` is a lazily-created attribute so a subclass constructor that does
    not chain ``super()`` (the compiler does not emit super calls) still has it."""

    @property
    def entries(self):
        d = self.__dict__.get("_entries")
        if d is None:
            d = {}
            self.__dict__["_entries"] = d
        return d

    def __getitem__(self, key):
        return self.entries.get(key)

    def __setitem__(self, key, value):
        self.entries[key] = value

    def __str__(self):
        return "{" + ", ".join(f"{ops.to_str(k)}: {ops.to_str(v)}" for k, v in self.entries.items()) + "}"


def make_ball_map(entries=None):
    m = BallMap()
    if entries:
        m.entries.update(entries)
    return m


class MapEntry:
    """A Dart ``MapEntry`` — what ``Map.entries`` yields (``.key`` / ``.value``)."""

    __slots__ = ("key", "value")

    def __init__(self, key, value):
        self.key = key
        self.value = value

    def __str__(self):
        return f"MapEntry({ops.to_str(self.key)}: {ops.to_str(self.value)})"


NULL = None

# The Dart protobuf codegen renames a generated getter that would collide with an
# Object member (`FieldAccess.field` -> `.field_2`, `TypeDefinition.descriptor` ->
# `.descriptor_`); the engine reads the program through those renamed getters, but
# the loaded proto3-JSON view keys fields by their plain jsonName. Mirrors the
# Go/Rust/TS engines' aliases.
_FIELD_ALIAS = {"field_2": "field", "descriptor_": "descriptor"}


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


def _runtime_type_name(obj):
    """Dart ``value.runtimeType`` — the type's name (used by the engine in error
    messages and type reporting). A user instance reports its class name."""
    if obj is None:
        return "Null"
    if isinstance(obj, bool):
        return "bool"
    if isinstance(obj, int):
        return "int"
    if isinstance(obj, float):
        return "double"
    if isinstance(obj, str):
        return "String"
    if isinstance(obj, list):
        return "List"
    if isinstance(obj, dict):
        return "Map"
    if isinstance(obj, BallSet):
        return "Set"
    return type(obj).__name__


def getfield(obj, name):
    if name == "runtimeType":
        return _runtime_type_name(obj)
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
        # An actual key wins over a Dart Map getter of the same name — the loaded
        # proto view has literal fields named `values` (ListValue.values),
        # `keys`, `entries`, `length`, so a proto message's own field must take
        # precedence (the engine's `.values` on a plain Dart map has no such key
        # and still falls through to the getter below).
        if name in obj:
            return obj[name]
        alias = _FIELD_ALIAS.get(name)
        if alias is not None and alias in obj:
            return obj[alias]
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
        if name == "entries":
            return [MapEntry(k, v) for k, v in obj.items()]
        # Proto-message field access on the loaded program view: an absent field
        # reads as its proto3 default. Returning None (and letting iterate(None)
        # -> [] and truthy(None) -> false handle repeated/scalar defaults) matches
        # how the reference loaders materialise defaults.
        return obj.get(name)
    if isinstance(obj, BallSet):
        if name == "length":
            return len(obj)
        if name == "isEmpty":
            return len(obj) == 0
        if name == "isNotEmpty":
            return len(obj) > 0
    if isinstance(obj, BallMap):
        ent = obj.entries
        if name == "length":
            return len(ent)
        if name == "isEmpty":
            return len(ent) == 0
        if name == "isNotEmpty":
            return len(ent) > 0
        if name == "keys":
            return list(ent.keys())
        if name == "values":
            return list(ent.values())
        # fall through to attribute access (entries, and BallObject fields).
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
    if isinstance(target, BallMap):
        return target.entries.get(key)
    raise TypeError(f"ball: cannot index {type(target).__name__}")


def index_set(target, key, value):
    if isinstance(target, list):
        target[int(key)] = value
        return value
    if isinstance(target, dict):
        target[key] = value
        return value
    # A class instance overriding `operator []=` (emitted as __op_set_index__);
    # dispatch to it so BallObject's field bookkeeping runs.
    op = getattr(target, "__op_set_index__", None)
    if op is not None:
        op({"key": key, "value": value})
        return value
    if isinstance(target, BallMap):
        target.entries[key] = value
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
    if isinstance(value, BallMap):
        return list(value.entries.keys())
    if value is None:
        return []
    return list(value)
