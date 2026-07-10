using Ball.V1;
using static Ball.Shared.DescriptorBuilders;

namespace Ball.Shared;

/// <summary>
/// Builders for the universal base modules — the C# port of
/// <c>dart/shared/lib/std*.dart</c> (canonical inventory
/// <c>dart/shared/std.json</c>) and its Rust sibling
/// <c>rust/shared/src/std_*_module.rs</c>. Every function is a base function
/// (<c>is_base = true</c>, no body); the per-platform compiler/engine supplies
/// the implementation (invariant #3). The function counts/names are asserted
/// against the canonical Dart inventory in the test project — never hardcoded.
/// </summary>
public static class StdModuleBuilders
{
    /// <summary>Build the universal <c>std</c> base module (119 functions).</summary>
    public static Module BuildStdModule()
    {
        var module = new Module
        {
            Name = "std",
            Description = "Universal standard library base module. Every function here "
                + "represents a language-agnostic operation that all target languages "
                + "implement natively. Types use protobuf descriptors so they map to "
                + "every target language.",
        };

        module.TypeDefs.AddRange(new[]
        {
            TypeDef("BinaryInput", ExprField("left", 1), ExprField("right", 2)),
            TypeDef("UnaryInput", ExprField("value", 1)),
            TypeDef("PrintInput", StringField("message", 1)),
            TypeDef("IfInput", ExprField("condition", 1), ExprField("then", 2), ExprField("else", 3), StringField("case_pattern", 4)),
            TypeDef("ForInput", ExprField("init", 1), ExprField("condition", 2), ExprField("update", 3), ExprField("body", 4)),
            TypeDef("ForInInput", StringField("variable", 1), StringField("variable_type", 2), ExprField("iterable", 3), ExprField("body", 4)),
            TypeDef("WhileInput", ExprField("condition", 1), ExprField("body", 2)),
            TypeDef("DoWhileInput", ExprField("body", 1), ExprField("condition", 2)),
            TypeDef("SwitchInput", ExprField("subject", 1), ExprListField("cases", 2)),
            TypeDef("SwitchCase", ExprField("value", 1), BoolField("is_default", 2), ExprField("body", 3), StringField("pattern", 4)),
            TypeDef("TryInput", ExprField("body", 1), ExprListField("catches", 2), ExprField("finally", 3)),
            TypeDef("CatchClause", StringField("type", 1), StringField("variable", 2), StringField("stack_trace", 3), ExprField("body", 4)),
            TypeDef("AssertInput", ExprField("condition", 1), ExprField("message", 2)),
            TypeDef("AssignInput", ExprField("target", 1), ExprField("value", 2), StringField("op", 3)),
            TypeDef("IndexInput", ExprField("target", 1), ExprField("index", 2)),
            TypeDef("TypeCheckInput", ExprField("value", 1), StringField("type", 2)),
            TypeDef("BreakInput", StringField("label", 1)),
            TypeDef("ContinueInput", StringField("label", 1)),
            TypeDef("ReturnInput", ExprField("value", 1)),
            TypeDef("GotoInput", StringField("label", 1)),
            TypeDef("LabelInput", StringField("name", 1), ExprField("body", 2)),
            TypeDef("StringSubstringInput", ExprField("value", 1), ExprField("start", 2), ExprField("end", 3)),
            TypeDef("StringReplaceInput", ExprField("value", 1), ExprField("from", 2), ExprField("to", 3)),
            TypeDef("StringRepeatInput", ExprField("value", 1), ExprField("count", 2)),
            TypeDef("StringPadInput", ExprField("value", 1), ExprField("width", 2), ExprField("padding", 3)),
            TypeDef("MathClampInput", ExprField("value", 1), ExprField("min", 2), ExprField("max", 3)),
        });

        module.Functions.AddRange(new[]
        {
            // I/O
            BaseFn("print", "PrintInput", "", "Print to stdout: print(message)"),
            // Arithmetic
            BaseFn("add", "BinaryInput", "", "Addition: left + right"),
            BaseFn("subtract", "BinaryInput", "", "Subtraction: left - right"),
            BaseFn("multiply", "BinaryInput", "", "Multiplication: left * right"),
            BaseFn("divide", "BinaryInput", "", "Integer division: left ~/ right"),
            BaseFn("divide_double", "BinaryInput", "", "Double division: left / right"),
            BaseFn("modulo", "BinaryInput", "", "Modulo: left % right"),
            BaseFn("negate", "UnaryInput", "", "Unary negation: -value"),
            // Comparison
            BaseFn("equals", "BinaryInput", "", "Equality: left == right"),
            BaseFn("not_equals", "BinaryInput", "", "Inequality: left != right"),
            BaseFn("less_than", "BinaryInput", "", "Less than: left < right"),
            BaseFn("greater_than", "BinaryInput", "", "Greater than: left > right"),
            BaseFn("lte", "BinaryInput", "", "Less or equal: left <= right"),
            BaseFn("gte", "BinaryInput", "", "Greater or equal: left >= right"),
            // Logical
            BaseFn("and", "BinaryInput", "", "Logical AND: left && right"),
            BaseFn("or", "BinaryInput", "", "Logical OR: left || right"),
            BaseFn("not", "UnaryInput", "", "Logical NOT: !value"),
            // Bitwise
            BaseFn("bitwise_and", "BinaryInput", "", "Bitwise AND: left & right"),
            BaseFn("bitwise_or", "BinaryInput", "", "Bitwise OR: left | right"),
            BaseFn("bitwise_xor", "BinaryInput", "", "Bitwise XOR: left ^ right"),
            BaseFn("bitwise_not", "UnaryInput", "", "Bitwise NOT: ~value"),
            BaseFn("left_shift", "BinaryInput", "", "Left shift: left << right"),
            BaseFn("right_shift", "BinaryInput", "", "Right shift: left >> right"),
            BaseFn("unsigned_right_shift", "BinaryInput", "", "Unsigned right shift: left >>> right"),
            // Increment/Decrement
            BaseFn("pre_increment", "UnaryInput", "", "Prefix increment: ++value"),
            BaseFn("pre_decrement", "UnaryInput", "", "Prefix decrement: --value"),
            BaseFn("post_increment", "UnaryInput", "", "Postfix increment: value++"),
            BaseFn("post_decrement", "UnaryInput", "", "Postfix decrement: value--"),
            // String & Conversion
            BaseFn("concat", "BinaryInput", "", "String concatenation: left + right (strings)"),
            BaseFn("to_string", "UnaryInput", "", "Convert to string: value.toString()"),
            BaseFn("length", "UnaryInput", "", "Get length: value.length"),
            BaseFn("int_to_string", "UnaryInput", "", "Int to string: value.toString()"),
            BaseFn("double_to_string", "UnaryInput", "", "Double to string: value.toString()"),
            BaseFn("string_to_int", "UnaryInput", "", "Parse int from string: int.parse(value)"),
            BaseFn("string_to_double", "UnaryInput", "", "Parse double from string: double.parse(value)"),
            // Null safety
            BaseFn("null_coalesce", "BinaryInput", "", "Null coalescing: left ?? right"),
            BaseFn("null_check", "UnaryInput", "", "Null assertion: value!"),
            // Control flow
            BaseFn("if", "IfInput", "", "Conditional: if (cond) { then } else { else }"),
            BaseFn("for", "ForInput", "", "C-style for loop: for (init; cond; update) { body }"),
            BaseFn("for_in", "ForInInput", "", "For-in loop: for (var x in iterable) { body }"),
            BaseFn("while", "WhileInput", "", "While loop: while (cond) { body }"),
            BaseFn("do_while", "DoWhileInput", "", "Do-while loop: do { body } while (cond)"),
            BaseFn("switch", "SwitchInput", "", "Switch statement: switch (subj) { case ... }"),
            // Error handling
            BaseFn("try", "TryInput", "", "Try/catch/finally: try { ... } catch (e) { ... } finally { ... }"),
            BaseFn("throw", "UnaryInput", "", "Throw exception: throw value"),
            BaseFn("rethrow", "", "", "Rethrow current exception: rethrow"),
            // Assertions
            BaseFn("assert", "AssertInput", "", "Debug assertion: assert(cond, msg)"),
            // Flow control
            BaseFn("return", "ReturnInput", "", "Return from function: return value"),
            BaseFn("break", "BreakInput", "", "Break from loop/switch: break [label]"),
            BaseFn("continue", "ContinueInput", "", "Continue to next iteration: continue [label]"),
            // goto / labels
            BaseFn("goto", "GotoInput", "", "Jump to label: goto label_name"),
            BaseFn("label", "LabelInput", "", "Define a label point: label_name: { body }"),
            // Generators & async
            BaseFn("yield", "UnaryInput", "", "Yield from generator: yield value"),
            BaseFn("await", "UnaryInput", "", "Await a future: await value"),
            // Assignment
            BaseFn("assign", "AssignInput", "", "Assignment (simple or compound): target = value, target += value"),
            // Type operations
            BaseFn("is", "TypeCheckInput", "", "Type test: value is Type"),
            BaseFn("is_not", "TypeCheckInput", "", "Negated type test: value is! Type"),
            BaseFn("as", "TypeCheckInput", "", "Type cast: value as Type"),
            // Indexing
            BaseFn("index", "IndexInput", "", "Index access: target[index]"),
            // Strings (pure manipulation, universal)
            BaseFn("string_length", "UnaryInput", "", "String length: value.length"),
            BaseFn("string_is_empty", "UnaryInput", "", "Is string empty: value.isEmpty"),
            BaseFn("string_concat", "BinaryInput", "", "String concat: left + right"),
            BaseFn("string_contains", "BinaryInput", "", "String contains: left.contains(right)"),
            BaseFn("string_starts_with", "BinaryInput", "", "Starts with: left.startsWith(right)"),
            BaseFn("string_ends_with", "BinaryInput", "", "Ends with: left.endsWith(right)"),
            BaseFn("string_index_of", "BinaryInput", "", "Index of substring: left.indexOf(right)"),
            BaseFn("string_last_index_of", "BinaryInput", "", "Last index of: left.lastIndexOf(right)"),
            BaseFn("string_substring", "StringSubstringInput", "", "Substring: value.substring(start, end)"),
            BaseFn("string_char_at", "IndexInput", "", "Character at index: target[index]"),
            BaseFn("string_char_code_at", "IndexInput", "", "Char code at index: target.codeUnitAt(index)"),
            BaseFn("string_from_char_code", "UnaryInput", "", "String from char code: String.fromCharCode(value)"),
            BaseFn("string_to_upper", "UnaryInput", "", "To upper case: value.toUpperCase()"),
            BaseFn("string_to_lower", "UnaryInput", "", "To lower case: value.toLowerCase()"),
            BaseFn("string_trim", "UnaryInput", "", "Trim whitespace: value.trim()"),
            BaseFn("string_trim_start", "UnaryInput", "", "Trim start: value.trimLeft()"),
            BaseFn("string_trim_end", "UnaryInput", "", "Trim end: value.trimRight()"),
            BaseFn("string_replace", "StringReplaceInput", "", "Replace first: value.replaceFirst(from, to)"),
            BaseFn("string_replace_all", "StringReplaceInput", "", "Replace all: value.replaceAll(from, to)"),
            BaseFn("string_split", "BinaryInput", "", "Split string: left.split(right)"),
            BaseFn("string_runes", "UnaryInput", "", "Unicode code points: value.runes.toList()"),
            BaseFn("string_repeat", "StringRepeatInput", "", "Repeat string: value * count"),
            BaseFn("string_pad_left", "StringPadInput", "", "Pad left: value.padLeft(width, padding)"),
            BaseFn("string_pad_right", "StringPadInput", "", "Pad right: value.padRight(width, padding)"),
            // Regex (universal)
            BaseFn("regex_match", "BinaryInput", "", "Regex match: RegExp(right).hasMatch(left)"),
            BaseFn("regex_find", "BinaryInput", "", "Regex find first: RegExp(right).firstMatch(left)?.group(0)"),
            BaseFn("regex_find_all", "BinaryInput", "", "Regex find all: RegExp(right).allMatches(left).map(m => m.group(0))"),
            BaseFn("regex_replace", "StringReplaceInput", "", "Regex replace first: value.replaceFirst(RegExp(from), to)"),
            BaseFn("regex_replace_all", "StringReplaceInput", "", "Regex replace all: value.replaceAll(RegExp(from), to)"),
            // Math (pure numeric, universal)
            BaseFn("math_abs", "UnaryInput", "", "Absolute value: value.abs()"),
            BaseFn("math_floor", "UnaryInput", "", "Floor: value.floor()"),
            BaseFn("math_ceil", "UnaryInput", "", "Ceiling: value.ceil()"),
            BaseFn("math_round", "UnaryInput", "", "Round: value.round()"),
            BaseFn("math_trunc", "UnaryInput", "", "Truncate: value.truncate()"),
            BaseFn("math_sqrt", "UnaryInput", "", "Square root: sqrt(value)"),
            BaseFn("math_pow", "BinaryInput", "", "Power: pow(left, right)"),
            BaseFn("math_log", "UnaryInput", "", "Natural log: log(value)"),
            BaseFn("math_log2", "UnaryInput", "", "Log base 2: log2(value)"),
            BaseFn("math_log10", "UnaryInput", "", "Log base 10: log10(value)"),
            BaseFn("math_exp", "UnaryInput", "", "Exponential: exp(value)"),
            BaseFn("math_sin", "UnaryInput", "", "Sine: sin(value)"),
            BaseFn("math_cos", "UnaryInput", "", "Cosine: cos(value)"),
            BaseFn("math_tan", "UnaryInput", "", "Tangent: tan(value)"),
            BaseFn("math_asin", "UnaryInput", "", "Arc sine: asin(value)"),
            BaseFn("math_acos", "UnaryInput", "", "Arc cosine: acos(value)"),
            BaseFn("math_atan", "UnaryInput", "", "Arc tangent: atan(value)"),
            BaseFn("math_atan2", "BinaryInput", "", "Arc tangent 2: atan2(left, right)"),
            BaseFn("math_min", "BinaryInput", "", "Minimum: min(left, right)"),
            BaseFn("math_max", "BinaryInput", "", "Maximum: max(left, right)"),
            BaseFn("math_clamp", "MathClampInput", "", "Clamp: value.clamp(min, max)"),
            BaseFn("math_pi", "", "", "Constant: pi"),
            BaseFn("math_e", "", "", "Constant: e"),
            BaseFn("math_infinity", "", "", "Constant: infinity"),
            BaseFn("math_nan", "", "", "Constant: NaN"),
            BaseFn("math_is_nan", "UnaryInput", "", "Is NaN: value.isNaN"),
            BaseFn("math_is_finite", "UnaryInput", "", "Is finite: value.isFinite"),
            BaseFn("math_is_infinite", "UnaryInput", "", "Is infinite: value.isInfinite"),
            BaseFn("math_sign", "UnaryInput", "", "Sign: value.sign"),
            BaseFn("math_gcd", "BinaryInput", "", "GCD: gcd(left, right)"),
            BaseFn("math_lcm", "BinaryInput", "", "LCM: lcm(left, right)"),
        });

        return module;
    }

