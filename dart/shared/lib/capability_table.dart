/// Static mapping of every Ball base function to its capability category.
///
/// Since every side effect in Ball flows through a named base function in a
/// known module, this table is provably complete. No function can perform I/O,
/// access the filesystem, or spawn threads without appearing here.
///
/// This is a `part of 'cli_core.dart'` (engine-safe authoring rules apply —
/// see `cli_core.dart`): capability categories are plain **Strings** (not a
/// Dart `enum`, which cannot self-host), and the table is built procedurally so
/// it round-trips through `DartEncoder` and executes on the Ball engine.
part of 'cli_core.dart';

/// The capability category names, in report-iteration order. Each program
/// function is tagged with a subset of these; `'pure'` means no side effects.
///
/// `'custom'` (issues #609, #683) is the one category this table cannot
/// describe: it marks a call into a base function the program DECLARES but
/// this table does not model — the host extension seam (`BallModuleHandler`),
/// whose implementation is supplied per platform and is therefore outside the
/// language's known side-effect surface. It is never `pure`; see
/// [capabilityRisk].
///
/// **This list is a closed set.** `proto/ball/v1/ball.proto`'s
/// `CapabilityEntry.capability` doc comment enumerates it for consumers, and
/// `dart/shared/test/capability_table_closed_set_test.dart` asserts the two
/// agree — so a new category cannot drift the published schema silently.
List<String> capabilityNames() {
  return <String>[
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
    'custom',
  ];
}

/// Risk level associated with a capability name (`'none'` for `'pure'`).
///
/// `'custom'` is `'unknown'` — not `'low'` and not `'high'`. The audit knows
/// only that the program calls into a host-supplied module; ranking that call
/// would be a fabrication, and calling it harmless would be the #609 bug.
///
/// The set of levels this can return is closed and mirrored by
/// `CapabilityEntry.risk_level`'s doc comment in `ball.proto`; the closed-set
/// suite asserts the two agree.
String capabilityRisk(String capability) {
  if (capability == 'pure') return 'none';
  if (capability == 'io') return 'low';
  if (capability == 'fs') return 'medium';
  if (capability == 'process') return 'high';
  if (capability == 'time') return 'low';
  if (capability == 'random') return 'low';
  if (capability == 'memory') return 'high';
  if (capability == 'concurrency') return 'medium';
  if (capability == 'network') return 'high';
  if (capability == 'async') return 'low';
  if (capability == 'custom') return 'unknown';
  return 'none';
}

/// The capability of a base function call, or `''` for non-base / user-defined
/// functions (which are pure by construction — they can only call other
/// functions in this table). [table] is a `buildCapabilityTable()` result.
String lookupCapability(Map table, String module, String function) {
  final key = '$module.$function';
  if (table.containsKey(key)) {
    return table[key] as String;
  }
  return '';
}

/// The base module names keyed in [buildCapabilityTable], in scan order. The
/// audit's bare-name fallback ([lookupCapabilityByName]) walks these prefixes,
/// so this list MUST stay in sync with the modules present in the table — the
/// `capability_table` group in `capability_analyzer_test.dart` guards against
/// drift and against any bare-name collision that would make the fallback
/// ambiguous.
List<String> capabilityModuleNames() {
  return <String>[
    'std',
    'std_io',
    'std_fs',
    'std_collections',
    'std_convert',
    'std_time',
    'std_memory',
    'std_concurrency',
  ];
}

/// Whether [module] is one of the eight universal std modules this table
/// models ([capabilityModuleNames]).
///
/// Since #683 the module name alone no longer decides `'custom'` — a base
/// function is `'custom'` when the TABLE does not model it, whatever module
/// declares it. What this predicate still decides is the SCOPE of the #402
/// bare-name resolution: inside the eight std module names a declaration may
/// be resolved by bare name (the conformance corpus routinely labels a
/// collection base function `std.list_push` while the table keys
/// `std_collections.list_push` — the same base function, loosely labelled).
/// Outside them that leniency would be wrong: a host module declaring
/// `mutex_create` is not `std_concurrency.mutex_create`, and treating a
/// bare-name coincidence as evidence would re-open issue #609.
bool isKnownBaseModule(String module) {
  final modules = capabilityModuleNames();
  for (final m in modules) {
    if (m == module) return true;
  }
  return false;
}

/// Resolve a base-function capability by BARE function name alone, ignoring the
/// (attacker-controllable) call-site module. Scans the known base modules in
/// [capabilityModuleNames] and returns the capability of the single base
/// function named [function], or `''` when no base function has that name.
///
/// Every base function has a globally-unique bare name across the base modules,
/// so at most one module yields a hit and the result is unambiguous. This
/// backstops [lookupCapability] for `ball audit`: the engine dispatches a call
/// by base-function identity, not by `call.module`, so a program can name a
/// base call with a bogus module (`{module: "harmless", function:
/// "mutex_create"}`) and slip past a `(module, function)` capability lookup —
/// issue #402. Fails closed: an unrecognized name yields `''`, so a genuine
/// user call is still treated as a user call.
String lookupCapabilityByName(Map table, String function) {
  final modules = capabilityModuleNames();
  for (final m in modules) {
    final cap = lookupCapability(table, m, function);
    if (cap.isNotEmpty) {
      return cap;
    }
  }
  return '';
}

