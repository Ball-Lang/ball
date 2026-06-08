# Standard Library Completeness Tracker

**Legend:** ✅ = Implemented | ⚠️ = Partial | ❌ = Missing/Stubbed

> **Note:** Compilers emit native language equivalents (e.g., `list.push_back()` in C++, `list.add()` in Dart).
> Some functions don't need compiler support because they're only used at runtime (engine) or are
> handled by the compiler's general expression compilation. "N/A" means not applicable for that column.

---

## `std` Module — Core Operations (~90 functions)

### I/O

| Function | Dart Engine | Dart Compiler | C++ Engine | C++ Compiler |
|----------|:-----------:|:-------------:|:----------:|:------------:|
| print | ✅ | ✅ | ✅ | ✅ |

### Arithmetic

| Function | Dart Engine | Dart Compiler | C++ Engine | C++ Compiler |
|----------|:-----------:|:-------------:|:----------:|:------------:|
| add | ✅ | ✅ | ✅ | ✅ |
| subtract | ✅ | ✅ | ✅ | ✅ |
| multiply | ✅ | ✅ | ✅ | ✅ |
| divide | ✅ | ✅ | ✅ | ✅ |
| divide_double | ✅ | ✅ | ✅ | ✅ |
| modulo | ✅ | ✅ | ✅ | ✅ |
| negate | ✅ | ✅ | ✅ | ✅ |

### Comparison

| Function | Dart Engine | Dart Compiler | C++ Engine | C++ Compiler |
|----------|:-----------:|:-------------:|:----------:|:------------:|
| equals | ✅ | ✅ | ✅ | ✅ |
| not_equals | ✅ | ✅ | ✅ | ✅ |
| less_than | ✅ | ✅ | ✅ | ✅ |
| greater_than | ✅ | ✅ | ✅ | ✅ |
| lte | ✅ | ✅ | ✅ | ✅ |
| gte | ✅ | ✅ | ✅ | ✅ |

### Logical

| Function | Dart Engine | Dart Compiler | C++ Engine | C++ Compiler |
|----------|:-----------:|:-------------:|:----------:|:------------:|
| and | ✅ | ✅ | ✅ | ✅ |
| or | ✅ | ✅ | ✅ | ✅ |
| not | ✅ | ✅ | ✅ | ✅ |

### Bitwise

| Function | Dart Engine | Dart Compiler | C++ Engine | C++ Compiler |
|----------|:-----------:|:-------------:|:----------:|:------------:|
| bitwise_and | ✅ | ✅ | ✅ | ✅ |
| bitwise_or | ✅ | ✅ | ✅ | ✅ |
| bitwise_xor | ✅ | ✅ | ✅ | ✅ |
| bitwise_not | ✅ | ✅ | ✅ | ✅ |
| left_shift | ✅ | ✅ | ✅ | ✅ |
| right_shift | ✅ | ✅ | ✅ | ✅ |
| unsigned_right_shift | ✅ | ✅ | ✅ | ✅ |

### Increment/Decrement

| Function | Dart Engine | Dart Compiler | C++ Engine | C++ Compiler |
|----------|:-----------:|:-------------:|:----------:|:------------:|
| pre_increment | ✅ | ✅ | ✅ | ✅ |
| pre_decrement | ✅ | ✅ | ✅ | ✅ |
| post_increment | ✅ | ✅ | ✅ | ✅ |
| post_decrement | ✅ | ✅ | ✅ | ✅ |

### String & Conversion

| Function | Dart Engine | Dart Compiler | C++ Engine | C++ Compiler |
|----------|:-----------:|:-------------:|:----------:|:------------:|
| concat | ✅ | ✅ | ✅ | ✅ |
| length | ✅ | ✅ | ✅ | ✅ |
| to_string | ✅ | ✅ | ✅ | ✅ |
| int_to_string | ✅ | ✅ | ✅ | ✅ |
| double_to_string | ✅ | ✅ | ✅ | ✅ |
| string_to_int | ✅ | ✅ | ✅ | ✅ |
| string_to_double | ✅ | ✅ | ✅ | ✅ |
| string_interpolation | ✅ | ✅ | ✅ | ✅ |

### Null Safety

