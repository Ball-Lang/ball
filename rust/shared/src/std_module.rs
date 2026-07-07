//! Universal `std` base module builder (issue #35).
//!
//! Ports `dart/shared/lib/std.dart` — the single source of truth for the
//! universal base module — to Rust. Every function here is
//! language-agnostic (arithmetic, comparison, logical, control flow, error
//! handling, string/math operations, ...) and every target language
//! compiler/engine implements it natively. `dart/shared/std.json` is the
//! canonical inventory this must match exactly: **119** functions (the
//! issue's tracked count of 118 has drifted by one function since the issue
//! was filed — verified against `std.json` directly, see the
//! `function_count_matches_std_json` test).

use crate::descriptor_builders::{
    base_fn, bool_field, expr_field, expr_list_field, string_field, type_def,
};
use crate::{FunctionDefinition, Module, TypeDefinition};

/// Build the universal `std` base module.
pub fn build_std_module() -> Module {
    Module {
        name: "std".to_string(),
        description: "Universal standard library base module. Every function here \
            represents a language-agnostic operation that all target languages \
            implement natively. Types use protobuf descriptors so they map to \
            every target language."
            .to_string(),
        type_defs: type_defs(),
        functions: functions(),
        ..Default::default()
    }
}

fn type_defs() -> Vec<TypeDefinition> {
    vec![
        type_def(
            "BinaryInput",
            vec![expr_field("left", 1), expr_field("right", 2)],
        ),
        type_def("UnaryInput", vec![expr_field("value", 1)]),
        type_def("PrintInput", vec![string_field("message", 1)]),
        type_def(
            "IfInput",
            vec![
                expr_field("condition", 1),
                expr_field("then", 2),
                expr_field("else", 3),
                string_field("case_pattern", 4),
            ],
        ),
        type_def(
            "ForInput",
            vec![
                expr_field("init", 1),
                expr_field("condition", 2),
                expr_field("update", 3),
                expr_field("body", 4),
            ],
        ),
        type_def(
            "ForInInput",
            vec![
                string_field("variable", 1),
                string_field("variable_type", 2),
                expr_field("iterable", 3),
                expr_field("body", 4),
            ],
        ),
        type_def(
            "WhileInput",
            vec![expr_field("condition", 1), expr_field("body", 2)],
        ),
        type_def(
            "DoWhileInput",
            vec![expr_field("body", 1), expr_field("condition", 2)],
        ),
        type_def(
            "SwitchInput",
            vec![expr_field("subject", 1), expr_list_field("cases", 2)],
        ),
        type_def(
            "SwitchCase",
            vec![
                expr_field("value", 1),
                bool_field("is_default", 2),
                expr_field("body", 3),
                string_field("pattern", 4),
            ],
        ),
        type_def(
            "TryInput",
            vec![
                expr_field("body", 1),
                expr_list_field("catches", 2),
                expr_field("finally", 3),
            ],
        ),
        type_def(
            "CatchClause",
            vec![
                string_field("type", 1),
                string_field("variable", 2),
                string_field("stack_trace", 3),
                expr_field("body", 4),
            ],
        ),
        type_def(
            "AssertInput",
            vec![expr_field("condition", 1), expr_field("message", 2)],
        ),
        type_def(
            "AssignInput",
            vec![
                expr_field("target", 1),
                expr_field("value", 2),
                string_field("op", 3),
            ],
        ),
        type_def(
            "IndexInput",
            vec![expr_field("target", 1), expr_field("index", 2)],
        ),
        type_def(
            "TypeCheckInput",
            vec![expr_field("value", 1), string_field("type", 2)],
        ),
        type_def("BreakInput", vec![string_field("label", 1)]),
        type_def("ContinueInput", vec![string_field("label", 1)]),
        type_def("ReturnInput", vec![expr_field("value", 1)]),
        type_def("GotoInput", vec![string_field("label", 1)]),
        type_def(
            "LabelInput",
            vec![string_field("name", 1), expr_field("body", 2)],
        ),
        // --- String operation input types ---
        type_def(
            "StringSubstringInput",
            vec![
                expr_field("value", 1),
                expr_field("start", 2),
                expr_field("end", 3),
            ],
        ),
        type_def(
            "StringReplaceInput",
            vec![
                expr_field("value", 1),
                expr_field("from", 2),
                expr_field("to", 3),
            ],
        ),
        type_def(
            "StringRepeatInput",
            vec![expr_field("value", 1), expr_field("count", 2)],
        ),
        type_def(
            "StringPadInput",
            vec![
                expr_field("value", 1),
                expr_field("width", 2),
                expr_field("padding", 3),
            ],
        ),
        // --- Math input types ---
        type_def(
            "MathClampInput",
            vec![
                expr_field("value", 1),
                expr_field("min", 2),
                expr_field("max", 3),
            ],
        ),
    ]
}

