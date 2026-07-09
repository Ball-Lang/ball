<!-- GENERATED FILE — do not hand-edit.
Regenerate with: cd dart/encoder && dart run bin/gen_std_coverage.dart
Source of truth: dart/shared/std.json + the buildStd*Module()
builders in package:ball_base. See issue #135. -->

# Std Base-Function Coverage Inventory

Every base function across the 8 universal std modules, generated directly from the canonical builders (never hand-maintained).

> Coverage here is *function-name presence* in an executed conformance fixture, not full behavioral completeness — see [`docs/TESTING_STRATEGY.md`](../../docs/TESTING_STRATEGY.md) §2. "Engine-implemented" is scoped to the **Dart** reference engine (`dart/engine/lib/`); the TS/C++ self-hosted engines are generated from it (`docs/TESTING_STRATEGY.md` §5).

## Summary

| Metric | Count |
|---|---|
| Total base functions | 257 |
| Encoder-emittable | 107 |
| Covered by a conformance fixture | 113 |
| Dart engine-implemented | 219 |
| Documented carve-outs | 0 |

## `std` (119 functions)

Universal standard library base module. Every function here represents a language-agnostic operation that all target languages implement natively. Types use protobuf descriptors so they map to every target language.

| Function | Encoder-emittable | Covered by fixture | Dart engine |
|---|---|---|---|
| `add` | ✅ | ✅ 98 fixture(s): `101_simple_class`, `104_getter_setter`, `107_method_override_super` +95 more | ✅ |
| `and` | ✅ | ✅ 14 fixture(s): `100_complex_control_flow`, `113_operator_overloading`, `131_insertion_sort` +11 more | ✅ |
| `as` | ✅ | ✅ 2 fixture(s): `195_deep_nesting`, `256_editions_resolver` | ✅ |
| `assert` | ✅ | ✅ 1 fixture(s): `313_assert_statement` | ✅ |
| `assign` | ✅ | ✅ 113 fixture(s): `100_complex_control_flow`, `101_simple_class`, `104_getter_setter` +110 more | ✅ |
| `await` | ✅ | ✅ 11 fixture(s): `160_async_basic`, `161_async_chained`, `163_generator_async` +8 more | ✅ |
| `bitwise_and` | ✅ | ✅ 4 fixture(s): `206_integer_arithmetic_edge`, `251_bitwise_signed_edges`, `284_enc_bitwise` +1 more | ✅ |
| `bitwise_not` | ✅ | ✅ 3 fixture(s): `251_bitwise_signed_edges`, `284_enc_bitwise`, `61_bitwise_ops` | ✅ |
| `bitwise_or` | ✅ | ✅ 3 fixture(s): `206_integer_arithmetic_edge`, `284_enc_bitwise`, `61_bitwise_ops` | ✅ |
| `bitwise_xor` | ✅ | ✅ 5 fixture(s): `113_operator_overloading`, `206_integer_arithmetic_edge`, `251_bitwise_signed_edges` +2 more | ✅ |
| `break` | ✅ | ✅ 10 fixture(s): `100_complex_control_flow`, `136_string_pattern_match`, `148_labeled_loops` +7 more | ✅ |
| `concat` | ✅ | ✅ 95 fixture(s): `101_simple_class`, `102_inheritance`, `103_abstract_class` +92 more | ✅ |
| `continue` | ✅ | ✅ 6 fixture(s): `100_complex_control_flow`, `148_labeled_loops`, `274_enc_nested_control` +3 more | ✅ |
| `divide` | ✅ | ✅ 18 fixture(s): `108_class_tostring`, `132_merge_sort`, `143_perfect_number` +15 more | ✅ |
| `divide_double` | ✅ | ✅ 12 fixture(s): `104_getter_setter`, `130_running_average`, `214_nan_propagation` +9 more | ✅ |
| `do_while` | ✅ | ✅ 2 fixture(s): `282_enc_do_while`, `47_do_while` | ✅ |
| `double_to_string` | ✅ | ✅ 1 fixture(s): `389_typed_to_string` | ✅ |
| `equals` | ✅ | ✅ 65 fixture(s): `100_complex_control_flow`, `113_operator_overloading`, `117_list_generate` +62 more | ✅ |
| `for` | ✅ | ✅ 93 fixture(s): `100_complex_control_flow`, `103_abstract_class`, `105_static_methods` +90 more | ✅ |
| `for_in` | ✅ | ✅ 47 fixture(s): `103_abstract_class`, `109_enum_values`, `117_list_generate` +44 more | ✅ |
| `goto` | ❌ | ✅ 1 fixture(s): `390_goto_label` | ✅ |
| `greater_than` | ✅ | ✅ 40 fixture(s): `100_complex_control_flow`, `105_static_methods`, `131_insertion_sort` +37 more | ✅ |
| `gte` | ✅ | ✅ 10 fixture(s): `131_insertion_sort`, `140_caesar_cipher`, `151_recursive_descent_parser` +7 more | ✅ |
| `if` | ✅ | ✅ 82 fixture(s): `100_complex_control_flow`, `105_static_methods`, `106_factory_constructor` +79 more | ✅ |
| `index` | ✅ | ✅ 57 fixture(s): `106_factory_constructor`, `119_nested_maps`, `120_list_of_maps` +54 more | ✅ |
| `int_to_string` | ✅ | ✅ 1 fixture(s): `389_typed_to_string` | ✅ |
| `is` | ✅ | ✅ 12 fixture(s): `113_operator_overloading`, `167_generics_reified`, `180_generic_list_ops` +9 more | ✅ |
| `is_not` | ✅ | ✅ 1 fixture(s): `380_is_not_type_check` | ✅ |
| `label` | ✅ | ✅ 1 fixture(s): `390_goto_label` | ✅ |
| `left_shift` | ✅ | ✅ 4 fixture(s): `206_integer_arithmetic_edge`, `251_bitwise_signed_edges`, `284_enc_bitwise` +1 more | ✅ |
| `length` | ❌ | ❌ | ✅ |
| `less_than` | ✅ | ✅ 72 fixture(s): `100_complex_control_flow`, `105_static_methods`, `127_zip_lists` +69 more | ✅ |
| `lte` | ✅ | ✅ 42 fixture(s): `105_static_methods`, `125_group_by`, `132_merge_sort` +39 more | ✅ |
| `math_abs` | ✅ | ✅ 5 fixture(s): `108_class_tostring`, `230_signed_int_boundaries`, `259_math_functions` +2 more | ✅ |
| `math_acos` | ❌ | ❌ | ✅ |
| `math_asin` | ❌ | ❌ | ✅ |
| `math_atan` | ❌ | ❌ | ✅ |
| `math_atan2` | ❌ | ❌ | ✅ |
| `math_ceil` | ✅ | ✅ 2 fixture(s): `259_math_functions`, `320_num_methods_on_double_local` | ✅ |
| `math_clamp` | ✅ | ✅ 2 fixture(s): `105_static_methods`, `259_math_functions` | ✅ |
| `math_cos` | ❌ | ❌ | ✅ |
| `math_e` | ❌ | ❌ | ✅ |
| `math_exp` | ❌ | ❌ | ✅ |
| `math_floor` | ✅ | ✅ 2 fixture(s): `259_math_functions`, `320_num_methods_on_double_local` | ✅ |
| `math_gcd` | ✅ | ✅ 1 fixture(s): `263_numeric_properties` | ✅ |
| `math_infinity` | ❌ | ❌ | ✅ |
| `math_is_finite` | ✅ | ✅ 2 fixture(s): `215_infinity_arithmetic`, `317_primitive_number_getters` | ✅ |
| `math_is_infinite` | ✅ | ✅ 3 fixture(s): `215_infinity_arithmetic`, `263_numeric_properties`, `317_primitive_number_getters` | ✅ |
| `math_is_nan` | ✅ | ✅ 4 fixture(s): `214_nan_propagation`, `215_infinity_arithmetic`, `263_numeric_properties` +1 more | ✅ |
| `math_lcm` | ❌ | ❌ | ✅ |
| `math_log` | ❌ | ❌ | ✅ |
| `math_log10` | ❌ | ❌ | ✅ |
| `math_log2` | ❌ | ❌ | ✅ |
| `math_max` | ❌ | ❌ | ✅ |
| `math_min` | ❌ | ❌ | ✅ |
| `math_nan` | ❌ | ❌ | ✅ |
| `math_pi` | ❌ | ❌ | ✅ |
| `math_pow` | ❌ | ❌ | ✅ |
| `math_round` | ✅ | ✅ 2 fixture(s): `259_math_functions`, `320_num_methods_on_double_local` | ✅ |
| `math_sign` | ✅ | ✅ 2 fixture(s): `262_getter_properties`, `317_primitive_number_getters` | ✅ |
| `math_sin` | ❌ | ❌ | ✅ |
| `math_sqrt` | ❌ | ❌ | ✅ |
| `math_tan` | ❌ | ❌ | ✅ |
| `math_trunc` | ✅ | ✅ 2 fixture(s): `259_math_functions`, `320_num_methods_on_double_local` | ✅ |
| `modulo` | ✅ | ✅ 36 fixture(s): `108_class_tostring`, `117_list_generate`, `125_group_by` +33 more | ✅ |
| `multiply` | ✅ | ✅ 61 fixture(s): `100_complex_control_flow`, `101_simple_class`, `103_abstract_class` +58 more | ✅ |
| `negate` | ✅ | ✅ 43 fixture(s): `105_static_methods`, `135_linear_search_sentinel`, `170_pattern_switch_expr` +40 more | ✅ |
| `not` | ✅ | ✅ 12 fixture(s): `123_queue_simulation`, `125_group_by`, `129_unique_elements` +9 more | ✅ |
| `not_equals` | ✅ | ✅ 11 fixture(s): `108_class_tostring`, `135_linear_search_sentinel`, `136_string_pattern_match` +8 more | ✅ |
| `null_check` | ✅ | ✅ 5 fixture(s): `106_factory_constructor`, `119_nested_maps`, `125_group_by` +2 more | ✅ |
| `null_coalesce` | ✅ | ✅ 1 fixture(s): `124_frequency_counter` | ✅ |
| `or` | ✅ | ✅ 8 fixture(s): `135_linear_search_sentinel`, `151_recursive_descent_parser`, `153_memoized_recursive` +5 more | ✅ |
| `post_decrement` | ✅ | ✅ 6 fixture(s): `131_insertion_sort`, `308_list_comprehension_cstyle`, `40_increment_decrement` +3 more | ✅ |
| `post_increment` | ✅ | ✅ 66 fixture(s): `100_complex_control_flow`, `105_static_methods`, `127_zip_lists` +63 more | ✅ |
| `pre_decrement` | ✅ | ✅ 1 fixture(s): `261_conversion_and_ops` | ✅ |
| `pre_increment` | ✅ | ✅ 1 fixture(s): `261_conversion_and_ops` | ✅ |
| `print` | ✅ | ✅ 321 fixture(s): `100_complex_control_flow`, `101_simple_class`, `102_inheritance` +318 more | ✅ |
| `regex_find` | ❌ | ❌ | ✅ |
| `regex_find_all` | ❌ | ❌ | ✅ |
| `regex_match` | ❌ | ❌ | ✅ |
| `regex_replace` | ❌ | ❌ | ✅ |
| `regex_replace_all` | ❌ | ❌ | ✅ |
| `rethrow` | ✅ | ✅ 8 fixture(s): `146_nested_try_catch_types`, `208_async_chain_rethrow`, `221_rethrow_preserves_chain` +5 more | ✅ |
| `return` | ✅ | ✅ 57 fixture(s): `105_static_methods`, `106_factory_constructor`, `109_enum_values` +54 more | ✅ |
| `right_shift` | ✅ | ✅ 5 fixture(s): `206_integer_arithmetic_edge`, `251_bitwise_signed_edges`, `284_enc_bitwise` +2 more | ✅ |
| `string_char_at` | ❌ | ❌ | ✅ |
| `string_char_code_at` | ❌ | ❌ | ✅ |
| `string_concat` | ❌ | ❌ | ✅ |
| `string_contains` | ❌ | ❌ | ✅ |
| `string_ends_with` | ✅ | ✅ 1 fixture(s): `260_string_functions` | ✅ |
| `string_from_char_code` | ❌ | ❌ | ✅ |
| `string_index_of` | ❌ | ❌ | ✅ |
| `string_is_empty` | ✅ | ✅ 13 fixture(s): `115_generic_class`, `123_queue_simulation`, `195_deep_nesting` +10 more | ✅ |
| `string_last_index_of` | ✅ | ✅ 1 fixture(s): `264_string_replace_ops` | ✅ |
| `string_length` | ❌ | ❌ | ✅ |
| `string_pad_left` | ✅ | ✅ 2 fixture(s): `204_string_operations`, `264_string_replace_ops` | ✅ |
| `string_pad_right` | ✅ | ✅ 1 fixture(s): `264_string_replace_ops` | ✅ |
| `string_repeat` | ❌ | ❌ | ✅ |
| `string_replace` | ✅ | ✅ 1 fixture(s): `264_string_replace_ops` | ✅ |
| `string_replace_all` | ✅ | ✅ 4 fixture(s): `204_string_operations`, `249_string_control_char_edges`, `260_string_functions` +1 more | ✅ |
| `string_runes` | ✅ | ✅ 1 fixture(s): `319_string_runes` | ✅ |
| `string_split` | ✅ | ✅ 2 fixture(s): `124_frequency_counter`, `264_string_replace_ops` | ✅ |
| `string_starts_with` | ✅ | ✅ 2 fixture(s): `260_string_functions`, `382_list_all_every` | ✅ |
| `string_substring` | ✅ | ✅ 6 fixture(s): `151_recursive_descent_parser`, `193_unicode_and_special_characters`, `204_string_operations` +3 more | ✅ |
| `string_to_double` | ✅ | ✅ 3 fixture(s): `314_string_to_double`, `316_to_string_as_fixed`, `321_whole_double_parse_print` | ✅ |
| `string_to_int` | ✅ | ✅ 3 fixture(s): `151_recursive_descent_parser`, `275_enc_try_catch`, `99_type_conversion` | ✅ |
| `string_to_lower` | ✅ | ✅ 4 fixture(s): `204_string_operations`, `26_string_ops`, `287_enc_string_ops` +1 more | ✅ |
| `string_to_upper` | ✅ | ✅ 6 fixture(s): `204_string_operations`, `213_string_edge_cases`, `26_string_ops` +3 more | ✅ |
| `string_trim` | ✅ | ✅ 5 fixture(s): `204_string_operations`, `213_string_edge_cases`, `26_string_ops` +2 more | ✅ |
| `string_trim_end` | ✅ | ✅ 1 fixture(s): `260_string_functions` | ✅ |
| `string_trim_start` | ✅ | ✅ 1 fixture(s): `260_string_functions` | ✅ |
| `subtract` | ✅ | ✅ 36 fixture(s): `104_getter_setter`, `113_operator_overloading`, `131_insertion_sort` +33 more | ✅ |
| `switch` | ✅ | ✅ 22 fixture(s): `109_enum_values`, `147_complex_switch`, `150_state_machine` +19 more | ✅ |
| `throw` | ✅ | ✅ 20 fixture(s): `146_nested_try_catch_types`, `171_async_error_propagation`, `208_async_chain_rethrow` +17 more | ✅ |
| `to_string` | ✅ | ✅ 183 fixture(s): `101_simple_class`, `102_inheritance`, `103_abstract_class` +180 more | ✅ |
| `try` | ✅ | ✅ 23 fixture(s): `146_nested_try_catch_types`, `171_async_error_propagation`, `199_malicious_input_patterns` +20 more | ✅ |
| `unsigned_right_shift` | ✅ | ✅ 1 fixture(s): `381_unsigned_right_shift` | ✅ |
| `while` | ✅ | ✅ 24 fixture(s): `100_complex_control_flow`, `108_class_tostring`, `123_queue_simulation` +21 more | ✅ |
| `yield` | ✅ | ✅ 6 fixture(s): `162_generator_sync`, `163_generator_async`, `174_generator_yield_star` +3 more | ✅ |