    /// <summary>Build the <c>std_collections</c> base module (53 functions).</summary>
    public static Module BuildStdCollectionsModule()
    {
        var module = new Module
        {
            Name = "std_collections",
            Description = "Standard collections module. List and map operations. "
                + "Separate from std because not all runtimes support mutable "
                + "collections natively.",
        };

        module.TypeDefs.AddRange(new[]
        {
            TypeDef("ListInput", ExprField("list", 1), ExprField("index", 2), ExprField("value", 3)),
            TypeDef("ListCallbackInput", ExprField("list", 1), ExprField("callback", 2)),
            TypeDef("ListReduceInput", ExprField("list", 1), ExprField("callback", 2), ExprField("initial", 3)),
            TypeDef("ListSliceInput", ExprField("list", 1), ExprField("start", 2), ExprField("end", 3)),
            TypeDef("MapInput", ExprField("map", 1), ExprField("key", 2), ExprField("value", 3)),
            TypeDef("MapCallbackInput", ExprField("map", 1), ExprField("callback", 2)),
            TypeDef("StringJoinInput", ExprField("list", 1), ExprField("separator", 2)),
            TypeDef("SetInput", ExprField("set", 1), ExprField("value", 2)),
            TypeDef("SetCallbackInput", ExprField("set", 1), ExprField("callback", 2)),
            TypeDef("SetBinaryInput", ExprField("left", 1), ExprField("right", 2)),
        });

        module.Functions.AddRange(new[]
        {
            // List — indexed, ordered
            BaseFn("list_push", "ListInput", "", "Append to list: list.add(value)"),
            BaseFn("list_pop", "ListInput", "", "Remove last: list.removeLast()"),
            BaseFn("list_insert", "ListInput", "", "Insert at index: list.insert(index, value)"),
            BaseFn("list_remove_at", "ListInput", "", "Remove at index: list.removeAt(index)"),
            BaseFn("list_get", "ListInput", "", "Get element: list[index]"),
            BaseFn("list_set", "ListInput", "", "Set element: list[index] = value"),
            BaseFn("list_length", "ListInput", "", "List length: list.length"),
            BaseFn("list_is_empty", "ListInput", "", "Is empty: list.isEmpty"),
            BaseFn("list_first", "ListInput", "", "First element: list.first"),
            BaseFn("list_last", "ListInput", "", "Last element: list.last"),
            BaseFn("list_single", "ListInput", "", "Single element: list.single"),
            BaseFn("list_contains", "ListInput", "", "Contains element: list.contains(value)"),
            BaseFn("list_index_of", "ListInput", "", "Index of element: list.indexOf(value)"),
            BaseFn("list_map", "ListCallbackInput", "", "Map: list.map(callback)"),
            BaseFn("list_filter", "ListCallbackInput", "", "Filter: list.where(callback)"),
            BaseFn("list_reduce", "ListReduceInput", "", "Reduce: list.fold(initial, callback)"),
            BaseFn("list_find", "ListCallbackInput", "", "Find first: list.firstWhere(callback)"),
            BaseFn("list_any", "ListCallbackInput", "", "Any match: list.any(callback)"),
            BaseFn("list_all", "ListCallbackInput", "", "All match: list.every(callback)"),
            BaseFn("list_none", "ListCallbackInput", "", "None match: !list.any(callback)"),
            BaseFn("list_sort", "ListCallbackInput", "", "Sort: list.sort(compare)"),
            BaseFn("list_sort_by", "ListCallbackInput", "", "Sort by key: list.sort((a,b) => key(a).compareTo(key(b)))"),
            BaseFn("list_reverse", "ListInput", "", "Reverse: list.reversed.toList()"),
            BaseFn("list_slice", "ListSliceInput", "", "Slice: list.sublist(start, end)"),
            BaseFn("list_flat_map", "ListCallbackInput", "", "Flat map: list.expand(callback)"),
            BaseFn("list_zip", "ListInput", "", "Zip two lists: zip(list, other)"),
            BaseFn("list_take", "ListInput", "", "Take N: list.take(n)"),
            BaseFn("list_drop", "ListInput", "", "Drop N: list.skip(n)"),
            BaseFn("list_concat", "ListInput", "", "Concat two lists: list + other"),
            // Map — key/value
            BaseFn("map_get", "MapInput", "", "Get value: map[key]"),
            BaseFn("map_set", "MapInput", "", "Set value: map[key] = value"),
            BaseFn("map_delete", "MapInput", "", "Delete key: map.remove(key)"),
            BaseFn("map_contains_key", "MapInput", "", "Contains key: map.containsKey(key)"),
            BaseFn("map_keys", "MapInput", "", "All keys: map.keys"),
            BaseFn("map_values", "MapInput", "", "All values: map.values"),
            BaseFn("map_entries", "MapInput", "", "All entries: map.entries"),
            BaseFn("map_from_entries", "ListInput", "", "Map from entries: Map.fromEntries(list)"),
            BaseFn("map_merge", "MapInput", "", "Merge two maps: {...a, ...b}"),
            BaseFn("map_map", "MapCallbackInput", "", "Map over map: map.map(callback)"),
            BaseFn("map_filter", "MapCallbackInput", "", "Filter map: Map.fromEntries(map.entries.where(callback))"),
            BaseFn("map_is_empty", "MapInput", "", "Is empty: map.isEmpty"),
            BaseFn("map_length", "MapInput", "", "Map size: map.length"),
            // String <-> collection bridge
            BaseFn("string_join", "StringJoinInput", "", "Join list of strings: list.join(separator)"),
            // Set — unordered, unique elements
            BaseFn("set_create", "ListInput", "", "Create set from list: Set.from(list)"),
            BaseFn("set_add", "SetInput", "", "Add element: set.add(value)"),
            BaseFn("set_remove", "SetInput", "", "Remove element: set.remove(value)"),
            BaseFn("set_contains", "SetInput", "", "Contains element: set.contains(value)"),
            BaseFn("set_union", "SetBinaryInput", "", "Union: left.union(right)"),
            BaseFn("set_intersection", "SetBinaryInput", "", "Intersection: left.intersection(right)"),
            BaseFn("set_difference", "SetBinaryInput", "", "Difference: left.difference(right)"),
            BaseFn("set_length", "SetInput", "", "Set size: set.length"),
            BaseFn("set_is_empty", "SetInput", "", "Is empty: set.isEmpty"),
            BaseFn("set_to_list", "SetInput", "", "To list: set.toList()"),
        });

        return module;
    }