| Function | Dart Engine | Dart Compiler | C++ Engine | C++ Compiler |
|----------|:-----------:|:-------------:|:----------:|:------------:|
| null_coalesce | ✅ | ✅ | ✅ | ✅ |
| null_check | ✅ | ✅ | ✅ | ✅ |
| null_aware_access | ✅ | ✅ | ✅ | ✅ |
| null_aware_call | ✅ | ✅ | ✅ | ✅ |

### Control Flow (lazy-evaluated)

| Function | Dart Engine | Dart Compiler | C++ Engine | C++ Compiler |
|----------|:-----------:|:-------------:|:----------:|:------------:|
| if | ✅ | ✅ | ✅ | ✅ |
| for | ✅ | ✅ | ✅ | ✅ |
| for_in | ✅ | ✅ | ✅ | ✅ |
| while | ✅ | ✅ | ✅ | ✅ |
| do_while | ✅ | ✅ | ✅ | ✅ |
| switch | ✅ | ✅ | ✅ | ✅ |
| switch_expr | ✅ | ✅ | ⚠️ | ✅ |
| try | ✅ | ✅ | ✅ | ✅ |
| break | ✅ | ✅ | ✅ | ✅ |
| continue | ✅ | ✅ | ✅ | ✅ |
| return | ✅ | ✅ | ✅ | ✅ |

### Type Operations

| Function | Dart Engine | Dart Compiler | C++ Engine | C++ Compiler |
|----------|:-----------:|:-------------:|:----------:|:------------:|
| is | ✅ | ✅ | ✅ | ✅ |
| is_not | ✅ | ✅ | ✅ | ✅ |
| as | ✅ | ✅ | ✅ | ✅ |

### Indexing & Assignment

| Function | Dart Engine | Dart Compiler | C++ Engine | C++ Compiler |
|----------|:-----------:|:-------------:|:----------:|:------------:|
| index | ✅ | ✅ | ✅ | ✅ |
| assign | ✅ | ✅ | ✅ | ✅ |

### Cascade/Spread/Invoke

| Function | Dart Engine | Dart Compiler | C++ Engine | C++ Compiler |
|----------|:-----------:|:-------------:|:----------:|:------------:|
| cascade | ✅ | ✅ | ✅ | ✅ |
| spread | ✅ | ✅ | ✅ | ✅ |
| null_spread | ✅ | ✅ | ✅ | ✅ |
| invoke | ✅ | ✅ | ✅ | ✅ |

### Exceptions

| Function | Dart Engine | Dart Compiler | C++ Engine | C++ Compiler |
|----------|:-----------:|:-------------:|:----------:|:------------:|
| throw | ✅ | ✅ | ✅ | ✅ |
| rethrow | ✅ | ✅ | ✅ | ✅ |
| assert | ✅ | ✅ | ✅ | ✅ |

### Async

| Function | Dart Engine | Dart Compiler | C++ Engine | C++ Compiler |
|----------|:-----------:|:-------------:|:----------:|:------------:|
| await | ✅ | ✅ | ✅ | ✅ |
| yield | ✅ | ✅ | ✅ | ✅ |
| yield_each | ✅ | ✅ | ✅ | ✅ |

### Strings (28 functions)

| Function | Dart Engine | Dart Compiler | C++ Engine | C++ Compiler |
|----------|:-----------:|:-------------:|:----------:|:------------:|
| string_length | ✅ | ✅ | ✅ | ✅ |
| string_is_empty | ✅ | ✅ | ✅ | ✅ |
| string_concat | ✅ | ✅ | ✅ | ✅ |
| string_contains | ✅ | ✅ | ✅ | ✅ |
| string_starts_with | ✅ | ✅ | ✅ | ✅ |
| string_ends_with | ✅ | ✅ | ✅ | ✅ |
| string_index_of | ✅ | ✅ | ✅ | ✅ |
| string_last_index_of | ✅ | ✅ | ✅ | ✅ |
| string_substring | ✅ | ✅ | ✅ | ✅ |
| string_char_at | ✅ | ✅ | ✅ | ✅ |
| string_char_code_at | ✅ | ✅ | ✅ | ✅ |
| string_from_char_code | ✅ | ✅ | ✅ | ✅ |
| string_to_upper | ✅ | ✅ | ✅ | ✅ |
| string_to_lower | ✅ | ✅ | ✅ | ✅ |
| string_trim | ✅ | ✅ | ✅ | ✅ |
| string_trim_start | ✅ | ✅ | ✅ | ✅ |
| string_trim_end | ✅ | ✅ | ✅ | ✅ |
| string_replace | ✅ | ✅ | ✅ | ✅ |
| string_replace_all | ✅ | ✅ | ✅ | ✅ |
| string_split | ✅ | ✅ | ✅ | ✅ |
| string_repeat | ✅ | ✅ | ✅ | ✅ |
| string_pad_left | ✅ | ✅ | ✅ | ✅ |
| string_pad_right | ✅ | ✅ | ✅ | ✅ |