## `std_collections` (53 functions)

Standard collections module. List and map operations. Separate from std because not all runtimes support mutable collections natively.

| Function | Encoder-emittable | Covered by fixture | Dart engine |
|---|---|---|---|
| `list_all` | ✅ | ✅ 1 fixture(s): `382_list_all_every` | ✅ |
| `list_any` | ✅ | ✅ 1 fixture(s): `383_list_any_check` | ✅ |
| `list_concat` | ✅ | ✅ 1 fixture(s): `386_list_concat_addall` | ✅ |
| `list_contains` | ✅ | ✅ 6 fixture(s): `118_set_operations`, `129_unique_elements`, `260_string_functions` +3 more | ✅ |
| `list_drop` | ❌ | ❌ | ✅ |
| `list_filter` | ✅ | ✅ 1 fixture(s): `384_list_filter_where` | ✅ |
| `list_find` | ❌ | ❌ | ✅ |
| `list_first` | ❌ | ❌ | ✅ |
| `list_flat_map` | ❌ | ❌ | ✅ |
| `list_get` | ❌ | ❌ | ✅ |
| `list_index_of` | ✅ | ✅ 2 fixture(s): `204_string_operations`, `213_string_edge_cases` | ✅ |
| `list_insert` | ✅ | ✅ 1 fixture(s): `385_list_insert_at_index` | ✅ |
| `list_is_empty` | ❌ | ❌ | ✅ |
| `list_last` | ❌ | ❌ | ✅ |
| `list_length` | ❌ | ❌ | ✅ |
| `list_map` | ✅ | ✅ 1 fixture(s): `121_map_from_entries` | ✅ |
| `list_none` | ❌ | ❌ | ✅ |
| `list_pop` | ✅ | ✅ 2 fixture(s): `115_generic_class`, `97_stack_operations` | ✅ |
| `list_push` | ✅ | ✅ 33 fixture(s): `111_cascade_operator`, `115_generic_class`, `120_list_of_maps` +30 more | ✅ |
| `list_reduce` | ✅ | ✅ 1 fixture(s): `318_list_reduce` | ✅ |
| `list_remove_at` | ✅ | ✅ 1 fixture(s): `123_queue_simulation` | ✅ |
| `list_reverse` | ✅ | ✅ 1 fixture(s): `387_list_reverse_getter` | ✅ |
| `list_set` | ❌ | ❌ | ✅ |
| `list_single` | ❌ | ❌ | ✅ |
| `list_slice` | ✅ | ✅ 2 fixture(s): `132_merge_sort`, `155_pipeline_compose` | ✅ |
| `list_sort` | ✅ | ✅ 5 fixture(s): `118_set_operations`, `122_list_sort_comparator`, `124_frequency_counter` +2 more | ✅ |
| `list_sort_by` | ❌ | ❌ | ✅ |
| `list_take` | ❌ | ❌ | ✅ |
| `list_zip` | ❌ | ❌ | ✅ |
| `map_contains_key` | ✅ | ✅ 11 fixture(s): `106_factory_constructor`, `125_group_by`, `153_memoized_recursive` +8 more | ✅ |
| `map_delete` | ❌ | ❌ | ✅ |
| `map_entries` | ❌ | ❌ | ✅ |
| `map_filter` | ❌ | ❌ | ✅ |
| `map_from_entries` | ❌ | ❌ | ✅ |
| `map_get` | ❌ | ❌ | ✅ |
| `map_is_empty` | ❌ | ❌ | ✅ |
| `map_keys` | ❌ | ❌ | ✅ |
| `map_length` | ❌ | ❌ | ✅ |
| `map_map` | ❌ | ❌ | ✅ |
| `map_merge` | ❌ | ❌ | ✅ |
| `map_set` | ❌ | ❌ | ✅ |
| `map_values` | ❌ | ❌ | ✅ |
| `set_add` | ❌ | ❌ | ✅ |
| `set_contains` | ❌ | ❌ | ✅ |
| `set_create` | ✅ | ✅ 6 fixture(s): `118_set_operations`, `129_unique_elements`, `310_set_map_comprehension` +3 more | ✅ |
| `set_difference` | ❌ | ❌ | ✅ |
| `set_intersection` | ❌ | ❌ | ✅ |
| `set_is_empty` | ❌ | ❌ | ✅ |
| `set_length` | ❌ | ❌ | ✅ |
| `set_remove` | ❌ | ❌ | ✅ |
| `set_to_list` | ❌ | ❌ | ✅ |
| `set_union` | ❌ | ❌ | ✅ |
| `string_join` | ❌ | ❌ | ✅ |

