<!-- Parent: ../AGENTS.md -->

# ballrt — Python runtime for compiled Ball programs

Zero-dependency (Python stdlib only, >= 3.11). A program compiled by
`ball_compiler` does `import ballrt` and calls the flat helpers re-exported from
`ballrt/__init__.py`; nothing else is required to run it, so a compiled program
runs offline.

## Modules
| File | Role |
|------|------|
| `ballrt/ops.py` | Arithmetic / comparison / logic / string / numeric-format ops with **Dart-exact** semantics. |
| `ballrt/values.py` | Value model: `BallSet` (insertion-ordered), argument-message access (`arg`), field / index access, iteration. |
| `ballrt/collections.py` | `std_collections` list / map / set ops (namespaced `ballrt.col.*`). |
| `ballrt/flow.py` | `break`/`continue`/`return`/`throw` as exceptions + the `ret`/`brk`/`cont`/`throw`/`rethrow` helper calls that raise them. |
| `ballrt/io.py` | `print_` / `print_error` and `run_entry` (the entry-point driver). |

## Value model
Ball values are native Python: `int`/`float`/`str`/`bool`/`None` and
insertion-ordered `list`/`dict`. Sets are `BallSet`; user-type instances are
ordinary Python objects (the compiler emits real classes).

## Dart-exact quirks (do not "simplify" to Python defaults)
- `intdiv` (`~/`) truncates toward zero; Python `//` floors.
- `modulo` (`%`) is always in `[0, |b|)`; Python `%` follows the divisor sign.
- `int + int` stays `int`; `int + double` promotes to `float`.
- Integer arithmetic (`add`/`subtract`/`multiply`/`negate`/`intdiv`/`math_abs`)
  wraps to signed 64-bit (Dart ints are 64-bit two's-complement), and
  `to_int` on a double truncates toward zero then clamps to the int64 range.
- `to_str` on an integral double keeps `.0`; non-finite -> `Infinity`/`-Infinity`/`NaN`.
- `equals` does not conflate `bool` with `1`/`0` (Python treats `bool` as `int`).
- `length`/`String.length` counts **UTF-16 code units** (a non-BMP char is 2).
- `to_string_as_fixed`/`Exponential`/`Precision` round half away from zero and
  keep a negative receiver's sign even when the magnitude rounds to zero.
- `list_contains`/`list_index_of` also accept a **string** receiver, because the
  syntactic Dart->Ball encoder cross-routes `String.contains`/`indexOf` here.

## Testing
Runtime semantics are unit-tested in `../compiler/tests/test_runtime.py`, and
exercised end-to-end by the golden-exact conformance gate
(`../compiler/tests/test_conformance.py`).