### Regex (5 functions)

| Function | Dart Engine | Dart Compiler | C++ Engine | C++ Compiler |
|----------|:-----------:|:-------------:|:----------:|:------------:|
| regex_match | ✅ | ✅ | ✅ | ✅ |
| regex_find | ✅ | ✅ | ✅ | ✅ |
| regex_find_all | ✅ | ✅ | ✅ | ✅ |
| regex_replace | ✅ | ✅ | ✅ | ✅ |
| regex_replace_all | ✅ | ✅ | ✅ | ✅ |

### Math (31 functions)

| Function | Dart Engine | Dart Compiler | C++ Engine | C++ Compiler |
|----------|:-----------:|:-------------:|:----------:|:------------:|
| math_abs | ✅ | ✅ | ✅ | ✅ |
| math_floor | ✅ | ✅ | ✅ | ✅ |
| math_ceil | ✅ | ✅ | ✅ | ✅ |
| math_round | ✅ | ✅ | ✅ | ✅ |
| math_trunc | ✅ | ✅ | ✅ | ✅ |
| math_sqrt | ✅ | ✅ | ✅ | ✅ |
| math_pow | ✅ | ✅ | ✅ | ✅ |
| math_log | ✅ | ✅ | ✅ | ✅ |
| math_log2 | ✅ | ✅ | ✅ | ⚠️ |
| math_log10 | ✅ | ✅ | ✅ | ⚠️ |
| math_exp | ✅ | ✅ | ✅ | ✅ |
| math_sin | ✅ | ✅ | ✅ | ✅ |
| math_cos | ✅ | ✅ | ✅ | ✅ |
| math_tan | ✅ | ✅ | ✅ | ⚠️ |
| math_asin | ✅ | ✅ | ✅ | ✅ |
| math_acos | ✅ | ✅ | ✅ | ✅ |
| math_atan | ✅ | ✅ | ✅ | ✅ |
| math_atan2 | ✅ | ✅ | ✅ | ✅ |
| math_min | ✅ | ✅ | ✅ | ✅ |
| math_max | ✅ | ✅ | ✅ | ✅ |
| math_clamp | ✅ | ✅ | ✅ | ✅ |
| math_pi | ✅ | ✅ | ✅ | ✅ |
| math_e | ✅ | ✅ | ✅ | ✅ |
| math_infinity | ✅ | ✅ | ✅ | ✅ |
| math_nan | ✅ | ✅ | ✅ | ✅ |
| math_is_nan | ✅ | ✅ | ✅ | ✅ |
| math_is_finite | ✅ | ✅ | ✅ | ✅ |
| math_is_infinite | ✅ | ✅ | ✅ | ✅ |
| math_sign | ✅ | ✅ | ✅ | ✅ |
| math_gcd | ✅ | ✅ | ✅ | ✅ |
| math_lcm | ✅ | ✅ | ✅ | ✅ |

---

## `std_collections` Module (~43 functions)

### List Operations (29 functions)

