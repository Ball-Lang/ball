"""Dart-SDK method dispatch for the self-hosted engine.

The reference engine (Ball-portable Dart) calls a handful of Dart SDK methods on
values as *method calls* (`list.addAll(x)`, `regexp.firstMatch(s)`, …) rather
than through std base functions. The compiler routes those (any receiver-method
whose name is not a user method) to :func:`call_method`, which dispatches by
receiver type. User/runtime objects (RegExp, StringBuffer, …) implement the
method directly; Python builtins go through the dispatch table below with
Dart-exact semantics.
"""

from __future__ import annotations

from . import ops
from . import proto as _proto
from .flow import throw
from .values import BallMap, BallSet, invoke, iterate

_BUILTIN = (list, dict, str, int, float, bool)


def identical(a, b):
    """Dart ``identical(a, b)`` — reference identity. Used by the engine to test
    against sentinel singletons; ``is`` is the right primitive for that."""
    return a is b


def call_method(recv, name, *args):
    # A native protobuf presence accessor (`msg.hasValue()`, `binding.hasBody()`)
    # — encoded as a method call — is a presence check on the underlying field.
    if len(name) > 3 and name.startswith("has") and name[3].isupper():
        field = name[3].lower() + name[4:]
        target = recv.entries if isinstance(recv, BallMap) else recv
        return _proto._has(target, field)
    # A runtime/user object (RegExp, StringBuffer, a Ball class instance, …)
    # implements the method directly; builtins go through the dispatch table so
    # Dart semantics (not Python's) apply.
    if not isinstance(recv, _BUILTIN) and not isinstance(recv, BallSet):
        fn = getattr(recv, name, None)
        if callable(fn):
            return fn(*args)
    handler = _DISPATCH.get(name)
    if handler is None:
        return throw(f"unsupported method .{name} on {type(recv).__name__}")
    return handler(recv, *args)


# ── Handlers (receiver, *args) ───────────────────────────────────────────────

def _remove(recv, x):
    if isinstance(recv, list):
        for i, it in enumerate(recv):
            if ops.equals(it, x):
                del recv[i]
                return True
        return False
    if isinstance(recv, dict):
        if x in recv:
            recv.pop(x)
            return True
        return False
    if isinstance(recv, BallSet):
        return recv.remove(x)
    return throw(f"unsupported .remove on {type(recv).__name__}")


def _add_all(recv, other):
    items = iterate(other)
    if isinstance(recv, list):
        recv.extend(items)
        return recv
    if isinstance(recv, dict):
        if isinstance(other, dict):
            recv.update(other)
        else:
            for it in items:
                recv[it] = other[it] if isinstance(other, dict) else it
        return recv
    if isinstance(recv, BallSet):
        for it in items:
            recv.add(it)
        return recv
    return throw(f"unsupported .addAll on {type(recv).__name__}")


def _clear(recv):
    if isinstance(recv, (list, dict)):
        recv.clear()
        return None
    if isinstance(recv, BallSet):
        recv._items.clear()
        return None
    return throw(f"unsupported .clear on {type(recv).__name__}")


def _cast(recv, *_):
    # Dart <T>.cast<R>() is a typed view; in dynamic Python it is the identity.
    return recv


def _to_set(recv, *_):
    return BallSet(iterate(recv))


def _take(recv, n):
    return list(iterate(recv))[: int(n)]


def _skip(recv, n):
    return list(iterate(recv))[int(n):]


def _element_at(recv, i):
    return list(iterate(recv))[int(i)]


def _fold(recv, initial, combine):
    acc = initial
    for el in iterate(recv):
        acc = invoke(combine, {"arg0": acc, "arg1": el})
    return acc


def _index_where(recv, test):
    for i, el in enumerate(iterate(recv)):
        if ops.truthy(invoke(test, el)):
            return i
    return -1


def _set_all(recv, index, iterable):
    i = int(index)
    for off, v in enumerate(iterate(iterable)):
        recv[i + off] = v
    return None


def _union(recv, other):
    out = BallSet(iterate(recv))
    for it in iterate(other):
        out.add(it)
    return out


def _intersection(recv, other):
    ob = BallSet(iterate(other))
    return BallSet(it for it in iterate(recv) if ob.contains(it))


def _difference(recv, other):
    ob = BallSet(iterate(other))
    return BallSet(it for it in iterate(recv) if not ob.contains(it))


def _remainder(recv, other):
    # Dart num.remainder: truncated remainder, result carries the dividend's sign.
    from .ops import intdiv
    return recv - intdiv(recv, other) * other


def _to_int(recv, *_):
    return ops.to_int(recv)


def _contains(recv, x):
    if isinstance(recv, BallSet):
        return recv.contains(x)
    if isinstance(recv, dict):
        return x in recv
    for it in iterate(recv):
        if ops.equals(it, x):
            return True
    return False