## `std_io` (10 functions)

Standard I/O module. Console, process, time, random, environment. Not available in all runtimes (browser, WASM, embedded).

| Function | Encoder-emittable | Covered by fixture | Dart engine |
|---|---|---|---|
| `args_get` | ❌ | ❌ | ✅ |
| `env_get` | ❌ | ❌ | ✅ |
| `exit` | ❌ | ❌ | ✅ |
| `panic` | ❌ | ❌ | ✅ |
| `print_error` | ❌ | ❌ | ✅ |
| `random_double` | ❌ | ❌ | ✅ |
| `random_int` | ❌ | ❌ | ✅ |
| `read_line` | ❌ | ❌ | ✅ |
| `sleep_ms` | ❌ | ❌ | ✅ |
| `timestamp_ms` | ❌ | ✅ 1 fixture(s): `188_std_time_now` | ✅ |

## `std_memory` (38 functions)

Linear memory simulation module. Provides heap allocation, typed reads/writes, pointer arithmetic, and stack frame management. Used by the hybrid normalizer when C/C++ code performs raw pointer operations that cannot be safely projected to native references.

| Function | Encoder-emittable | Covered by fixture | Dart engine |
|---|---|---|---|
| `address_of` | ❌ | ❌ | ❌ |
| `deref` | ❌ | ❌ | ❌ |
| `memory_alloc` | ❌ | ❌ | ❌ |
| `memory_compare` | ❌ | ❌ | ❌ |
| `memory_copy` | ❌ | ❌ | ❌ |
| `memory_free` | ❌ | ❌ | ❌ |
| `memory_heap_size` | ❌ | ❌ | ❌ |
| `memory_read_f32` | ❌ | ❌ | ❌ |
| `memory_read_f64` | ❌ | ❌ | ❌ |
| `memory_read_i16` | ❌ | ❌ | ❌ |
| `memory_read_i32` | ❌ | ❌ | ❌ |
| `memory_read_i64` | ❌ | ❌ | ❌ |
| `memory_read_i8` | ❌ | ❌ | ❌ |
| `memory_read_u16` | ❌ | ❌ | ❌ |
| `memory_read_u32` | ❌ | ❌ | ❌ |
| `memory_read_u64` | ❌ | ❌ | ❌ |
| `memory_read_u8` | ❌ | ❌ | ❌ |
| `memory_realloc` | ❌ | ❌ | ❌ |
| `memory_set` | ❌ | ❌ | ❌ |
| `memory_sizeof` | ❌ | ❌ | ❌ |
| `memory_stack_size` | ❌ | ❌ | ❌ |
| `memory_write_f32` | ❌ | ❌ | ❌ |
| `memory_write_f64` | ❌ | ❌ | ❌ |
| `memory_write_i16` | ❌ | ❌ | ❌ |
| `memory_write_i32` | ❌ | ❌ | ❌ |
| `memory_write_i64` | ❌ | ❌ | ❌ |
| `memory_write_i8` | ❌ | ❌ | ❌ |
| `memory_write_u16` | ❌ | ❌ | ❌ |
| `memory_write_u32` | ❌ | ❌ | ❌ |
| `memory_write_u64` | ❌ | ❌ | ❌ |
| `memory_write_u8` | ❌ | ❌ | ❌ |
| `nullptr` | ❌ | ❌ | ❌ |
| `ptr_add` | ❌ | ❌ | ❌ |
| `ptr_diff` | ❌ | ❌ | ❌ |
| `ptr_sub` | ❌ | ❌ | ❌ |
| `stack_alloc` | ❌ | ❌ | ❌ |
| `stack_pop_frame` | ❌ | ❌ | ❌ |
| `stack_push_frame` | ❌ | ❌ | ❌ |

