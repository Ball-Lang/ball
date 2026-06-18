# Conformance Test Gap Analysis

**Updated:** 2026-06-07 | **Audit scope:** `tests/conformance/` (hand-written + encoder-generated)

---

## Executive Summary

| Metric | Value |
|--------|-------|
| Total std base functions in `std.json` | **118** |
| Covered by conformance programs | **79 (67%)** |
| Uncovered | **39 (33%)** |
| Conformance programs (`.ball.json`) | **288** |
| Dart sources (`src/*.dart`) | **282** |
| Skipped (no entry function / no stdout) | **4** (196, 197, 201, 202 — sandbox/security tests) |

---

## Engine Conformance Status

Engine pass counts are maintained in `.github/workflows/regression-gates.yml`
(the CI-enforced floor). Check that file for the current exact numbers.

The C++ compiled leg is wired into the CI conformance matrix (`conformance-matrix.yml`).

---

## Std Functions WITH Conformance Coverage (79/118)

### Arithmetic (7/7)
`add`, `subtract`, `multiply`, `divide`, `divide_double`, `modulo`, `negate`

### Comparison (6/6)
`equals`, `not_equals`, `less_than`, `greater_than`, `lte`, `gte`

### Logical (3/3)
`and`, `or`, `not`

### Bitwise (6/7)
`bitwise_and`, `bitwise_or`, `bitwise_xor`, `bitwise_not`, `left_shift`, `right_shift`
- **Missing:** `unsigned_right_shift`

### Increment/Decrement (4/4)
`pre_increment`, `pre_decrement`, `post_increment`, `post_decrement`

### Control Flow (7/8)
`if`, `for`, `for_in`, `while`, `do_while`, `switch`, `label`
- **Missing:** `goto`

### Error Handling (3/3)
`try`, `throw`, `rethrow`

### Flow Control (3/3)
`return`, `break`, `continue`

### Assignment (1/1)
`assign`

### Null Safety (2/2)
`null_coalesce`, `null_check`

### Type Operations (2/4)
`is`, `as`
- **Missing:** `is_not`, `assert`

### Indexing (1/1)
`index`

### Async/Generators (2/2)
`await`, `yield`

### Print (1/1)
`print`

### String & Conversion (5/8)
`concat`, `to_string`, `string_to_int`, `string_to_lower`, `string_to_upper`
- **Missing:** `int_to_string`, `double_to_string`, `string_to_double`

### Strings (16/21)
`string_substring`, `string_trim`, `string_trim_start`, `string_trim_end`,
`string_split`, `string_length`, `string_is_empty`, `string_index_of`,
`string_last_index_of`, `string_starts_with`, `string_ends_with`,
`string_replace`, `string_replace_all`, `string_pad_left`, `string_pad_right`,
`string_repeat`
- **Missing:** `string_char_at`, `string_char_code_at`, `string_from_char_code`,
  `string_concat`, `string_contains`

### Math (10/31)
`math_abs`, `math_ceil`, `math_clamp`, `math_floor`, `math_gcd`, `math_is_infinite`,
`math_is_nan`, `math_round`, `math_sign`, `math_trunc`
- **Missing:** 21 functions (see below)

---

## Std Functions WITHOUT Conformance Coverage (39)

### Tier 1 — Conversion gaps (encodable now, high impact)

| Function | Notes |
|----------|-------|
| `int_to_string` | Dart `.toString()` on int — encoder routes to `to_string` |
| `double_to_string` | Dart `.toString()` on double — same |
| `string_to_double` | `double.parse()` — encoder can't route without type resolution |
| `length` | Generic length op — encoder routes to `string_length` or `list_length` |

### Tier 2 — String gaps (encoder routes exist but need testing)

| Function | Notes |
|----------|-------|
| `string_char_at` | `s[i]` — encoder routes to `index`, not `string_char_at` |
| `string_char_code_at` | `s.codeUnitAt(i)` — encoder route exists |
| `string_from_char_code` | `String.fromCharCode(c)` — static method, encoder needs routing |
| `string_concat` | Duplicate of `concat` — semantically covered |
| `string_contains` | `s.contains(x)` — routes to `list_contains` (encoder ambiguity) |

