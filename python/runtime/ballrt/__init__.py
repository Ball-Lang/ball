"""ballrt — the zero-dependency runtime for Ball programs compiled to Python.

Compiled programs ``import ballrt`` and call the flat helpers re-exported here
(``ballrt.add``, ``ballrt.print_``, ``ballrt.ret`` …). Everything is native
Python and stdlib-only, so a compiled program runs offline with no third-party
packages. See the submodules for semantics:

* :mod:`ballrt.ops` — arithmetic / comparison / logic / string with Dart-exact
  behaviour.
* :mod:`ballrt.values` — set, argument messages, field / index access, iteration.
* :mod:`ballrt.collections` — std_collections list / map / set ops.
* :mod:`ballrt.flow` — break / continue / return / throw as exceptions.
* :mod:`ballrt.io` — console output and the entry-point driver.
"""

from __future__ import annotations

from .flow import (
    BallBreak,
    BallContinue,
    BallReturn,
    BallThrow,
    brk,
    cont,
    ret,
    rethrow,
    throw,
)
from .io import print_, print_error, run_entry
from .ops import (
    add,
    and_,
    bitwise_and,
    bitwise_not,
    bitwise_or,
    bitwise_xor,
    compare_to,
    concat,
    divide_double,
    equals,
    greater_than,
    gte,
    intdiv,
    left_shift,
    length,
    less_than,
    lte,
    math_abs,
    math_ceil,
    math_floor,
    math_max,
    math_min,
    math_pow,
    math_round,
    math_sign,
    math_sqrt,
    math_trunc,
    modulo,
    multiply,
    negate,
    not_,
    not_equals,
    null_check,
    null_coalesce,
    or_,
    right_shift,
    string_code_unit_at,
    string_concat,
    string_contains,
    string_ends_with,
    string_index_of,
    string_is_empty,
    string_last_index_of,
    string_length,
    string_pad_left,
    string_pad_right,
    string_replace,
    string_replace_all,
    string_split,
    string_starts_with,
    string_substring,
    string_to_double,
    string_to_int,
    string_to_lower,
    string_to_upper,
    string_trim,
    string_trim_end,
    string_trim_start,
    subtract,
    to_double,
    to_int,
    to_str,
    to_string_as_exponential,
    to_string_as_fixed,
    to_string_as_precision,
    truthy,
    unsigned_right_shift,
)
from .values import (
    NULL,
    BallSet,
    arg,
    call_fn,
    getfield,
    index_get,
    index_set,
    invoke,
    iterate,
    setfield,
)
from . import collections as _collections

# std_collections ops are namespaced under ballrt.col.* in emitted code.
col = _collections

__all__ = [name for name in globals() if not name.startswith("_")]
