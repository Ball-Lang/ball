/**
 * Static mapping of every Ball base function to its capability category.
 *
 * Since every side effect in Ball flows through a named base function in a
 * known module, this table is provably complete. No function can perform I/O,
 * access the filesystem, or spawn threads without appearing here.
 *
 * Ported from `dart/shared/lib/capability_table.dart`.
 */

/** Capability categories for Ball base functions. */
export type Capability =
  | 'pure'
  | 'io'
  | 'fs'
  | 'process'
  | 'time'
  | 'random'
  | 'memory'
  | 'concurrency'
  | 'network'
  | 'async';

/** Canonical ordering of capabilities (matches the Dart enum order). */
export const ALL_CAPABILITIES: readonly Capability[] = [
  'pure',
  'io',
  'fs',
  'process',
  'time',
  'random',
  'memory',
  'concurrency',
  'network',
  'async',
];

/** Risk level associated with each capability. */
export const capabilityRiskLevel: Record<Capability, string> = {
  pure: 'none',
  io: 'low',
  fs: 'medium',
  process: 'high',
  time: 'low',
  random: 'low',
  memory: 'high',
  concurrency: 'medium',
  network: 'high',
  async: 'low',
};

/**
 * Lookup the capability of a base function call.
 *
 * Returns `undefined` for non-base / user-defined functions (which are pure
 * by construction — they can only call other functions in this table).
 */
export function lookupCapability(
  module: string,
  fn: string,
): Capability | undefined {
  return CAPABILITY_TABLE[`${module}.${fn}`];
}

