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
    ceil_to_double,
    floor_to_double,
    math_clamp,
    math_gcd,
    math_is_finite,
    math_is_infinite,
    math_min,
    round_to_double,
    string_runes,
    truncate_to_double,
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
    BallMap,
    BallSet,
    BallValue,
    arg,
    call_fn,
    getfield,
    index_get,
    index_set,
    invoke,
    iterate,
    make_ball_map,
    setfield,
)
from .methods import call_method, identical
from .selfhost import (
    RegExp,
    StateError,
    StringBuffer,
    arm,
    as_type,
    dm,
    datetime_from_ms,
    datetime_now,
    datetime_parse,
    make_ball_bool,
    make_ball_double,
    make_ball_int,
    make_ball_list,
    make_ball_string,
    make_duration,
    make_json_decoder,
    make_json_encoder,
    make_regexp,
    make_state_error,
    make_string_buffer,
    stack_trace_of,
    double_infinity,
    double_max_finite,
    double_min_positive,
    double_nan,
    double_negative_infinity,
    double_parse,
    double_try_parse,
    function_apply,
    int_parse,
    int_try_parse,
    io_stub,
    is_type,
    list_filled,
    list_generate,
    map_unmodifiable,
    num_parse,
    num_try_parse,
    set_unmodifiable,
    string_from_char_code,
    string_from_char_codes,
    ty_DateTime,
    ty_Function,
    ty_Future,
    ty_List,
    ty_Map,
    ty_Set,
    ty_String,
    ty_double,
    ty_int,
    ty_num,
)
from . import collections as _collections
from . import convert as _convert
from . import proto as _proto

# std_collections ops are namespaced under ballrt.col.* in emitted code;
# std_convert under ballrt.cvt.*; ball_proto access patterns under ballrt.proto.*.
col = _collections
cvt = _convert
proto = _proto

__all__ = [name for name in globals() if not name.startswith("_")]