| Function | Dart Engine | Dart Compiler | C++ Engine | C++ Compiler |
|----------|:-----------:|:-------------:|:----------:|:------------:|
| list_push | ✅ | ✅ | ✅ | ✅ |
| list_pop | ✅ | ✅ | ✅ | ✅ |
| list_insert | ✅ | ✅ | ✅ | ✅ |
| list_remove_at | ✅ | ✅ | ✅ | ✅ |
| list_get | ✅ | ✅ | ✅ | ✅ |
| list_set | ✅ | ✅ | ✅ | ✅ |
| list_length | ✅ | ✅ | ✅ | ✅ |
| list_is_empty | ✅ | ✅ | ✅ | ✅ |
| list_first | ✅ | ✅ | ✅ | ✅ |
| list_last | ✅ | ✅ | ✅ | ✅ |
| list_single | ✅ | ✅ | ✅ | ✅ |
| list_contains | ✅ | ✅ | ✅ | ✅ |
| list_index_of | ✅ | ✅ | ✅ | ✅ |
| list_map | ✅ | ✅ | ✅ | ✅ |
| list_filter | ✅ | ✅ | ✅ | ✅ |
| list_reduce | ✅ | ✅ | ✅ | ✅ |
| list_find | ✅ | ✅ | ✅ | ✅ |
| list_any | ✅ | ✅ | ✅ | ✅ |
| list_all | ✅ | ✅ | ✅ | ✅ |
| list_none | ✅ | ✅ | ✅ | ✅ |
| list_sort | ✅ | ✅ | ✅ | ✅ |
| list_sort_by | ✅ | ✅ | ✅ | ✅ |
| list_reverse | ✅ | ✅ | ✅ | ✅ |
| list_slice | ✅ | ✅ | ✅ | ✅ |
| list_take | ✅ | ✅ | ✅ | ✅ |
| list_drop | ✅ | ✅ | ✅ | ✅ |
| list_concat | ✅ | ✅ | ✅ | ✅ |
| list_flat_map | ✅ | ✅ | ✅ | ✅ |
| list_zip | ✅ | ✅ | ✅ | ✅ |
| string_join | ✅ | ✅ | ✅ | ✅ |

### Map Operations (13 functions)

| Function | Dart Engine | Dart Compiler | C++ Engine | C++ Compiler |
|----------|:-----------:|:-------------:|:----------:|:------------:|
| map_get | ✅ | ✅ | ✅ | ✅ |
| map_set | ✅ | ✅ | ✅ | ✅ |
| map_delete | ✅ | ✅ | ✅ | ✅ |
| map_contains_key | ✅ | ✅ | ✅ | ✅ |
| map_keys | ✅ | ✅ | ✅ | ✅ |
| map_values | ✅ | ✅ | ✅ | ✅ |
| map_entries | ✅ | ✅ | ✅ | ✅ |
| map_from_entries | ✅ | ✅ | ✅ | ✅ |
| map_merge | ✅ | ✅ | ✅ | ✅ |
| map_map | ✅ | ✅ | ✅ | ✅ |
| map_filter | ✅ | ✅ | ✅ | ✅ |
| map_is_empty | ✅ | ✅ | ✅ | ✅ |
| map_length | ✅ | ✅ | ✅ | ✅ |

### Set Operations (10 functions)

| Function | Dart Engine | Dart Compiler | C++ Engine | C++ Compiler |
|----------|:-----------:|:-------------:|:----------:|:------------:|
| set_create | ✅ | ✅ | ✅ | ✅ |
| set_add | ✅ | ✅ | ✅ | ✅ |
| set_remove | ✅ | ✅ | ✅ | ✅ |
| set_contains | ✅ | ✅ | ✅ | ✅ |
| set_union | ✅ | ✅ | ✅ | ✅ |
| set_intersection | ✅ | ✅ | ✅ | ✅ |
| set_difference | ✅ | ✅ | ✅ | ✅ |
| set_length | ✅ | ✅ | ✅ | ✅ |
| set_is_empty | ✅ | ✅ | ✅ | ✅ |
| set_to_list | ✅ | ✅ | ✅ | ✅ |

---

## `std_io` Module (~10 functions)

| Function | Dart Engine | Dart Compiler | C++ Engine | C++ Compiler |
|----------|:-----------:|:-------------:|:----------:|:------------:|
| print_error | ✅ | ✅ | ✅ | ✅ |
| read_line | ✅ | ✅ | ✅ | ✅ |
| exit | ✅ | ✅ | ✅ | ✅ |
| panic | ✅ | ✅ | ✅ | ✅ |
| sleep_ms | ✅ | ✅ | ✅ | ✅ |
| timestamp_ms | ✅ | ✅ | ✅ | ✅ |
| random_int | ✅ | ✅ | ✅ | ✅ |
| random_double | ✅ | ✅ | ✅ | ✅ |
| env_get | ✅ | ✅ | ✅ | ✅ |
| args_get | ✅ | ✅ | ⚠️ | ✅ |

---

## `std_memory` Module (~30 functions)