## `std_convert` (6 functions)

Standard conversion module. JSON, UTF-8, base64 encoding/decoding.

| Function | Encoder-emittable | Covered by fixture | Dart engine |
|---|---|---|---|
| `base64_decode` | ✅ | ✅ 1 fixture(s): `191_base64_encode_decode` | ✅ |
| `base64_encode` | ✅ | ✅ 1 fixture(s): `191_base64_encode_decode` | ✅ |
| `json_decode` | ✅ | ✅ 1 fixture(s): `185_std_convert` | ✅ |
| `json_encode` | ✅ | ✅ 1 fixture(s): `185_std_convert` | ✅ |
| `utf8_decode` | ✅ | ✅ 2 fixture(s): `190_utf8_encode_decode`, `191_base64_encode_decode` | ✅ |
| `utf8_encode` | ✅ | ✅ 2 fixture(s): `190_utf8_encode_decode`, `191_base64_encode_decode` | ✅ |

## `std_fs` (10 functions)

Standard file system module. File and directory operations. Not available in browser, WASM, or sandboxed runtimes.

| Function | Encoder-emittable | Covered by fixture | Dart engine |
|---|---|---|---|
| `dir_create` | ❌ | ❌ | ✅ |
| `dir_exists` | ❌ | ❌ | ✅ |
| `dir_list` | ❌ | ❌ | ✅ |
| `file_append` | ❌ | ❌ | ✅ |
| `file_delete` | ❌ | ❌ | ✅ |
| `file_exists` | ❌ | ❌ | ✅ |
| `file_read` | ❌ | ✅ 1 fixture(s): `202_sandbox_mode` | ✅ |
| `file_read_bytes` | ❌ | ❌ | ✅ |
| `file_write` | ❌ | ❌ | ✅ |
| `file_write_bytes` | ❌ | ❌ | ✅ |