    /// <summary>Build the <c>std_io</c> base module (10 functions).</summary>
    public static Module BuildStdIoModule()
    {
        var module = new Module
        {
            Name = "std_io",
            Description = "Standard I/O module. Console, process, time, random, environment. "
                + "Not available in all runtimes (browser, WASM, embedded).",
        };

        module.TypeDefs.AddRange(new[]
        {
            TypeDef("PrintErrorInput", StringField("message", 1)),
            TypeDef("ExitInput", IntField("code", 1)),
            TypeDef("PanicInput", StringField("message", 1)),
            TypeDef("SleepInput", IntField("milliseconds", 1)),
            TypeDef("RandomIntInput", IntField("min", 1), IntField("max", 2)),
            TypeDef("EnvGetInput", StringField("name", 1)),
        });

        module.Functions.AddRange(new[]
        {
            BaseFn("print_error", "PrintErrorInput", "", "Write to stderr: stderr.writeln(message)"),
            BaseFn("read_line", "", "", "Read one line from stdin"),
            BaseFn("exit", "ExitInput", "", "Terminate with exit code"),
            BaseFn("panic", "PanicInput", "", "Hard abort with message (Rust panic!, C++ terminate, Java RuntimeException)"),
            BaseFn("sleep_ms", "SleepInput", "", "Pause execution N milliseconds"),
            BaseFn("timestamp_ms", "", "", "Wall clock milliseconds since epoch"),
            BaseFn("random_int", "RandomIntInput", "", "Random integer in range [min, max]"),
            BaseFn("random_double", "", "", "Random double in [0.0, 1.0)"),
            BaseFn("env_get", "EnvGetInput", "", "Read environment variable by name"),
            BaseFn("args_get", "", "", "Command-line arguments as list of strings"),
        });

        return module;
    }