/// The base module that declares bare [function], or `''` if none does.
/// Companion to [lookupCapabilityByName] (same globally-unique-bare-name
/// guarantee, so at most one module matches) — resolves the owning module so
/// the audit can name the shadowed base function in full, e.g.
/// `std_concurrency.mutex_create` (issue #420).
String lookupBaseModuleByName(Map table, String function) {
  final modules = capabilityModuleNames();
  for (final m in modules) {
    final cap = lookupCapability(table, m, function);
    if (cap.isNotEmpty) {
      return m;
    }
  }
  return '';
}

/// Build the `"module.function" -> capability-name` table. Provably complete:
/// every base function that can perform a side effect appears here.
///
/// "Provably" is now literal (#683). Two closed-set gates in
/// `dart/shared/test/capability_table_closed_set_test.dart` assert this
/// against sources of truth on every PR:
///   * every base function the eight `buildStd*Module()` builders DECLARE has
///     an entry here, and
///   * every base function an executed conformance fixture declares RESOLVES
///     (directly, or by bare name within a std module name).
/// Before those gates 60+ declared/dispatched/executed base functions were
/// absent, which is what made a squatted `std.exec_shell` audit as pure.
///
/// A base function whose semantics this table does not model MUST NOT be
/// added with a guessed capability — leave it out and it is classified
/// `'custom'` (risk `unknown`), which is the honest answer.
Map<String, String> buildCapabilityTable() {
  return <String, String>{
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
    'std.to_int': 'pure',
    'std.to_double': 'pure',
    'std.int_to_double': 'pure',
    'std.double_to_int': 'pure',
    'std.to_string_as_fixed': 'pure',
    'std.to_string_as_exponential': 'pure',
    'std.to_string_as_precision': 'pure',
    'std.ceil_to_double': 'pure',
    'std.floor_to_double': 'pure',
    'std.round_to_double': 'pure',
    'std.truncate_to_double': 'pure',
    'std.compare_to': 'pure',

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
    'std.type_of': 'pure',
    'std.type_literal': 'pure',
    'std.symbol': 'pure',

    // ── std: expression lowerings the encoders emit (all pure) ──
    //
    // Desugarings, not effects: each one only re-shapes operands the caller
    // already evaluated. `cascade`/`null_aware_*` sequence field and method
    // accesses on a receiver; `invoke`/`tear_off` apply a value that is
    // already a function (whatever IT calls is classified at its own call
    // site); `spread`/`null_spread`/`collection_if`/`collection_for` build
    // collection literals; `switch_expr`/`record` build values. None reaches
    // the host, so `pure` is the measured answer, not a default.
    'std.cascade': 'pure',
    'std.null_aware_access': 'pure',
    'std.null_aware_call': 'pure',
    'std.null_aware_cascade': 'pure',
    'std.invoke': 'pure',
    'std.tear_off': 'pure',
    'std.spread': 'pure',
    'std.null_spread': 'pure',
    'std.collection_if': 'pure',
    'std.collection_for': 'pure',
    'std.switch_expr': 'pure',
    'std.record': 'pure',

    // ── std: collection CONSTRUCTION (pure) ──
    //
    // Keyed under `std` because that is the module the encoders declare them
    // in and the module the engines dispatch them from — `std_collections`
    // declares none of them, and duplicating the names across both modules
    // would break the globally-unique-bare-name invariant the #402 fallback
    // depends on.
    'std.typed_list': 'pure',
    'std.list_filled': 'pure',
    'std.list_generate': 'pure',
    'std.dart_list_filled': 'pure',
    'std.dart_list_generate': 'pure',
    'std.map_create': 'pure',

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
    'std.string_code_unit_at': 'pure',
    'std.string_runes': 'pure',

    // ── std: text sink (issue #630) — pure ──
    //
    // Append-only in-memory text accumulation with a terminal read. Declared in
    // universal `std` rather than `std_io` precisely so building a string does
    // NOT mark a program io-capable (see `std.dart`'s declaration comment).
    'std.sink_create': 'pure',
    'std.sink_write': 'pure',
    'std.sink_to_string': 'pure',

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
    'std_collections.list_clear': 'pure',
    'std_collections.list_foreach': 'pure',
    'std_collections.list_join': 'pure',
    'std_collections.list_to_list': 'pure',
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
    'std_collections.map_contains_value': 'pure',
    'std_collections.map_put_if_absent': 'pure',
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
    'std_concurrency.atomic_create': 'concurrency',
    'std_concurrency.atomic_load': 'concurrency',
    'std_concurrency.atomic_store': 'concurrency',
    'std_concurrency.atomic_compare_exchange': 'concurrency',
  };
}