## `std_time` (12 functions)

Standard time module. Current time, formatting, parsing, durations.

| Function | Encoder-emittable | Covered by fixture | Dart engine |
|---|---|---|---|
| `day` | ❌ | ❌ | ✅ |
| `duration_add` | ❌ | ❌ | ✅ |
| `duration_subtract` | ❌ | ❌ | ✅ |
| `format_timestamp` | ❌ | ✅ 1 fixture(s): `188_std_time_now` | ✅ |
| `hour` | ❌ | ❌ | ✅ |
| `minute` | ❌ | ❌ | ✅ |
| `month` | ❌ | ❌ | ✅ |
| `now` | ❌ | ✅ 1 fixture(s): `188_std_time_now` | ✅ |
| `now_micros` | ❌ | ❌ | ✅ |
| `parse_timestamp` | ❌ | ✅ 1 fixture(s): `188_std_time_now` | ✅ |
| `second` | ❌ | ❌ | ✅ |
| `year` | ❌ | ❌ | ✅ |

## `std_concurrency` (9 functions)

Concurrency primitives: threads, mutexes, atomics. Engines may simulate single-threaded or use real threads.

| Function | Encoder-emittable | Covered by fixture | Dart engine |
|---|---|---|---|
| `atomic_compare_exchange` | ❌ | ❌ | ✅ |
| `atomic_load` | ❌ | ❌ | ✅ |
| `atomic_store` | ❌ | ❌ | ✅ |
| `mutex_create` | ❌ | ❌ | ✅ |
| `mutex_lock` | ❌ | ❌ | ✅ |
| `mutex_unlock` | ❌ | ❌ | ✅ |
| `scoped_lock` | ❌ | ❌ | ✅ |
| `thread_join` | ❌ | ❌ | ✅ |
| `thread_spawn` | ❌ | ❌ | ✅ |