export const CAPABILITY_TABLE: Readonly<Record<string, Capability>> = {
  // ── std: print ──
  'std.print': 'io',

  // ── std: arithmetic (pure) ──
  'std.add': 'pure',
  'std.subtract': 'pure',
  'std.multiply': 'pure',
  'std.divide': 'pure',
  'std.divide_double': 'pure',
  'std.modulo': 'pure',
  'std.negate': 'pure',

  // ── std: comparison (pure) ──
  'std.equals': 'pure',
  'std.not_equals': 'pure',
  'std.less_than': 'pure',
  'std.greater_than': 'pure',
  'std.lte': 'pure',
  'std.gte': 'pure',

  // ── std: logical (pure) ──
  'std.and': 'pure',
  'std.or': 'pure',
  'std.not': 'pure',

  // ── std: bitwise (pure) ──
  'std.bitwise_and': 'pure',
  'std.bitwise_or': 'pure',
  'std.bitwise_xor': 'pure',
  'std.bitwise_not': 'pure',
  'std.left_shift': 'pure',
  'std.right_shift': 'pure',
  'std.unsigned_right_shift': 'pure',

  // ── std: increment/decrement (pure) ──
  'std.pre_increment': 'pure',
  'std.pre_decrement': 'pure',
  'std.post_increment': 'pure',
  'std.post_decrement': 'pure',

  // ── std: string & conversion (pure) ──
  'std.concat': 'pure',
  'std.length': 'pure',
  'std.to_string': 'pure',
  'std.int_to_string': 'pure',
  'std.double_to_string': 'pure',
  'std.string_to_int': 'pure',
  'std.string_to_double': 'pure',

  // ── std: null safety (pure) ──
  'std.null_coalesce': 'pure',
  'std.null_check': 'pure',

  // ── std: control flow (pure) ──
  'std.if': 'pure',
  'std.for': 'pure',
  'std.for_in': 'pure',
  'std.while': 'pure',
  'std.do_while': 'pure',
  'std.switch': 'pure',

  // ── std: error handling (pure) ──
  'std.try': 'pure',
  'std.throw': 'pure',
  'std.rethrow': 'pure',

  // ── std: assertions (pure) ──
  'std.assert': 'pure',

  // ── std: flow control (pure) ──
  'std.return': 'pure',
  'std.break': 'pure',
  'std.continue': 'pure',

  // ── std: generators & async ──
  'std.yield': 'async',
  'std.yield_each': 'async',
  'std.await': 'async',
  'std.async': 'async',

  // ── std: assignment (pure) ──
  'std.assign': 'pure',
  'std.compound_assign': 'pure',

  // ── std: type operations (pure) ──
  'std.is': 'pure',
  'std.is_not': 'pure',
  'std.as': 'pure',

  // ── std: indexing (pure) ──
  'std.index': 'pure',
  'std.index_assign': 'pure',

  // ── std: labels (pure) ──
  'std.labeled': 'pure',
  'std.label': 'pure',
  'std.goto': 'pure',
  'std.paren': 'pure',

  // ── std: string operations (pure) ──
  'std.string_length': 'pure',
  'std.string_is_empty': 'pure',
  'std.string_concat': 'pure',
  'std.string_contains': 'pure',
  'std.string_starts_with': 'pure',
  'std.string_ends_with': 'pure',
  'std.string_index_of': 'pure',
  'std.string_last_index_of': 'pure',
  'std.string_substring': 'pure',
  'std.string_char_at': 'pure',
  'std.string_char_code_at': 'pure',
  'std.string_from_char_code': 'pure',
  'std.string_to_upper': 'pure',
  'std.string_to_lower': 'pure',
  'std.string_trim': 'pure',
  'std.string_trim_start': 'pure',
  'std.string_trim_end': 'pure',
  'std.string_replace': 'pure',
  'std.string_replace_all': 'pure',
  'std.string_split': 'pure',
  'std.string_repeat': 'pure',
  'std.string_pad_left': 'pure',
  'std.string_pad_right': 'pure',
  'std.string_interpolation': 'pure',

  // ── std: regex (pure) ──
  'std.regex_match': 'pure',
  'std.regex_find': 'pure',
  'std.regex_find_all': 'pure',
  'std.regex_replace': 'pure',
  'std.regex_replace_all': 'pure',

  // ── std: math (pure) ──
  'std.math_abs': 'pure',
  'std.math_floor': 'pure',
  'std.math_ceil': 'pure',
  'std.math_round': 'pure',
  'std.math_trunc': 'pure',
  'std.math_sqrt': 'pure',
  'std.math_pow': 'pure',
  'std.math_log': 'pure',
  'std.math_log2': 'pure',
  'std.math_log10': 'pure',
  'std.math_exp': 'pure',
  'std.math_sin': 'pure',
  'std.math_cos': 'pure',
  'std.math_tan': 'pure',
  'std.math_asin': 'pure',
  'std.math_acos': 'pure',
  'std.math_atan': 'pure',
  'std.math_atan2': 'pure',
  'std.math_min': 'pure',
  'std.math_max': 'pure',
  'std.math_clamp': 'pure',
  'std.math_pi': 'pure',
  'std.math_e': 'pure',
  'std.math_infinity': 'pure',
  'std.math_nan': 'pure',
  'std.math_is_nan': 'pure',
  'std.math_is_finite': 'pure',
  'std.math_is_infinite': 'pure',
  'std.math_sign': 'pure',
  'std.math_gcd': 'pure',
  'std.math_lcm': 'pure',

  // ── std_io ──
  'std_io.print_error': 'io',
  'std_io.read_line': 'io',
  'std_io.exit': 'process',
  'std_io.panic': 'process',
  'std_io.sleep_ms': 'time',
  'std_io.timestamp_ms': 'time',
  'std_io.random_int': 'random',
  'std_io.random_double': 'random',
  'std_io.env_get': 'io',
  'std_io.args_get': 'io',

  // ── std_fs ──
  'std_fs.file_read': 'fs',
  'std_fs.file_read_bytes': 'fs',
  'std_fs.file_write': 'fs',
  'std_fs.file_write_bytes': 'fs',
  'std_fs.file_append': 'fs',
  'std_fs.file_exists': 'fs',
  'std_fs.file_delete': 'fs',
  'std_fs.dir_list': 'fs',
  'std_fs.dir_create': 'fs',
  'std_fs.dir_exists': 'fs',

  // ── std_collections (all pure) ──
  'std_collections.list_push': 'pure',
  'std_collections.list_pop': 'pure',
  'std_collections.list_insert': 'pure',
  'std_collections.list_remove_at': 'pure',
  'std_collections.list_get': 'pure',
  'std_collections.list_set': 'pure',
  'std_collections.list_length': 'pure',
  'std_collections.list_is_empty': 'pure',
  'std_collections.list_first': 'pure',
  'std_collections.list_last': 'pure',
  'std_collections.list_single': 'pure',
  'std_collections.list_contains': 'pure',
  'std_collections.list_index_of': 'pure',
  'std_collections.list_map': 'pure',
  'std_collections.list_filter': 'pure',
  'std_collections.list_reduce': 'pure',
  'std_collections.list_find': 'pure',
  'std_collections.list_any': 'pure',
  'std_collections.list_all': 'pure',
  'std_collections.list_none': 'pure',
  'std_collections.list_sort': 'pure',
  'std_collections.list_sort_by': 'pure',
  'std_collections.list_reverse': 'pure',
  'std_collections.list_slice': 'pure',
  'std_collections.list_flat_map': 'pure',
  'std_collections.list_zip': 'pure',
  'std_collections.list_take': 'pure',
  'std_collections.list_drop': 'pure',
  'std_collections.list_concat': 'pure',
  'std_collections.map_get': 'pure',
  'std_collections.map_set': 'pure',
  'std_collections.map_delete': 'pure',
  'std_collections.map_contains_key': 'pure',
  'std_collections.map_keys': 'pure',
  'std_collections.map_values': 'pure',
  'std_collections.map_entries': 'pure',
  'std_collections.map_from_entries': 'pure',
  'std_collections.map_merge': 'pure',
  'std_collections.map_map': 'pure',
  'std_collections.map_filter': 'pure',
  'std_collections.map_is_empty': 'pure',
  'std_collections.map_length': 'pure',
  'std_collections.set_create': 'pure',
  'std_collections.set_add': 'pure',
  'std_collections.set_remove': 'pure',
  'std_collections.set_contains': 'pure',
  'std_collections.set_union': 'pure',
  'std_collections.set_intersection': 'pure',
  'std_collections.set_difference': 'pure',
  'std_collections.set_length': 'pure',
  'std_collections.set_is_empty': 'pure',
  'std_collections.set_to_list': 'pure',
  'std_collections.string_join': 'pure',

  // ── std_convert (all pure) ──
  'std_convert.json_encode': 'pure',
  'std_convert.json_decode': 'pure',
  'std_convert.utf8_encode': 'pure',
  'std_convert.utf8_decode': 'pure',
  'std_convert.base64_encode': 'pure',
  'std_convert.base64_decode': 'pure',

  // ── std_time ──
  'std_time.now': 'time',
  'std_time.now_micros': 'time',
  'std_time.format_timestamp': 'time',
  'std_time.parse_timestamp': 'time',
  'std_time.duration_add': 'pure',
  'std_time.duration_subtract': 'pure',
  'std_time.year': 'time',
  'std_time.month': 'time',
  'std_time.day': 'time',
  'std_time.hour': 'time',
  'std_time.minute': 'time',
  'std_time.second': 'time',

  // ── std_memory (all memory/unsafe) ──
  'std_memory.memory_alloc': 'memory',
  'std_memory.memory_free': 'memory',
  'std_memory.memory_realloc': 'memory',
  'std_memory.memory_read_i8': 'memory',
  'std_memory.memory_read_u8': 'memory',
  'std_memory.memory_read_i16': 'memory',
  'std_memory.memory_read_u16': 'memory',
  'std_memory.memory_read_i32': 'memory',
  'std_memory.memory_read_u32': 'memory',
  'std_memory.memory_read_i64': 'memory',
  'std_memory.memory_read_u64': 'memory',
  'std_memory.memory_read_f32': 'memory',
  'std_memory.memory_read_f64': 'memory',
  'std_memory.memory_write_i8': 'memory',
  'std_memory.memory_write_u8': 'memory',
  'std_memory.memory_write_i16': 'memory',
  'std_memory.memory_write_u16': 'memory',
  'std_memory.memory_write_i32': 'memory',
  'std_memory.memory_write_u32': 'memory',
  'std_memory.memory_write_i64': 'memory',
  'std_memory.memory_write_u64': 'memory',
  'std_memory.memory_write_f32': 'memory',
  'std_memory.memory_write_f64': 'memory',
  'std_memory.memory_copy': 'memory',
  'std_memory.memory_set': 'memory',
  'std_memory.memory_compare': 'memory',
  'std_memory.ptr_add': 'memory',
  'std_memory.ptr_sub': 'memory',
  'std_memory.ptr_diff': 'memory',
  'std_memory.stack_alloc': 'memory',
  'std_memory.stack_push_frame': 'memory',
  'std_memory.stack_pop_frame': 'memory',
  'std_memory.memory_sizeof': 'memory',
  'std_memory.address_of': 'memory',
  'std_memory.deref': 'memory',
  'std_memory.nullptr': 'memory',
  'std_memory.memory_heap_size': 'memory',
  'std_memory.memory_stack_size': 'memory',

  // ── std_concurrency ──
  'std_concurrency.thread_spawn': 'concurrency',
  'std_concurrency.thread_join': 'concurrency',
  'std_concurrency.mutex_create': 'concurrency',
  'std_concurrency.mutex_lock': 'concurrency',
  'std_concurrency.mutex_unlock': 'concurrency',
  'std_concurrency.scoped_lock': 'concurrency',
  'std_concurrency.atomic_load': 'concurrency',
  'std_concurrency.atomic_store': 'concurrency',
  'std_concurrency.atomic_compare_exchange': 'concurrency',
};
