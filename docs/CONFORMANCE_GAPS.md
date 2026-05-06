# Conformance Test Gap Analysis

**Generated:** 2026-05-06 | **Audit scope:** `tests/conformance/` (hand-written) + `tests/fixtures/dart/_generated/` (encoder-generated)

---

## Executive Summary

| Metric | Value |
|--------|-------|
| Total std functions in `std.dart` | **118** |
| Std functions with conformance coverage | **52 (44%)** |
| Std functions without conformance coverage | **66 (56%)** |
| Hand-written conformance fixtures | **135** (all PASS) |
| Encoder-generated conformance fixtures | **37** (all PASS) |
| Total fixtures | **172** |
| Failures | **0** |
| Skipped (missing expected output) | **0** |

---

## Pass/Fail Detail

All **172** conformance tests pass on the Dart engine. No failures or skips.

| Source | Total | Pass | Fail | Skip |
|--------|------:|-----:|-----:|-----:|
| Hand-written (`tests/conformance/*.ball.json`) | 135 | 135 | 0 | 0 |
| Encoder-generated (`tests/fixtures/dart/_generated/*.ball.json`) | 37 | 37 | 0 | 0 |
| **Total** | **172** | **172** | **0** | **0** |

> **Note:** The standalone runner at `tests/conformance/run_conformance.dart` has import path issues (cannot resolve `package:ball_engine`). Tests were run via `dart test test/conformance_test.dart` from `dart/engine/`.

---

## Std Functions WITH Conformance Coverage (52)

### I/O
- `print`

### Arithmetic (7/7)
- `add`, `subtract`, `multiply`, `divide`, `divide_double`, `modulo`, `negate`

### Comparison (6/6)
- `equals`, `not_equals`, `less_than`, `greater_than`, `lte`, `gte`

### Logical (3/3)
- `and`, `or`, `not`

### Bitwise (6/7)
- `bitwise_and`, `bitwise_or`, `bitwise_xor`, `bitwise_not`, `left_shift`, `right_shift`
- **Missing:** `unsigned_right_shift`

### Increment/Decrement (2/4)
- `post_increment`, `post_decrement`
- **Missing:** `pre_increment`, `pre_decrement`

### String & Conversion (3/7)
- `concat`, `to_string`, `string_to_int`
- **Missing:** `length`, `int_to_string`, `double_to_string`, `string_to_double`

### Null Safety (2/2)
- `null_coalesce`, `null_check`

### Control Flow (6/6)
- `if`, `for`, `for_in`, `while`, `do_while`, `switch`

### Error Handling (3/3)
- `try`, `throw`, `rethrow`

### Flow Control (3/3)
- `return`, `break`, `continue`

### Assignment (1/1)
- `assign`

### Type Operations (1/3)
- `is`
- **Missing:** `is_not`, `as`

### Indexing (1/1)
- `index`

### Strings (partial — 6/23)
- `string_substring`, `string_to_upper`, `string_to_lower`, `string_trim`, `string_split`
- `concat` (also counts for string_concat coverage)
- **Missing:** 17 others (see below)

### Math (2/31)
- `math_abs`, `math_clamp`
- **Missing:** 29 others (see below)

---

## Std Functions WITHOUT Conformance Coverage (66)

### Tier 1 — Critical Gaps (high-use, no coverage)

These are functions that existing tests likely exercise indirectly or that are frequently used in practice:

| Function | Category | Notes |
|----------|----------|-------|
| `length` | String & Conversion | Generic length op; used in many contexts |
| `int_to_string` | String & Conversion | Used in `to_string` for ints |
| `double_to_string` | String & Conversion | Used in `to_string` for doubles |
| `string_to_double` | String & Conversion | Parse double from string |
| `string_concat` | Strings | Duplicate of `concat` — likely covered already |
| `string_length` | Strings | String-specific length |
| `string_char_at` | Strings | Character access by index |
| `string_contains` | Strings | Substring containment |
| `string_trim_start` | Strings | Left trim |
| `string_trim_end` | Strings | Right trim |
| `math_min` | Math | Minimum of two values |
| `math_max` | Math | Maximum of two values |
| `math_pow` | Math | Exponentiation |
| `math_sqrt` | Math | Square root |
| `math_gcd` | Math | GCD algorithm |
| `assert` | Assertions | Debug assertion |

### Tier 2 — Moderate Gaps (useful, less critical)