## Gaps

### Not encoder-emittable (150) — no Dart-source construct routes to this function

- `std_memory.address_of`
- `std_io.args_get`
- `std_concurrency.atomic_compare_exchange`
- `std_concurrency.atomic_load`
- `std_concurrency.atomic_store`
- `std_time.day`
- `std_memory.deref`
- `std_fs.dir_create`
- `std_fs.dir_exists`
- `std_fs.dir_list`
- `std_time.duration_add`
- `std_time.duration_subtract`
- `std_io.env_get`
- `std_io.exit`
- `std_fs.file_append`
- `std_fs.file_delete`
- `std_fs.file_exists`
- `std_fs.file_read`
- `std_fs.file_read_bytes`
- `std_fs.file_write`
- `std_fs.file_write_bytes`
- `std_time.format_timestamp`
- `std.goto`
- `std_time.hour`
- `std.length`
- `std_collections.list_drop`
- `std_collections.list_find`
- `std_collections.list_first`
- `std_collections.list_flat_map`
- `std_collections.list_get`
- `std_collections.list_is_empty`
- `std_collections.list_last`
- `std_collections.list_length`
- `std_collections.list_none`
- `std_collections.list_set`
- `std_collections.list_single`
- `std_collections.list_sort_by`
- `std_collections.list_take`
- `std_collections.list_zip`
- `std_collections.map_delete`
- `std_collections.map_entries`
- `std_collections.map_filter`
- `std_collections.map_from_entries`
- `std_collections.map_get`
- `std_collections.map_is_empty`
- `std_collections.map_keys`
- `std_collections.map_length`
- `std_collections.map_map`
- `std_collections.map_merge`
- `std_collections.map_set`
- `std_collections.map_values`
- `std.math_acos`
- `std.math_asin`
- `std.math_atan`
- `std.math_atan2`
- `std.math_cos`
- `std.math_e`
- `std.math_exp`
- `std.math_infinity`
- `std.math_lcm`
- `std.math_log`
- `std.math_log10`
- `std.math_log2`
- `std.math_max`
- `std.math_min`
- `std.math_nan`
- `std.math_pi`
- `std.math_pow`
- `std.math_sin`
- `std.math_sqrt`
- `std.math_tan`
- `std_memory.memory_alloc`
- `std_memory.memory_compare`
- `std_memory.memory_copy`
- `std_memory.memory_free`
- `std_memory.memory_heap_size`
- `std_memory.memory_read_f32`
- `std_memory.memory_read_f64`
- `std_memory.memory_read_i16`
- `std_memory.memory_read_i32`
- `std_memory.memory_read_i64`
- `std_memory.memory_read_i8`
- `std_memory.memory_read_u16`
- `std_memory.memory_read_u32`
- `std_memory.memory_read_u64`
- `std_memory.memory_read_u8`
- `std_memory.memory_realloc`
- `std_memory.memory_set`
- `std_memory.memory_sizeof`
- `std_memory.memory_stack_size`
- `std_memory.memory_write_f32`
- `std_memory.memory_write_f64`
- `std_memory.memory_write_i16`
- `std_memory.memory_write_i32`
- `std_memory.memory_write_i64`
- `std_memory.memory_write_i8`
- `std_memory.memory_write_u16`
- `std_memory.memory_write_u32`
- `std_memory.memory_write_u64`
- `std_memory.memory_write_u8`
- `std_time.minute`
- `std_time.month`
- `std_concurrency.mutex_create`
- `std_concurrency.mutex_lock`
- `std_concurrency.mutex_unlock`
- `std_time.now`
- `std_time.now_micros`
- `std_memory.nullptr`
- `std_io.panic`
- `std_time.parse_timestamp`
- `std_io.print_error`
- `std_memory.ptr_add`
- `std_memory.ptr_diff`
- `std_memory.ptr_sub`
- `std_io.random_double`
- `std_io.random_int`
- `std_io.read_line`
- `std.regex_find`
- `std.regex_find_all`
- `std.regex_match`
- `std.regex_replace`
- `std.regex_replace_all`
- `std_concurrency.scoped_lock`
- `std_time.second`
- `std_collections.set_add`
- `std_collections.set_contains`
- `std_collections.set_difference`
- `std_collections.set_intersection`
- `std_collections.set_is_empty`
- `std_collections.set_length`
- `std_collections.set_remove`
- `std_collections.set_to_list`
- `std_collections.set_union`
- `std_io.sleep_ms`
- `std_memory.stack_alloc`
- `std_memory.stack_pop_frame`
- `std_memory.stack_push_frame`
- `std.string_char_at`
- `std.string_char_code_at`
- `std.string_concat`
- `std.string_contains`
- `std.string_from_char_code`
- `std.string_index_of`
- `std_collections.string_join`
- `std.string_length`
- `std.string_repeat`
- `std_concurrency.thread_join`
- `std_concurrency.thread_spawn`
- `std_io.timestamp_ms`
- `std_time.year`

