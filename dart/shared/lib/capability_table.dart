/// Static mapping of every Ball base function to its capability category.
///
/// Since every side effect in Ball flows through a named base function in a
/// known module, this table is provably complete. No function can perform I/O,
/// access the filesystem, or spawn threads without appearing here.
library;

/// Capability categories for Ball base functions.
enum Capability {
  pure,
  io,
  fs,
  process,
  time,
  random,
  memory,
  concurrency,
  network,
  async,
}

/// Risk level associated with each capability.
const Map<Capability, String> capabilityRiskLevel = {
  Capability.pure: 'none',
  Capability.io: 'low',
  Capability.fs: 'medium',
  Capability.process: 'high',
  Capability.time: 'low',
  Capability.random: 'low',
  Capability.memory: 'high',
  Capability.concurrency: 'medium',
  Capability.network: 'high',
  Capability.async: 'low',
};

/// Lookup the capability of a base function call.
///
/// Returns `null` for non-base / user-defined functions (which are pure
/// by construction — they can only call other functions in this table).
Capability? lookupCapability(String module, String function) {
  return _table['$module.$function'];
}

const Map<String, Capability> _table = {
  // ── std: print ──
  'std.print': Capability.io,

  // ── std: arithmetic (pure) ──
  'std.add': Capability.pure,
  'std.subtract': Capability.pure,
  'std.multiply': Capability.pure,
  'std.divide': Capability.pure,
  'std.divide_double': Capability.pure,
  'std.modulo': Capability.pure,
  'std.negate': Capability.pure,

  // ── std: comparison (pure) ──
  'std.equals': Capability.pure,
  'std.not_equals': Capability.pure,
  'std.less_than': Capability.pure,
  'std.greater_than': Capability.pure,
  'std.lte': Capability.pure,
  'std.gte': Capability.pure,

  // ── std: logical (pure) ──
  'std.and': Capability.pure,
  'std.or': Capability.pure,
  'std.not': Capability.pure,

  // ── std: bitwise (pure) ──
  'std.bitwise_and': Capability.pure,
  'std.bitwise_or': Capability.pure,
  'std.bitwise_xor': Capability.pure,
  'std.bitwise_not': Capability.pure,
  'std.left_shift': Capability.pure,
  'std.right_shift': Capability.pure,
  'std.unsigned_right_shift': Capability.pure,

  // ── std: increment/decrement (pure) ──
  'std.pre_increment': Capability.pure,
  'std.pre_decrement': Capability.pure,
  'std.post_increment': Capability.pure,
  'std.post_decrement': Capability.pure,

  // ── std: string & conversion (pure) ──
  'std.concat': Capability.pure,
  'std.length': Capability.pure,
  'std.to_string': Capability.pure,
  'std.int_to_string': Capability.pure,
  'std.double_to_string': Capability.pure,
  'std.string_to_int': Capability.pure,
  'std.string_to_double': Capability.pure,

  // ── std: null safety (pure) ──
  'std.null_coalesce': Capability.pure,
  'std.null_check': Capability.pure,

  // ── std: control flow (pure) ──
  'std.if': Capability.pure,
  'std.for': Capability.pure,
  'std.for_in': Capability.pure,
  'std.while': Capability.pure,
  'std.do_while': Capability.pure,
  'std.switch': Capability.pure,

  // ── std: error handling (pure) ──
  'std.try': Capability.pure,
  'std.throw': Capability.pure,
  'std.rethrow': Capability.pure,

  // ── std: assertions (pure) ──
  'std.assert': Capability.pure,

  // ── std: flow control (pure) ──
  'std.return': Capability.pure,
  'std.break': Capability.pure,
  'std.continue': Capability.pure,

  // ── std: generators & async ──
  'std.yield': Capability.async,
  'std.yield_each': Capability.async,
  'std.await': Capability.async,
  'std.async': Capability.async,

  // ── std: assignment (pure) ──
  'std.assign': Capability.pure,
  'std.compound_assign': Capability.pure,

  // ── std: type operations (pure) ──
  'std.is': Capability.pure,
  'std.is_not': Capability.pure,
  'std.as': Capability.pure,

  // ── std: indexing (pure) ──
  'std.index': Capability.pure,
  'std.index_assign': Capability.pure,

  // ── std: labels (pure) ──
  'std.labeled': Capability.pure,
  'std.label': Capability.pure,
  'std.goto': Capability.pure,
  'std.paren': Capability.pure,

  // ── std: string operations (pure) ──
  'std.string_length': Capability.pure,
  'std.string_is_empty': Capability.pure,
  'std.string_concat': Capability.pure,
  'std.string_contains': Capability.pure,
  'std.string_starts_with': Capability.pure,
  'std.string_ends_with': Capability.pure,
  'std.string_index_of': Capability.pure,
  'std.string_last_index_of': Capability.pure,
  'std.string_substring': Capability.pure,
  'std.string_char_at': Capability.pure,
  'std.string_char_code_at': Capability.pure,
  'std.string_from_char_code': Capability.pure,
  'std.string_to_upper': Capability.pure,
  'std.string_to_lower': Capability.pure,
  'std.string_trim': Capability.pure,
  'std.string_trim_start': Capability.pure,
  'std.string_trim_end': Capability.pure,
  'std.string_replace': Capability.pure,
  'std.string_replace_all': Capability.pure,
  'std.string_split': Capability.pure,
  'std.string_repeat': Capability.pure,
  'std.string_pad_left': Capability.pure,
  'std.string_pad_right': Capability.pure,
  'std.string_interpolation': Capability.pure,

  // ── std: regex (pure) ──
  'std.regex_match': Capability.pure,
  'std.regex_find': Capability.pure,
  'std.regex_find_all': Capability.pure,
  'std.regex_replace': Capability.pure,
  'std.regex_replace_all': Capability.pure,

  // ── std: math (pure) ──
  'std.math_abs': Capability.pure,
  'std.math_floor': Capability.pure,
  'std.math_ceil': Capability.pure,
  'std.math_round': Capability.pure,
  'std.math_trunc': Capability.pure,
  'std.math_sqrt': Capability.pure,
  'std.math_pow': Capability.pure,
  'std.math_log': Capability.pure,
  'std.math_log2': Capability.pure,
  'std.math_log10': Capability.pure,
  'std.math_exp': Capability.pure,
  'std.math_sin': Capability.pure,
  'std.math_cos': Capability.pure,
  'std.math_tan': Capability.pure,
  'std.math_asin': Capability.pure,
  'std.math_acos': Capability.pure,
  'std.math_atan': Capability.pure,
  'std.math_atan2': Capability.pure,
  'std.math_min': Capability.pure,
  'std.math_max': Capability.pure,
  'std.math_clamp': Capability.pure,
  'std.math_pi': Capability.pure,
  'std.math_e': Capability.pure,
  'std.math_infinity': Capability.pure,
  'std.math_nan': Capability.pure,
  'std.math_is_nan': Capability.pure,
  'std.math_is_finite': Capability.pure,
  'std.math_is_infinite': Capability.pure,
  'std.math_sign': Capability.pure,
  'std.math_gcd': Capability.pure,
  'std.math_lcm': Capability.pure,

  // ── std_io ──
  'std_io.print_error': Capability.io,
  'std_io.read_line': Capability.io,
  'std_io.exit': Capability.process,
  'std_io.panic': Capability.process,
  'std_io.sleep_ms': Capability.time,
  'std_io.timestamp_ms': Capability.time,
  'std_io.random_int': Capability.random,
  'std_io.random_double': Capability.random,
  'std_io.env_get': Capability.io,
  'std_io.args_get': Capability.io,

  // ── std_fs ──
  'std_fs.file_read': Capability.fs,
  'std_fs.file_read_bytes': Capability.fs,
  'std_fs.file_write': Capability.fs,
  'std_fs.file_write_bytes': Capability.fs,
  'std_fs.file_append': Capability.fs,
  'std_fs.file_exists': Capability.fs,
  'std_fs.file_delete': Capability.fs,
  'std_fs.dir_list': Capability.fs,
  'std_fs.dir_create': Capability.fs,
  'std_fs.dir_exists': Capability.fs,

  // ── std_collections (all pure) ──
  'std_collections.list_push': Capability.pure,
  'std_collections.list_pop': Capability.pure,
  'std_collections.list_insert': Capability.pure,
  'std_collections.list_remove_at': Capability.pure,
  'std_collections.list_get': Capability.pure,
  'std_collections.list_set': Capability.pure,
  'std_collections.list_length': Capability.pure,
  'std_collections.list_is_empty': Capability.pure,
  'std_collections.list_first': Capability.pure,
  'std_collections.list_last': Capability.pure,
  'std_collections.list_single': Capability.pure,
  'std_collections.list_contains': Capability.pure,
  'std_collections.list_index_of': Capability.pure,
  'std_collections.list_map': Capability.pure,
  'std_collections.list_filter': Capability.pure,
  'std_collections.list_reduce': Capability.pure,
  'std_collections.list_find': Capability.pure,
  'std_collections.list_any': Capability.pure,
  'std_collections.list_all': Capability.pure,
  'std_collections.list_none': Capability.pure,
  'std_collections.list_sort': Capability.pure,
  'std_collections.list_sort_by': Capability.pure,
  'std_collections.list_reverse': Capability.pure,
  'std_collections.list_slice': Capability.pure,
  'std_collections.list_flat_map': Capability.pure,
  'std_collections.list_zip': Capability.pure,
  'std_collections.list_take': Capability.pure,
  'std_collections.list_drop': Capability.pure,
  'std_collections.list_concat': Capability.pure,
  'std_collections.map_get': Capability.pure,
  'std_collections.map_set': Capability.pure,
  'std_collections.map_delete': Capability.pure,
  'std_collections.map_contains_key': Capability.pure,
  'std_collections.map_keys': Capability.pure,
  'std_collections.map_values': Capability.pure,
  'std_collections.map_entries': Capability.pure,
  'std_collections.map_from_entries': Capability.pure,
  'std_collections.map_merge': Capability.pure,
  'std_collections.map_map': Capability.pure,
  'std_collections.map_filter': Capability.pure,
  'std_collections.map_is_empty': Capability.pure,
  'std_collections.map_length': Capability.pure,
  'std_collections.set_create': Capability.pure,
  'std_collections.set_add': Capability.pure,
  'std_collections.set_remove': Capability.pure,
  'std_collections.set_contains': Capability.pure,
  'std_collections.set_union': Capability.pure,
  'std_collections.set_intersection': Capability.pure,
  'std_collections.set_difference': Capability.pure,
  'std_collections.set_length': Capability.pure,
  'std_collections.set_is_empty': Capability.pure,
  'std_collections.set_to_list': Capability.pure,
  'std_collections.string_join': Capability.pure,

  // ── std_convert (all pure) ──
  'std_convert.json_encode': Capability.pure,
  'std_convert.json_decode': Capability.pure,
  'std_convert.utf8_encode': Capability.pure,
  'std_convert.utf8_decode': Capability.pure,
  'std_convert.base64_encode': Capability.pure,
  'std_convert.base64_decode': Capability.pure,

  // ── std_time ──
  'std_time.now': Capability.time,
  'std_time.now_micros': Capability.time,
  'std_time.format_timestamp': Capability.time,
  'std_time.parse_timestamp': Capability.time,
  'std_time.duration_add': Capability.pure,
  'std_time.duration_subtract': Capability.pure,
  'std_time.year': Capability.time,
  'std_time.month': Capability.time,
  'std_time.day': Capability.time,
  'std_time.hour': Capability.time,
  'std_time.minute': Capability.time,
  'std_time.second': Capability.time,

  // ── std_memory (all memory/unsafe) ──
  'std_memory.memory_alloc': Capability.memory,
  'std_memory.memory_free': Capability.memory,
  'std_memory.memory_realloc': Capability.memory,
  'std_memory.memory_read_i8': Capability.memory,
  'std_memory.memory_read_u8': Capability.memory,
  'std_memory.memory_read_i16': Capability.memory,
  'std_memory.memory_read_u16': Capability.memory,
  'std_memory.memory_read_i32': Capability.memory,
  'std_memory.memory_read_u32': Capability.memory,
  'std_memory.memory_read_i64': Capability.memory,
  'std_memory.memory_read_u64': Capability.memory,
  'std_memory.memory_read_f32': Capability.memory,
  'std_memory.memory_read_f64': Capability.memory,
  'std_memory.memory_write_i8': Capability.memory,
  'std_memory.memory_write_u8': Capability.memory,
  'std_memory.memory_write_i16': Capability.memory,
  'std_memory.memory_write_u16': Capability.memory,
  'std_memory.memory_write_i32': Capability.memory,
  'std_memory.memory_write_u32': Capability.memory,
  'std_memory.memory_write_i64': Capability.memory,
  'std_memory.memory_write_u64': Capability.memory,
  'std_memory.memory_write_f32': Capability.memory,
  'std_memory.memory_write_f64': Capability.memory,
  'std_memory.memory_copy': Capability.memory,
  'std_memory.memory_set': Capability.memory,
  'std_memory.memory_compare': Capability.memory,
  'std_memory.ptr_add': Capability.memory,
  'std_memory.ptr_sub': Capability.memory,
  'std_memory.ptr_diff': Capability.memory,
  'std_memory.stack_alloc': Capability.memory,
  'std_memory.stack_push_frame': Capability.memory,
  'std_memory.stack_pop_frame': Capability.memory,
  'std_memory.memory_sizeof': Capability.memory,
  'std_memory.address_of': Capability.memory,
  'std_memory.deref': Capability.memory,
  'std_memory.nullptr': Capability.memory,
  'std_memory.memory_heap_size': Capability.memory,
  'std_memory.memory_stack_size': Capability.memory,

  // ── std_concurrency ──
  'std_concurrency.thread_spawn': Capability.concurrency,
  'std_concurrency.thread_join': Capability.concurrency,
  'std_concurrency.mutex_create': Capability.concurrency,
  'std_concurrency.mutex_lock': Capability.concurrency,
  'std_concurrency.mutex_unlock': Capability.concurrency,
  'std_concurrency.scoped_lock': Capability.concurrency,
  'std_concurrency.atomic_load': Capability.concurrency,
  'std_concurrency.atomic_store': Capability.concurrency,
  'std_concurrency.atomic_compare_exchange': Capability.concurrency,
};