| Function | Category |
|----------|----------|
| `pre_increment` | Increment/Decrement |
| `pre_decrement` | Increment/Decrement |
| `unsigned_right_shift` | Bitwise |
| `is_not` | Type Operations |
| `as` | Type Operations |
| `string_is_empty` | Strings |
| `string_starts_with` | Strings |
| `string_ends_with` | Strings |
| `string_index_of` | Strings |
| `string_last_index_of` | Strings |
| `string_char_code_at` | Strings |
| `string_from_char_code` | Strings |
| `string_replace` | Strings |
| `string_replace_all` | Strings |
| `string_repeat` | Strings |
| `string_pad_left` | Strings |
| `string_pad_right` | Strings |

### Tier 3 — Regex (no coverage at all)

| Function | Category |
|----------|----------|
| `regex_match` | Regex |
| `regex_find` | Regex |
| `regex_find_all` | Regex |
| `regex_replace` | Regex |
| `regex_replace_all` | Regex |

### Tier 4 — Math (29/31 functions missing coverage)

| Function | Category |
|----------|----------|
| `math_floor` | Math |
| `math_ceil` | Math |
| `math_round` | Math |
| `math_trunc` | Math |
| `math_sqrt` | Math |
| `math_pow` | Math |
| `math_log` | Math |
| `math_log2` | Math |
| `math_log10` | Math |
| `math_exp` | Math |
| `math_sin` | Math |
| `math_cos` | Math |
| `math_tan` | Math |
| `math_asin` | Math |
| `math_acos` | Math |
| `math_atan` | Math |
| `math_atan2` | Math |
| `math_min` | Math |
| `math_max` | Math |
| `math_pi` | Math |
| `math_e` | Math |
| `math_infinity` | Math |
| `math_nan` | Math |
| `math_is_nan` | Math |
| `math_is_finite` | Math |
| `math_is_infinite` | Math |
| `math_sign` | Math |
| `math_gcd` | Math |
| `math_lcm` | Math |

### Tier 5 — Advanced/Async (low usage)

| Function | Category |
|----------|----------|
| `switch_expr` | Control Flow (not in std.dart — engine-only) |
| `goto` | Control Flow |
| `label` | Control Flow |
| `yield` | Generators |
| `await` | Async |

---

## Module Coverage (Non-std)

The `std_collections`, `std_io`, `std_memory`, and `dart_std` modules also lack dedicated conformance fixtures. Their functions are exercised only through composite programs that happen to call them (e.g., `list_push`, `map_create`, `set_create` appear in some hand-written fixtures).

| Module | Functions | Functions in Conformance | Est. Coverage |
|--------|-----------|------------------------:|:-------------:|
| `std` (core) | 118 | 52 | 44% |
| `std_collections` | ~43 | ~3 (map_create, set_create, list_push) | ~7% |
| `std_io` | ~10 | 0 | 0% |
| `std_memory` | ~30 | 0 | 0% |
| `dart_std` | ~18 | 0 | 0% |

---

## Top Priority Gaps by Frequency of Use

Ranked by likely impact on cross-language compatibility:

1. **`length`** — fundamental operation, used constantly
2. **`int_to_string` / `double_to_string`** — basic type conversion
3. **`string_to_double`** — parsing
4. **`math_min` / `math_max`** — basic math
5. **`assert`** — debugging
6. **`string_contains`** — very common string operation
7. **`math_sqrt` / `math_pow`** — common math operations
8. **`pre_increment` / `pre_decrement`** — basic increment ops
9. **`unsigned_right_shift`** — bitwise completeness
10. **`is_not` / `as`** — type operations

---

## Methodology

1. Extracted all 118 base function names from `dart/shared/lib/std.dart`
2. Searched all hand-written fixtures (`tests/conformance/*.ball.json`) for `"module":"std","function":"FN"` call patterns
3. Searched all encoder-generated fixtures (`tests/fixtures/dart/_generated/*.ball.json`) for the same pattern
4. Cross-referenced to identify functions with zero call sites across both fixture sets
5. Ran `dart test test/conformance_test.dart` from `dart/engine/` to capture pass/fail/skip counts
6. Categorized missing functions by priority tiers

---

## Recommended Actions

1. **Add conformance fixtures for Tier 1 gaps** — these are the most impactful missing tests
2. **Add conformance fixtures for Regex** (Tier 3) — all 5 regex functions have zero coverage
3. **Add representative Math fixtures** (Tier 4) — focus on the most commonly used: sqrt, pow, min, max, floor, ceil, round, gcd, sign
4. **Add async/generator fixtures** for `await` and `yield` once those features stabilize
5. **Extend coverage to non-std modules** (`std_collections`, `std_io`, `std_memory`, `dart_std`) in future waves