def _contains_key(recv, k):
    return k in recv


def _contains_value(recv, v):
    for it in recv.values():
        if ops.equals(it, v):
            return True
    return False


def _put_if_absent(recv, key, ifabsent):
    if key not in recv:
        recv[key] = invoke(ifabsent, None)
    return recv[key]


def _update(recv, key, update, *rest):
    if key in recv:
        recv[key] = invoke(update, recv[key])
    elif rest:
        # ifAbsent is passed as a packed {ifAbsent: fn}; accept a bare fn too.
        ia = rest[0]
        if isinstance(ia, dict) and "ifAbsent" in ia:
            ia = ia["ifAbsent"]
        recv[key] = invoke(ia, None)
    return recv.get(key)


def _for_each(recv, fn):
    if isinstance(recv, dict):
        for k, v in list(recv.items()):
            invoke(fn, {"arg0": k, "arg1": v, "key": k, "value": v})
    else:
        for it in iterate(recv):
            invoke(fn, it)
    return None


def _map(recv, fn):
    return [invoke(fn, it) for it in iterate(recv)]


def _where(recv, test):
    return [it for it in iterate(recv) if ops.truthy(invoke(test, it))]


def _any(recv, test):
    return any(ops.truthy(invoke(test, it)) for it in iterate(recv))


def _every(recv, test):
    return all(ops.truthy(invoke(test, it)) for it in iterate(recv))


def _join(recv, sep=""):
    return ops.to_str(sep).join(ops.to_str(it) for it in iterate(recv))


def _reduce(recv, combine):
    items = list(iterate(recv))
    if not items:
        return throw("Bad state: No element")
    acc = items[0]
    for el in items[1:]:
        acc = invoke(combine, {"arg0": acc, "arg1": el})
    return acc


def _first_where(recv, test, *rest):
    for it in iterate(recv):
        if ops.truthy(invoke(test, it)):
            return it
    if rest and isinstance(rest[0], dict) and "orElse" in rest[0]:
        return invoke(rest[0]["orElse"], None)
    return throw("Bad state: No element")


def _index_of(recv, x, *rest):
    start = int(rest[0]) if rest else 0
    if isinstance(recv, str):
        return recv.find(ops.to_str(x), start)
    for i in range(start, len(recv)):
        if ops.equals(recv[i], x):
            return i
    return -1


def _sublist(recv, start, *rest):
    end = int(rest[0]) if rest and rest[0] is not None else len(recv)
    return recv[int(start):end]


def _get_range(recv, start, end):
    return recv[int(start):int(end)]


def _insert(recv, index, value):
    recv.insert(int(index), value)
    return None


def _remove_at(recv, index):
    return recv.pop(int(index))


def _remove_last(recv):
    return recv.pop()


def _add(recv, value):
    if isinstance(recv, BallSet):
        return recv.add(value)
    recv.append(value)
    return None


def _sort(recv, *rest):
    import functools
    if rest and rest[0] is not None:
        cmp = rest[0]
        recv.sort(key=functools.cmp_to_key(
            lambda a, b: int(invoke(cmp, {"arg0": a, "arg1": b}))))
    else:
        recv.sort(key=functools.cmp_to_key(ops.compare_to))
    return None


def _expand(recv, fn):
    out = []
    for it in iterate(recv):
        out.extend(iterate(invoke(fn, it)))
    return out


def _as_map(recv, *_):
    return {i: v for i, v in enumerate(iterate(recv))}


_DISPATCH = {
    "remove": _remove,
    "addAll": _add_all,
    "clear": _clear,
    "cast": _cast,
    "toSet": _to_set,
    "toList": lambda r, *a: list(iterate(r)),
    "take": _take,
    "skip": _skip,
    "elementAt": _element_at,
    "fold": _fold,
    "indexWhere": _index_where,
    "setAll": _set_all,
    "union": _union,
    "intersection": _intersection,
    "difference": _difference,
    "remainder": _remainder,
    "toInt": _to_int,
    "toDouble": lambda r, *a: float(r),
    "contains": _contains,
    "containsKey": _contains_key,
    "containsValue": _contains_value,
    "putIfAbsent": _put_if_absent,
    "update": _update,
    "forEach": _for_each,
    "map": _map,
    "where": _where,
    "any": _any,
    "every": _every,
    "join": _join,
    "reduce": _reduce,
    "firstWhere": _first_where,
    "indexOf": _index_of,
    "sublist": _sublist,
    "getRange": _get_range,
    "insert": _insert,
    "removeAt": _remove_at,
    "removeLast": _remove_last,
    "add": _add,
    "sort": _sort,
    "expand": _expand,
    "asMap": _as_map,
}