    /// <summary>Build the <c>std_memory</c> base module (38 functions).</summary>
    public static Module BuildStdMemoryModule()
    {
        var module = new Module
        {
            Name = "std_memory",
            Description = "Linear memory simulation module. Provides heap allocation, "
                + "typed reads/writes, pointer arithmetic, and stack frame management. "
                + "Used by the hybrid normalizer when C/C++ code performs raw pointer "
                + "operations that cannot be safely projected to native references.",
        };

        module.TypeDefs.AddRange(new[]
        {
            TypeDef("AllocInput", IntField("size", 1)),
            TypeDef("FreeInput", IntField("address", 1)),
            TypeDef("ReallocInput", IntField("address", 1), IntField("new_size", 2)),
            TypeDef("MemReadInput", IntField("address", 1)),
            TypeDef("MemWriteInput", IntField("address", 1), ExprField("value", 2)),
            TypeDef("MemCopyInput", IntField("dest", 1), IntField("src", 2), IntField("size", 3)),
            TypeDef("MemSetInput", IntField("address", 1), IntField("value", 2), IntField("size", 3)),
            TypeDef("MemCompareInput", IntField("a", 1), IntField("b", 2), IntField("size", 3)),
            TypeDef("PtrArithInput", IntField("address", 1), IntField("offset", 2), IntField("element_size", 3)),
            TypeDef("StackAllocInput", IntField("size", 1)),
            TypeDef("SizeofInput", StringField("type_name", 1)),
            TypeDef("AddressOfInput", ExprField("value", 1)),
            TypeDef("DerefInput", ExprField("pointer", 1)),
        });

        module.Functions.AddRange(new[]
        {
            // Heap allocation
            BaseFn("memory_alloc", "AllocInput", "", "Allocate size bytes on the heap. Returns base address (int)."),
            BaseFn("memory_free", "FreeInput", "", "Free a previously allocated block at address."),
            BaseFn("memory_realloc", "ReallocInput", "", "Resize a previously allocated block. Returns new base address."),
            // Typed reads (little-endian)
            BaseFn("memory_read_i8", "MemReadInput", "", "Read signed 8-bit integer at address."),
            BaseFn("memory_read_u8", "MemReadInput", "", "Read unsigned 8-bit integer at address."),
            BaseFn("memory_read_i16", "MemReadInput", "", "Read signed 16-bit integer at address."),
            BaseFn("memory_read_u16", "MemReadInput", "", "Read unsigned 16-bit integer at address."),
            BaseFn("memory_read_i32", "MemReadInput", "", "Read signed 32-bit integer at address."),
            BaseFn("memory_read_u32", "MemReadInput", "", "Read unsigned 32-bit integer at address."),
            BaseFn("memory_read_i64", "MemReadInput", "", "Read signed 64-bit integer at address."),
            BaseFn("memory_read_u64", "MemReadInput", "", "Read unsigned 64-bit integer at address."),
            BaseFn("memory_read_f32", "MemReadInput", "", "Read 32-bit float at address."),
            BaseFn("memory_read_f64", "MemReadInput", "", "Read 64-bit float (double) at address."),
            // Typed writes (little-endian)
            BaseFn("memory_write_i8", "MemWriteInput", "", "Write signed 8-bit integer at address."),
            BaseFn("memory_write_u8", "MemWriteInput", "", "Write unsigned 8-bit integer at address."),
            BaseFn("memory_write_i16", "MemWriteInput", "", "Write signed 16-bit integer at address."),
            BaseFn("memory_write_u16", "MemWriteInput", "", "Write unsigned 16-bit integer at address."),
            BaseFn("memory_write_i32", "MemWriteInput", "", "Write signed 32-bit integer at address."),
            BaseFn("memory_write_u32", "MemWriteInput", "", "Write unsigned 32-bit integer at address."),
            BaseFn("memory_write_i64", "MemWriteInput", "", "Write signed 64-bit integer at address."),
            BaseFn("memory_write_u64", "MemWriteInput", "", "Write unsigned 64-bit integer at address."),
            BaseFn("memory_write_f32", "MemWriteInput", "", "Write 32-bit float at address."),
            BaseFn("memory_write_f64", "MemWriteInput", "", "Write 64-bit float (double) at address."),
            // Bulk operations
            BaseFn("memory_copy", "MemCopyInput", "", "Copy size bytes from src to dest (memmove-safe)."),
            BaseFn("memory_set", "MemSetInput", "", "Fill size bytes at address with value (memset)."),
            BaseFn("memory_compare", "MemCompareInput", "", "Compare size bytes at a and b. Returns <0, 0, or >0 (memcmp)."),
            // Pointer arithmetic
            BaseFn("ptr_add", "PtrArithInput", "", "Pointer add: address + offset * element_size."),
            BaseFn("ptr_sub", "PtrArithInput", "", "Pointer subtract: address - offset * element_size."),
            BaseFn("ptr_diff", "PtrArithInput", "", "Pointer difference: (a - b) / element_size."),
            // Stack frame
            BaseFn("stack_alloc", "StackAllocInput", "", "Allocate size bytes on the stack frame. Returns base address."),
            BaseFn("stack_push_frame", "", "", "Push a new stack frame (function entry)."),
            BaseFn("stack_pop_frame", "", "", "Pop the current stack frame (function exit). Frees all stack_alloc in this frame."),
            // Sizeof
            BaseFn("memory_sizeof", "SizeofInput", "", "Return the byte size of a named type (e.g. \"int32\" -> 4)."),
            // Address-of / dereference (pre-normalization)
            BaseFn("address_of", "AddressOfInput", "", "Take the address of a value. Pre-normalization placeholder."),
            BaseFn("deref", "DerefInput", "", "Dereference a pointer. Pre-normalization placeholder."),
            // Null pointer
            BaseFn("nullptr", "", "", "Null pointer constant (address 0)."),
            // Memory info
            BaseFn("memory_heap_size", "", "", "Current total heap size in bytes."),
            BaseFn("memory_stack_size", "", "", "Current stack usage in bytes."),
        });

        return module;
    }
}