### Emittable but uncovered by any fixture (0) — genuine conformance gaps, not carved out

_None._

### Not Dart engine-implemented (38)

- `std_memory.address_of`
- `std_memory.deref`
- `std_memory.memory_alloc`
- `std_memory.memory_compare`
- `std_memory.memory_copy`
- `std_memory.memory_free`
- `std_memory.memory_heap_size`
- `std_memory.memory_read_f32`
- `std_memory.memory_read_f64`
- `std_memory.memory_read_i16`
- `std_memory.memory_read_i32`
- `std_memory.memory_read_i64`
- `std_memory.memory_read_i8`
- `std_memory.memory_read_u16`
- `std_memory.memory_read_u32`
- `std_memory.memory_read_u64`
- `std_memory.memory_read_u8`
- `std_memory.memory_realloc`
- `std_memory.memory_set`
- `std_memory.memory_sizeof`
- `std_memory.memory_stack_size`
- `std_memory.memory_write_f32`
- `std_memory.memory_write_f64`
- `std_memory.memory_write_i16`
- `std_memory.memory_write_i32`
- `std_memory.memory_write_i64`
- `std_memory.memory_write_i8`
- `std_memory.memory_write_u16`
- `std_memory.memory_write_u32`
- `std_memory.memory_write_u64`
- `std_memory.memory_write_u8`
- `std_memory.nullptr`
- `std_memory.ptr_add`
- `std_memory.ptr_diff`
- `std_memory.ptr_sub`
- `std_memory.stack_alloc`
- `std_memory.stack_pop_frame`
- `std_memory.stack_push_frame`