### Tier 3 — Math gaps (need `dart:math` import, encoder can't route)

| Function | Category |
|----------|----------|
| `math_sin`, `math_cos`, `math_tan` | Trig |
| `math_asin`, `math_acos`, `math_atan` | Inverse trig |
| `math_atan2` | Two-arg inverse trig |
| `math_sqrt`, `math_pow` | Power/root |
| `math_log`, `math_log2`, `math_log10` | Logarithms |
| `math_exp` | Exponential |
| `math_min`, `math_max` | Min/max |
| `math_pi`, `math_e` | Constants |
| `math_infinity`, `math_nan` | Special values |
| `math_is_finite` | Finite check (encoder routes but int/double ambiguity) |
| `math_lcm` | LCM (no Dart method — needs manual impl) |

### Tier 4 — Regex (5 functions, no encoder support)

| Function | Notes |
|----------|-------|
| `regex_match` | `RegExp.hasMatch` — encoder can't route RegExp |
| `regex_find` | `RegExp.firstMatch` |
| `regex_find_all` | `RegExp.allMatches` |
| `regex_replace` | `replaceFirst(RegExp(...))` |
| `regex_replace_all` | `replaceAll(RegExp(...))` |

### Tier 5 — Low usage / niche

| Function | Notes |
|----------|-------|
| `is_not` | `x is! T` — encoder needs routing |
| `assert` | Debug assertion — no output on success |
| `goto` | Rarely used in Ball programs |
| `unsigned_right_shift` | `>>>` operator |

---

## Encoder Limitations (blockers for coverage expansion)

The Dart encoder uses `parseString` (no type resolution), so it dispatches by
syntax and name heuristics. Key limitations that prevent full coverage:

1. **`dart:math` functions** (`sin`, `cos`, `sqrt`, etc.) are top-level functions
   requiring an import — the encoder doesn't map imported function calls to Ball
   std functions. (21 math functions blocked.)

2. **List/String method ambiguity** — `contains`, `indexOf` route to `list_*`
   variants regardless of receiver type. String-specific versions
   (`string_contains`, `string_index_of`) exist in the engine but the encoder
   can't distinguish them without type info.

3. **Static methods** — `String.fromCharCode`, `double.parse`, `int.parse` are
   not routed to Ball std functions.

4. **RegExp** — `RegExp` class construction and methods have no encoder mapping.

### Recent encoder improvements (June 2026)

Added getter property routes: `sign`→`math_sign`, `isNaN`→`math_is_nan`,
`isFinite`→`math_is_finite`, `isInfinite`→`math_is_infinite`,
`isEmpty`→`string_is_empty`, `isNotEmpty`→`not(string_is_empty)`.

Added method routes: `replaceFirst`→`string_replace`,
`lastIndexOf`→`string_last_index_of`, `gcd`→`math_gcd`.

Fixed field names: `startsWith`/`endsWith` use `left`/`right` (not
`value`/`pattern`); `padLeft`/`padRight` use `padding` (not `fill`).

---

## Module Coverage (Non-std)

| Module | Functions | Approx. Coverage | Notes |
|--------|-----------|:----------------:|-------|
| `std` (core) | 118 | 67% (79/118) | See above |
| `std_collections` | ~53 | ~30% | list/map ops exercised by many programs |
| `std_io` | ~10 | ~5% | `print` is in `std`, not `std_io`; minimal `std_io` coverage (exit, env_get, args_get) |
| `std_memory` | ~38 | 0% | Linear memory (C/C++ interop) |
| `std_convert` | ~8 | ~80% | json/utf8/base64 now covered (conformance 185-191) |
| `std_time` | ~6 | ~50% | format/parse timestamp covered (conformance 188) |

---

## Priority Recommendations

1. **Hand-write Ball JSON** for the 21 math functions (bypasses the `dart:math`
   import limitation). These are simple unary/binary calls.
2. **Fix encoder** for `String.fromCharCode`, `double.parse`, `int.parse`
   (static method routing) — unblocks 3-4 more conformance programs.
3. **Add `is_not`** encoder routing (`x is! T` → `std.is_not`) — trivial.
4. **Regex** requires encoder support for `RegExp` class → lowest priority.
