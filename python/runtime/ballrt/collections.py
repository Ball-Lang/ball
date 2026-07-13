"""std_collections base ops over native lists / dicts / :class:`BallSet`.

Lists and maps are native Python ``list``/``dict`` (mutable, insertion-ordered);
sets are :class:`~ballrt.values.BallSet`. Mutating ops return the same object
(Dart's reference semantics) or, for the ``add``/``push`` family, the mutated
collection so the value can flow onward.
"""

from __future__ import annotations

from . import ops
from .values import BallSet


# ── Lists ────────────────────────────────────────────────────────────────────

def list_get(lst, index):
    return lst[int(index)]


def list_length(lst):
    return len(lst)


def list_is_empty(lst):
    return len(lst) == 0


def list_is_not_empty(lst):
    return len(lst) > 0


def list_first(lst):
    return lst[0]


def list_last(lst):
    return lst[-1]


def list_contains(lst, value):
    # The Dart -> Ball encoder is syntactic, so `String.contains` cross-routes
    # here; accept a string receiver as well as a list (mirrors the Go runtime's
    # polymorphic ListContains).
    if isinstance(lst, str):
        return value in lst
    return any(ops.equals(x, value) for x in lst)


def list_index_of(lst, value):
    if isinstance(lst, str):
        return lst.find(value)
    for i, x in enumerate(lst):
        if ops.equals(x, value):
            return i
    return -1


def list_reverse(lst):
    return list(reversed(lst))


def list_concat(lst, other):
    # This is also the target of Dart's `Map.addAll` / `Set.addAll` (the
    # syntactic encoder cannot see the receiver type and mis-routes them here).
    # A map/set receiver therefore merges in place (Dart addAll mutates and the
    # engine reassigns the result); only a genuine list receiver concatenates.
    if isinstance(lst, dict):
        if isinstance(other, dict):
            lst.update(other)
        else:
            from .values import iterate
            for k in iterate(other):
                lst[k] = other[k] if isinstance(other, dict) else k
        return lst
    if isinstance(lst, BallSet):
        from .values import iterate
        for it in iterate(other):
            lst.add(it)
        return lst
    from .values import iterate
    return list(iterate(lst)) + list(iterate(other))


def list_slice(lst, start, end):
    return lst[int(start):int(end)]


def list_take(lst, count):
    return lst[:int(count)]


def list_drop(lst, count):
    return lst[int(count):]


def list_push(lst, value):
    lst.append(value)
    return lst


def list_pop(lst):
    return lst.pop()


def list_insert(lst, index, value):
    lst.insert(int(index), value)
    return lst


def list_remove_at(lst, index):
    return lst.pop(int(index))


def list_set(lst, index, value):
    lst[int(index)] = value
    return value


def list_clear(lst):
    lst.clear()
    return lst


def list_map(lst, callback):
    return [callback(x) for x in lst]


def list_filter(lst, callback):
    return [x for x in lst if ops.truthy(callback(x))]


def list_all(lst, callback):
    return all(ops.truthy(callback(x)) for x in lst)


def list_any(lst, callback):
    return any(ops.truthy(callback(x)) for x in lst)


def list_join(lst, separator):
    return ops.to_str(separator).join(ops.to_str(x) for x in lst)


def list_to_list(lst):
    return list(lst)


def _cmp_key(compare):
    import functools

    return functools.cmp_to_key(lambda a, b: int(compare({"a": a, "b": b})))


def list_sort(lst, compare):
    if compare is None:
        lst.sort(key=lambda x: (str(type(x)), x))
    else:
        lst.sort(key=_cmp_key(compare))
    return lst


# ── Maps ─────────────────────────────────────────────────────────────────────

def map_get(mp, key):
    return mp.get(key)


def map_set(mp, key, value):
    mp[key] = value
    return value


def map_delete(mp, key):
    return mp.pop(key, None)


def map_contains_key(mp, key):
    return key in mp


def map_contains_value(mp, value):
    return any(ops.equals(v, value) for v in mp.values())


def map_keys(mp):
    return list(mp.keys())


def map_values(mp):
    return list(mp.values())


def map_length(mp):
    return len(mp)


def map_is_empty(mp):
    return len(mp) == 0


def map_put_if_absent(mp, key, value):
    # Dart Map.putIfAbsent's second argument is an ifAbsent *callback*, invoked
    # only when the key is missing (`map[key] = val is Function ? val() : val`).
    if key not in mp:
        mp[key] = value(None) if callable(value) else value
    return mp[key]


# ── Sets ─────────────────────────────────────────────────────────────────────

def set_create(items=None):
    if items is None:
        return BallSet()
    return BallSet(list(items))


def set_add(st, value):
    st.add(value)
    return st


def set_remove(st, value):
    st.remove(value)
    return st


def set_contains(st, value):
    return st.contains(value)


def set_length(st):
    return len(st)


def set_is_empty(st):
    return len(st) == 0


def set_to_list(st):
    return list(st)


def set_union(a, b):
    return BallSet(list(a) + list(b))


def set_intersection(a, b):
    return BallSet([x for x in a if b.contains(x)])


def set_difference(a, b):
    return BallSet([x for x in a if not b.contains(x)])