| Function | Dart Engine | Dart Compiler | C++ Engine | C++ Compiler |
|----------|:-----------:|:-------------:|:----------:|:------------:|
| memory_alloc | ✅ | ✅ | ✅ | ✅ |
| memory_free | ✅ | ✅ | ✅ | ✅ |
| memory_realloc | ✅ | ✅ | ✅ | ✅ |
| memory_read_(u8/i8/u16/i16/u32/i32/i64/u64/f32/f64) | ✅ | ✅ | ✅ | ✅ |
| memory_write_(u8/i8/u16/i16/u32/i32/i64/u64/f32/f64) | ✅ | ✅ | ✅ | ✅ |
| memory_copy | ✅ | ✅ | ✅ | ✅ |
| memory_set | ✅ | ✅ | ✅ | ✅ |
| memory_compare | ✅ | ✅ | ✅ | ✅ |
| ptr_add / ptr_sub / ptr_diff | ✅ | ✅ | ✅ | ✅ |
| stack_push_frame / stack_pop_frame / stack_alloc | ✅ | ✅ | ✅ | ✅ |
| address_of / deref / nullptr | ✅ | ✅ | ✅ | ✅ |
| memory_sizeof | ✅ | ✅ | ✅ | ✅ |

---

## Former `dart_std` Functions (now in `std`)

> **Note:** The `dart_std` module has been eliminated. All its functions now route through
> the universal `std` module. The encoder expands Dart-specific constructs into `std`
> operations at encoding time. The functions below are listed for historical reference
> and to confirm they are all implemented in `std`.

| Function | Dart Engine | Dart Compiler | C++ Engine | C++ Compiler |
|----------|:-----------:|:-------------:|:----------:|:------------:|
| cascade | ✅ | ✅ | ✅ | ✅ |
| null_aware_access | ✅ | ✅ | ✅ | ✅ |
| null_aware_call | ✅ | ✅ | ✅ | ✅ |
| invoke | ✅ | ✅ | ✅ | ✅ |
| spread | ✅ | ✅ | ✅ | ✅ |
| null_spread | ✅ | ✅ | ✅ | ✅ |
| collection_if | ✅ | ✅ | ✅ | ✅ |
| collection_for | ✅ | ✅ | ✅ | ✅ |
| record | ✅ | ✅ | ✅ | ✅ |
| map_create | ✅ | ✅ | ✅ | ✅ |
| set_create | ✅ | ✅ | ✅ | ✅ |
| tear_off | ✅ | ✅ | ✅ | ✅ |
| dart_await_for | ✅ | ✅ | ✅ | ✅ |
| dart_stream_yield | ✅ | ✅ | ✅ | ✅ |
| dart_list_generate | ✅ | ✅ | ✅ | ✅ |
| dart_list_filled | ✅ | ✅ | ✅ | ✅ |
| null_aware_cascade | ✅ | ✅ | ✅ | ✅ |

---

## Summary

| Module | Dart Engine | Dart Compiler | C++ Engine | C++ Compiler |
|--------|:-----------:|:-------------:|:----------:|:------------:|
| std (core, incl. former dart_std) | 90/90 (100%) | 90/90 (100%) | 89/90 (99%) | 88/90 (98%) |
| std_collections | 43/43 (100%) | 43/43 (100%) | 43/43 (100%) | 43/43 (100%) |
| std_io | 10/10 (100%) | 10/10 (100%) | 9/10 (90%) | 10/10 (100%) |
| std_memory | 30/30 (100%) | 30/30 (100%) | 30/30 (100%) | 30/30 (100%) |
| **Total** | **173/173 (100%)** | **173/173 (100%)** | **171/173 (99%)** | **171/173 (99%)** |

---

## Additional Modules

| Module | Functions | Status |
|--------|-----------|--------|
| `std_convert` | json_encode, json_decode, utf8_encode, utf8_decode, base64_encode, base64_decode | Implemented (Dart engine + TS engine + C++ engine) |
| `std_time` | now, now_micros, format_timestamp, parse_timestamp, year, month, day, hour, minute, second | Implemented (Dart engine + TS engine + C++ engine) |
| `std_fs` | file_read, file_write, file_exists, file_delete, dir_list, dir_create, etc. | Planned |
| `std_concurrency` | thread_spawn, thread_join, mutex_*, atomic_*, scoped_lock | Planned |
| `std_net` | http_get, http_post, tcp_connect, tcp_send, tcp_receive | Planned |
| ~~`cpp_std`~~ | ~~Eliminated~~ — C++ pointer/reference ops are now inlined into universal `std`/`std_memory` by the encoder | N/A |