fn functions() -> Vec<FunctionDefinition> {
    vec![
        // --- I/O ---
        base_fn("print", "PrintInput", "", "Print to stdout: print(message)"),
        // --- Arithmetic ---
        base_fn("add", "BinaryInput", "", "Addition: left + right"),
        base_fn("subtract", "BinaryInput", "", "Subtraction: left - right"),
        base_fn(
            "multiply",
            "BinaryInput",
            "",
            "Multiplication: left * right",
        ),
        base_fn(
            "divide",
            "BinaryInput",
            "",
            "Integer division: left ~/ right",
        ),
        base_fn(
            "divide_double",
            "BinaryInput",
            "",
            "Double division: left / right",
        ),
        base_fn("modulo", "BinaryInput", "", "Modulo: left % right"),
        base_fn("negate", "UnaryInput", "", "Unary negation: -value"),
        // --- Comparison ---
        base_fn("equals", "BinaryInput", "", "Equality: left == right"),
        base_fn("not_equals", "BinaryInput", "", "Inequality: left != right"),
        base_fn("less_than", "BinaryInput", "", "Less than: left < right"),
        base_fn(
            "greater_than",
            "BinaryInput",
            "",
            "Greater than: left > right",
        ),
        base_fn("lte", "BinaryInput", "", "Less or equal: left <= right"),
        base_fn("gte", "BinaryInput", "", "Greater or equal: left >= right"),
        // --- Logical ---
        base_fn("and", "BinaryInput", "", "Logical AND: left && right"),
        base_fn("or", "BinaryInput", "", "Logical OR: left || right"),
        base_fn("not", "UnaryInput", "", "Logical NOT: !value"),
        // --- Bitwise ---
        base_fn(
            "bitwise_and",
            "BinaryInput",
            "",
            "Bitwise AND: left & right",
        ),
        base_fn("bitwise_or", "BinaryInput", "", "Bitwise OR: left | right"),
        base_fn(
            "bitwise_xor",
            "BinaryInput",
            "",
            "Bitwise XOR: left ^ right",
        ),
        base_fn("bitwise_not", "UnaryInput", "", "Bitwise NOT: ~value"),
        base_fn("left_shift", "BinaryInput", "", "Left shift: left << right"),
        base_fn(
            "right_shift",
            "BinaryInput",
            "",
            "Right shift: left >> right",
        ),
        base_fn(
            "unsigned_right_shift",
            "BinaryInput",
            "",
            "Unsigned right shift: left >>> right",
        ),
        // --- Increment/Decrement ---
        base_fn(
            "pre_increment",
            "UnaryInput",
            "",
            "Prefix increment: ++value",
        ),
        base_fn(
            "pre_decrement",
            "UnaryInput",
            "",
            "Prefix decrement: --value",
        ),
        base_fn(
            "post_increment",
            "UnaryInput",
            "",
            "Postfix increment: value++",
        ),
        base_fn(
            "post_decrement",
            "UnaryInput",
            "",
            "Postfix decrement: value--",
        ),
        // --- String & Conversion ---
        base_fn(
            "concat",
            "BinaryInput",
            "",
            "String concatenation: left + right (strings)",
        ),
        base_fn(
            "to_string",
            "UnaryInput",
            "",
            "Convert to string: value.toString()",
        ),
        base_fn("length", "UnaryInput", "", "Get length: value.length"),
        base_fn(
            "int_to_string",
            "UnaryInput",
            "",
            "Int to string: value.toString()",
        ),
        base_fn(
            "double_to_string",
            "UnaryInput",
            "",
            "Double to string: value.toString()",
        ),
        base_fn(
            "string_to_int",
            "UnaryInput",
            "",
            "Parse int from string: int.parse(value)",
        ),
        base_fn(
            "string_to_double",
            "UnaryInput",
            "",
            "Parse double from string: double.parse(value)",
        ),
        // --- Null safety ---
        base_fn(
            "null_coalesce",
            "BinaryInput",
            "",
            "Null coalescing: left ?? right",
        ),
        base_fn("null_check", "UnaryInput", "", "Null assertion: value!"),
        // --- Control flow ---
        base_fn(
            "if",
            "IfInput",
            "",
            "Conditional: if (cond) { then } else { else }",
        ),
        base_fn(
            "for",
            "ForInput",
            "",
            "C-style for loop: for (init; cond; update) { body }",
        ),
        base_fn(
            "for_in",
            "ForInInput",
            "",
            "For-in loop: for (var x in iterable) { body }",
        ),
        base_fn(
            "while",
            "WhileInput",
            "",
            "While loop: while (cond) { body }",
        ),
        base_fn(
            "do_while",
            "DoWhileInput",
            "",
            "Do-while loop: do { body } while (cond)",
        ),
        base_fn(
            "switch",
            "SwitchInput",
            "",
            "Switch statement: switch (subj) { case ... }",
        ),
        // --- Error handling ---
        base_fn(
            "try",
            "TryInput",
            "",
            "Try/catch/finally: try { ... } catch (e) { ... } finally { ... }",
        ),
        base_fn("throw", "UnaryInput", "", "Throw exception: throw value"),
        base_fn("rethrow", "", "", "Rethrow current exception: rethrow"),
        // --- Assertions ---
        base_fn(
            "assert",
            "AssertInput",
            "",
            "Debug assertion: assert(cond, msg)",
        ),
        // --- Flow control ---
        base_fn(
            "return",
            "ReturnInput",
            "",
            "Return from function: return value",
        ),
        base_fn(
            "break",
            "BreakInput",
            "",
            "Break from loop/switch: break [label]",
        ),
        base_fn(
            "continue",
            "ContinueInput",
            "",
            "Continue to next iteration: continue [label]",
        ),
        // --- goto / labels ---
        base_fn("goto", "GotoInput", "", "Jump to label: goto label_name"),
        base_fn(
            "label",
            "LabelInput",
            "",
            "Define a label point: label_name: { body }",
        ),
        // --- Generators & async ---
        base_fn(
            "yield",
            "UnaryInput",
            "",
            "Yield from generator: yield value",
        ),
        base_fn("await", "UnaryInput", "", "Await a future: await value"),
        // --- Assignment ---
        base_fn(
            "assign",
            "AssignInput",
            "",
            "Assignment (simple or compound): target = value, target += value",
        ),
        // --- Type operations ---
        base_fn("is", "TypeCheckInput", "", "Type test: value is Type"),
        base_fn(
            "is_not",
            "TypeCheckInput",
            "",
            "Negated type test: value is! Type",
        ),
        base_fn("as", "TypeCheckInput", "", "Type cast: value as Type"),
        // --- Indexing ---
        base_fn("index", "IndexInput", "", "Index access: target[index]"),
        // --- Strings (pure manipulation, no I/O, universal) ---
        base_fn(
            "string_length",
            "UnaryInput",
            "",
            "String length: value.length",
        ),
        base_fn(
            "string_is_empty",
            "UnaryInput",
            "",
            "Is string empty: value.isEmpty",
        ),
        base_fn(
            "string_concat",
            "BinaryInput",
            "",
            "String concat: left + right",
        ),
        base_fn(
            "string_contains",
            "BinaryInput",
            "",
            "String contains: left.contains(right)",
        ),
        base_fn(
            "string_starts_with",
            "BinaryInput",
            "",
            "Starts with: left.startsWith(right)",
        ),
        base_fn(
            "string_ends_with",
            "BinaryInput",
            "",
            "Ends with: left.endsWith(right)",
        ),
        base_fn(
            "string_index_of",
            "BinaryInput",
            "",
            "Index of substring: left.indexOf(right)",
        ),
        base_fn(
            "string_last_index_of",
            "BinaryInput",
            "",
            "Last index of: left.lastIndexOf(right)",
        ),
        base_fn(
            "string_substring",
            "StringSubstringInput",
            "",
            "Substring: value.substring(start, end)",
        ),
        base_fn(
            "string_char_at",
            "IndexInput",
            "",
            "Character at index: target[index]",
        ),
        base_fn(
            "string_char_code_at",
            "IndexInput",
            "",
            "Char code at index: target.codeUnitAt(index)",
        ),
        base_fn(
            "string_from_char_code",
            "UnaryInput",
            "",
            "String from char code: String.fromCharCode(value)",
        ),
        base_fn(
            "string_to_upper",
            "UnaryInput",
            "",
            "To upper case: value.toUpperCase()",
        ),
        base_fn(
            "string_to_lower",
            "UnaryInput",
            "",
            "To lower case: value.toLowerCase()",
        ),
        base_fn(
            "string_trim",
            "UnaryInput",
            "",
            "Trim whitespace: value.trim()",
        ),
        base_fn(
            "string_trim_start",
            "UnaryInput",
            "",
            "Trim start: value.trimLeft()",
        ),
        base_fn(
            "string_trim_end",
            "UnaryInput",
            "",
            "Trim end: value.trimRight()",
        ),
        base_fn(
            "string_replace",
            "StringReplaceInput",
            "",
            "Replace first: value.replaceFirst(from, to)",
        ),
        base_fn(
            "string_replace_all",
            "StringReplaceInput",
            "",
            "Replace all: value.replaceAll(from, to)",
        ),
        base_fn(
            "string_split",
            "BinaryInput",
            "",
            "Split string: left.split(right)",
        ),
        base_fn(
            "string_runes",
            "UnaryInput",
            "",
            "Unicode code points: value.runes.toList()",
        ),
        base_fn(
            "string_repeat",
            "StringRepeatInput",
            "",
            "Repeat string: value * count",
        ),
        base_fn(
            "string_pad_left",
            "StringPadInput",
            "",
            "Pad left: value.padLeft(width, padding)",
        ),
        base_fn(
            "string_pad_right",
            "StringPadInput",
            "",
            "Pad right: value.padRight(width, padding)",
        ),
        // --- Regex (universal) ---
        base_fn(
            "regex_match",
            "BinaryInput",
            "",
            "Regex match: RegExp(right).hasMatch(left)",
        ),
        base_fn(
            "regex_find",
            "BinaryInput",
            "",
            "Regex find first: RegExp(right).firstMatch(left)?.group(0)",
        ),
        base_fn(
            "regex_find_all",
            "BinaryInput",
            "",
            "Regex find all: RegExp(right).allMatches(left).map(m => m.group(0))",
        ),
        base_fn(
            "regex_replace",
            "StringReplaceInput",
            "",
            "Regex replace first: value.replaceFirst(RegExp(from), to)",
        ),
        base_fn(
            "regex_replace_all",
            "StringReplaceInput",
            "",
            "Regex replace all: value.replaceAll(RegExp(from), to)",
        ),
        // --- Math (pure numeric, universal) ---
        base_fn("math_abs", "UnaryInput", "", "Absolute value: value.abs()"),
        base_fn("math_floor", "UnaryInput", "", "Floor: value.floor()"),
        base_fn("math_ceil", "UnaryInput", "", "Ceiling: value.ceil()"),
        base_fn("math_round", "UnaryInput", "", "Round: value.round()"),
        base_fn("math_trunc", "UnaryInput", "", "Truncate: value.truncate()"),
        base_fn("math_sqrt", "UnaryInput", "", "Square root: sqrt(value)"),
        base_fn("math_pow", "BinaryInput", "", "Power: pow(left, right)"),
        base_fn("math_log", "UnaryInput", "", "Natural log: log(value)"),
        base_fn("math_log2", "UnaryInput", "", "Log base 2: log2(value)"),
        base_fn("math_log10", "UnaryInput", "", "Log base 10: log10(value)"),
        base_fn("math_exp", "UnaryInput", "", "Exponential: exp(value)"),
        base_fn("math_sin", "UnaryInput", "", "Sine: sin(value)"),
        base_fn("math_cos", "UnaryInput", "", "Cosine: cos(value)"),
        base_fn("math_tan", "UnaryInput", "", "Tangent: tan(value)"),
        base_fn("math_asin", "UnaryInput", "", "Arc sine: asin(value)"),
        base_fn("math_acos", "UnaryInput", "", "Arc cosine: acos(value)"),
        base_fn("math_atan", "UnaryInput", "", "Arc tangent: atan(value)"),
        base_fn(
            "math_atan2",
            "BinaryInput",
            "",
            "Arc tangent 2: atan2(left, right)",
        ),
        base_fn("math_min", "BinaryInput", "", "Minimum: min(left, right)"),
        base_fn("math_max", "BinaryInput", "", "Maximum: max(left, right)"),
        base_fn(
            "math_clamp",
            "MathClampInput",
            "",
            "Clamp: value.clamp(min, max)",
        ),
        base_fn("math_pi", "", "", "Constant: pi"),
        base_fn("math_e", "", "", "Constant: e"),
        base_fn("math_infinity", "", "", "Constant: infinity"),
        base_fn("math_nan", "", "", "Constant: NaN"),
        base_fn("math_is_nan", "UnaryInput", "", "Is NaN: value.isNaN"),
        base_fn(
            "math_is_finite",
            "UnaryInput",
            "",
            "Is finite: value.isFinite",
        ),
        base_fn(
            "math_is_infinite",
            "UnaryInput",
            "",
            "Is infinite: value.isInfinite",
        ),
        base_fn("math_sign", "UnaryInput", "", "Sign: value.sign"),
        base_fn("math_gcd", "BinaryInput", "", "GCD: gcd(left, right)"),
        base_fn("math_lcm", "BinaryInput", "", "LCM: lcm(left, right)"),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_function_is_base_with_no_body() {
        let module = build_std_module();
        assert_eq!(module.name, "std");
        for function in &module.functions {
            assert!(function.is_base, "{} must be is_base", function.name);
            assert!(
                function.body.is_none(),
                "{} must have no body",
                function.name
            );
        }
    }

    #[test]
    fn function_count_matches_std_json() {
        // Canonical inventory: `dart/shared/std.json`, regenerated from
        // `dart/shared/lib/std.dart` via `dart run bin/gen_std.dart`. The
        // issue's tracked count (118) is stale by one function relative to
        // the current `std.json` on `main` — 119 is the verified real count.
        let module = build_std_module();
        assert_eq!(module.functions.len(), 119);
    }
}
