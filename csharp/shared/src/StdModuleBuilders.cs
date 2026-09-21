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
            TypeDef("CompareToInput", ExprField("value", 1), ExprField("other", 2)),
            // Shared by to_string_as_fixed / to_string_as_exponential (both take
            // `digits`) and to_string_as_precision (`precision`).
            TypeDef("NumFormatInput", ExprField("value", 1), ExprField("digits", 2), ExprField("precision", 3)),
            TypeDef("MathClampInput", ExprField("value", 1), ExprField("min", 2), ExprField("max", 3)),
            // Text-sink input types (issue #630). A sink is an opaque runtime
            // value, so `sink` is an ordinary expression field (the shape
            // `UnaryInput.value` uses); `initial` is optional.
            TypeDef("SinkCreateInput", ExprField("initial", 1)),
            TypeDef("SinkWriteInput", ExprField("sink", 1), ExprField("text", 2)),
            TypeDef("SinkToStringInput", ExprField("sink", 1)),
            // Language-construct input types (issue #702). Ported from
            // `dart/shared/lib/std.dart`, where the reasoning lives: every
            // construct below was dispatched by the engines and emitted by the
            // encoders while no builder declared it.
            TypeDef("CascadeInput", ExprField("target", 1), ExprField("sections", 2), BoolField("null_aware", 3)),
            TypeDef("NullAwareAccessInput", ExprField("target", 1), StringField("field", 2)),
            TypeDef("NullAwareCallInput", ExprField("target", 1), StringField("method", 2)),
            TypeDef("InvokeInput", ExprField("callee", 1)),
            TypeDef("TearOffInput", ExprField("callback", 1), ExprField("target", 2), StringField("method", 3)),
            TypeDef("SymbolInput", StringField("value", 1)),
            TypeDef("TypeLiteralInput", StringField("type", 1)),
            TypeDef("LabeledInput", StringField("label", 1), ExprField("body", 2)),
            TypeDef("TypedListInput", StringField("type_args", 1), ExprField("elements", 2)),
            TypeDef("MapCreateInput", StringField("type_args", 1), ExprListField("entry", 2), ExprListField("element", 3)),
            TypeDef("MapCreateEntry", ExprField("key", 1), ExprField("value", 2)),
            TypeDef("RecordInput", ExprField("fields", 1)),
            TypeDef("CollectionForInput", StringField("variable", 1), ExprField("iterable", 2), ExprField("init", 3), ExprField("condition", 4), ExprField("update", 5), ExprField("body", 6)),
            TypeDef("SwitchExprInput", ExprField("subject", 1), ExprField("cases", 2)),
            TypeDef("SwitchExprCase", StringField("pattern", 1), ExprField("body", 2), ExprField("pattern_expr", 3), ExprField("guard", 4), BoolField("is_default", 5)),
            TypeDef("ListFilledInput", ExprField("length", 1), ExprField("value", 2)),
            TypeDef("ListGenerateInput", ExprField("length", 1), ExprField("generator", 2)),
            TypeDef("StringInterpolationInput", ExprField("parts", 1), ExprField("value", 2)),
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
            BaseFn("to_double", "UnaryInput", "", "To double: value.toDouble()"),
            BaseFn("to_int", "UnaryInput", "", "To int: value.toInt()"),
            BaseFn("compare_to", "CompareToInput", "", "Three-way compare: value.compareTo(other)"),
            BaseFn("to_string_as_fixed", "NumFormatInput", "", "Fixed-point string: value.toStringAsFixed(digits)"),
            BaseFn("to_string_as_exponential", "NumFormatInput", "", "Exponential string: value.toStringAsExponential([digits])"),
            BaseFn("to_string_as_precision", "NumFormatInput", "", "Precision string: value.toStringAsPrecision(precision)"),
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
            BaseFn(
                "type_of",
                "UnaryInput",
                "",
                "Runtime type name: value.runtimeType.toString() / JS typeof. "
                + "Returns the canonical base type name (int, double, String, bool, "
                + "List, Map, Set, Function, Null, or a user class's short name) "
                + "with generic type arguments dropped and any module prefix stripped."),
            // Indexing
            BaseFn("index", "IndexInput", "", "Index access: target[index]"),
            // Strings (pure manipulation, universal)
            BaseFn("string_length", "UnaryInput", "", "String length: value.length"),
            BaseFn("string_is_empty", "UnaryInput", "", "Is string empty: value.isEmpty"),
            BaseFn("string_is_not_empty", "UnaryInput", "", "Is string non-empty: value.isNotEmpty (issue #674)"),
            BaseFn("string_concat", "BinaryInput", "", "String concat: left + right"),
            BaseFn("string_contains", "BinaryInput", "", "String contains: left.contains(right)"),
            BaseFn("string_starts_with", "BinaryInput", "", "Starts with: left.startsWith(right)"),
            BaseFn("string_ends_with", "BinaryInput", "", "Ends with: left.endsWith(right)"),
            BaseFn("string_index_of", "BinaryInput", "", "Index of substring: left.indexOf(right)"),
            BaseFn("string_last_index_of", "BinaryInput", "", "Last index of: left.lastIndexOf(right)"),
            BaseFn("string_substring", "StringSubstringInput", "", "Substring: value.substring(start, end)"),
            BaseFn("string_char_at", "IndexInput", "", "Character at index: target[index]"),
            BaseFn("string_char_code_at", "IndexInput", "", "Char code at index: target.codeUnitAt(index)"),
            // Dart-flavoured alias of string_char_code_at (same engine handler).
            BaseFn("string_code_unit_at", "IndexInput", "", "Code unit at index: target.codeUnitAt(index)"),
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
            // Text sink (issue #630) — the common denominator of Dart's
            // StringBuffer, Rust's fmt::Write, Go's strings.Builder, C#'s
            // StringBuilder, Python's io.StringIO and C++'s ostringstream:
            // append-only text accumulation with a terminal read. `writeln`
            // desugars to sink_write + "\n", so three functions are the whole
            // abstraction. NORMATIVE: a sink is a REFERENCE-SEMANTIC,
            // `__type__`-tagged value — std.type_of answers "Sink", and an
            // append performed inside a callee is visible to the caller.
            BaseFn("sink_create", "SinkCreateInput", "", "Create a text sink, optionally seeded: StringBuffer(initial)"),
            BaseFn("sink_write", "SinkWriteInput", "", "Append text to a sink: sink.write(text)"),
            BaseFn("sink_to_string", "SinkToStringInput", "String", "Read a sink back: sink.toString()"),
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
            // Language constructs (issue #702). Every name below was already
            // dispatched by the engines, keyed by the capability table and run
            // by the conformance corpus while NO builder declared it — the
            // #505 class, now gated in both directions
            // (`dart/shared/test/std_reverse_closed_set_test.dart`).
            BaseFn("int_to_double", "UnaryInput", "", "Int to double: value.toDouble() (statically an int)"),
            BaseFn("double_to_int", "UnaryInput", "", "Double to int, truncating toward zero: value.toInt()"),
            BaseFn("ceil_to_double", "UnaryInput", "", "Ceiling as a double: value.ceilToDouble()"),
            BaseFn("floor_to_double", "UnaryInput", "", "Floor as a double: value.floorToDouble()"),
            BaseFn("round_to_double", "UnaryInput", "", "Round as a double: value.roundToDouble()"),
            BaseFn("truncate_to_double", "UnaryInput", "", "Truncate as a double: value.truncateToDouble()"),
            BaseFn("null_aware_access", "NullAwareAccessInput", "", "Null-aware field access: target?.field — null when target is null"),
            BaseFn("null_aware_call", "NullAwareCallInput", "", "Null-aware method call: target?.method(args) — null when target is null"),
            BaseFn("paren", "UnaryInput", "", "Parenthesized expression: (value) — preserves operator precedence"),
            BaseFn("labeled", "LabeledInput", "", "Labeled statement: label: <body> — the target of a labelled break/continue"),
            BaseFn("yield_each", "UnaryInput", "", "Delegate to another generator: yield* value"),
            BaseFn("type_literal", "TypeLiteralInput", "", "A type used as a value: int, Box<int> — carries the type source text"),
            BaseFn("cascade", "CascadeInput", "", "Cascade: target..a()..b — evaluates each section against target and returns TARGET, not the last section"),
            BaseFn("null_aware_cascade", "CascadeInput", "", "Null-aware cascade: target?..a()..b — null when target is null"),
            BaseFn("invoke", "InvokeInput", "", "Call a function VALUE: callee(args). The arguments are the input's remaining fields; a single argument is passed through directly."),
            BaseFn("tear_off", "TearOffInput", "", "Function tear-off: the function value named by callback, or by target.method — never invoked"),
            BaseFn("symbol", "SymbolInput", "", "Symbol literal: #value"),
            BaseFn("record", "RecordInput", "", "Record literal: (a, b, name: c). Positional components are the input's $1, $2, … fields (1-based, matching Dart's record.$1) and named components carry their own name."),
            BaseFn("typed_list", "TypedListInput", "", "List literal with explicit type arguments: <T>[elements]"),
            BaseFn("map_create", "MapCreateInput", "", "Map literal: {k: v, …}. Each plain pair is one `entry` field; a comprehension element is spliced through `element`."),
            BaseFn("list_filled", "ListFilledInput", "", "Fixed-size list of one repeated value: List.filled(length, value). Engines also accept `count` for `length`."),
            BaseFn("list_generate", "ListGenerateInput", "", "List built by index: List.generate(length, generator). Engines also accept `count` for `length` and `callback` for `generator`."),
            BaseFn("dart_list_filled", "ListFilledInput", "", "List.filled(length, value) reached as a constructor call"),
            BaseFn("dart_list_generate", "ListGenerateInput", "", "List.generate(length, generator) reached as a constructor call"),
            BaseFn("spread", "UnaryInput", "", "Spread element inside a collection literal: ...value"),
            BaseFn("null_spread", "UnaryInput", "", "Null-aware spread element: ...?value — contributes nothing when null"),
            BaseFn("collection_if", "IfInput", "", "Conditional element inside a collection literal: [if (condition) then else else]"),
            BaseFn("collection_for", "CollectionForInput", "", "Comprehension element inside a collection literal: [for (variable in iterable) body] / [for (init; condition; update) body]"),
            BaseFn("switch_expr", "SwitchExprInput", "", "Switch EXPRESSION: switch (subject) { pattern => body, … } — yields a value, unlike the std.switch statement"),
            BaseFn("string_interpolation", "StringInterpolationInput", "", "String interpolation: 'a${b}c' — stringify each element of `parts` and concatenate in order"),
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
            // NO seed field — `list_reduce` is Dart's `Iterable.reduce`, not `fold`.
            // The `initial` this carried until #771 was read by no engine, compiler or
            // encoder on any target.
            TypeDef("ListReduceInput", ExprField("list", 1), ExprField("callback", 2)),
            TypeDef("ListSliceInput", ExprField("list", 1), ExprField("start", 2), ExprField("end", 3)),
            TypeDef("MapInput", ExprField("map", 1), ExprField("key", 2), ExprField("value", 3)),
            TypeDef("MapCallbackInput", ExprField("map", 1), ExprField("callback", 2)),
            TypeDef("StringJoinInput", ExprField("list", 1), ExprField("separator", 2)),
            TypeDef("SetInput", ExprField("set", 1), ExprField("value", 2)),
            TypeDef("SetCallbackInput", ExprField("set", 1), ExprField("callback", 2)),
            TypeDef("SetBinaryInput", ExprField("left", 1), ExprField("right", 2)),
            // `set_create` declared `ListInput` until #771, while every encoder writes
            // `{type_args?, elements}` and every engine reads `elements`.
            TypeDef("SetCreateInput", StringField("type_args", 1), ExprField("elements", 2)),
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
            BaseFn("list_reduce", "ListReduceInput", "", "Reduce: list.reduce(callback) — the accumulator starts at the first element, so an empty list is an error. Engines also accept `function` or `value` for `callback`."),
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
            BaseFn("list_clear", "ListInput", "", "Remove all elements: list.clear()"),
            BaseFn("list_to_list", "ListInput", "", "Copy to a list: list.toList()"),
            BaseFn("list_foreach", "ListCallbackInput", "", "Iterate: list.forEach(callback)"),
            BaseFn("list_join", "StringJoinInput", "", "Join elements: list.join(separator)"),
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
            BaseFn("map_contains_value", "MapInput", "", "Contains value: map.containsValue(value)"),
            BaseFn("map_put_if_absent", "MapInput", "", "Insert if absent: map.putIfAbsent(key, () => value)"),
            BaseFn("map_is_empty", "MapInput", "", "Is empty: map.isEmpty"),
            BaseFn("map_length", "MapInput", "", "Map size: map.length"),
            // String <-> collection bridge
            BaseFn("string_join", "StringJoinInput", "", "Join list of strings: list.join(separator)"),
            // Set — unordered, unique elements
            BaseFn("set_create", "SetCreateInput", "", "Set literal: <type_args>{elements}. `elements` is one expression holding the element list; `type_args` is the literal's explicit type arguments, if written."),
            // "bool", not "" — issue #545 made set_add/set_remove Dart-exact on
            // every target (mutate the receiver in place, answer true only on a
            // fresh insert / an actual removal) and declared that in
            // dart/shared/lib/std_collections.dart; this port kept "", so the
            // declared contract disagreed with the implemented one on the C#
            // side while both name-parity gates stayed green (issue #557).
            // StdModuleBuilderTests.AssertOutputTypesMatch is what now sees it.
            BaseFn("set_add", "SetInput", "bool", "Add element: set.add(value). Mutates the set in place; returns true only when the element was newly inserted (Dart Set.add semantics)."),
            BaseFn("set_remove", "SetInput", "bool", "Remove element: set.remove(value). Mutates the set in place; returns true only when the element was present (Dart Set.remove semantics)."),
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
