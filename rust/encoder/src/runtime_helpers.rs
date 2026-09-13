//! Recognizing the Ball Rust runtime's own dispatch helpers (`ball_*`).
//!
//! `ball_lang_shared::runtime` is an ordinary importable module, so
//! `ball_add(a, b)` is a perfectly normal thing to find in hand-written Rust —
//! but the reason this file exists is the ROUND-TRIP leg (issue #642):
//! `rust/compiler` emits every Ball base-function call as exactly one of these
//! free functions, imported by the compiled program's own
//! `use ball_lang_shared::runtime::*;`.
//!
//! Without this table the encoder did something WORSE than refusing them: a bare
//! `ball_add(x, y)` is syntactically a same-file function call, so
//! `encode_call`'s `encode_user_call` fallback encoded it as a call to a
//! function nobody declared. The result was a structurally valid Program that
//! died at run time with `Function "main.ball_add" not found` — a silent
//! degradation, exactly the class of bug issue #55's fail-loud doctrine exists
//! to prevent. An unmapped `ball_*` name now fails loud instead.
//!
//! Every entry is the exact INVERSE of one line in
//! `rust/compiler/src/base_call.rs`: the helper's name, the base function it is
//! the emission of, and that base function's input field for each positional
//! argument (a base call's input is always a message keyed by field name —
//! `{left, right}`, `{value}`, …). Keep the two in step. The table is
//! deliberately restricted to helpers whose shape is unambiguous:
//!
//! - fixed arity, every argument a real expression — helpers the compiler calls
//!   with a `BallValue::Null` placeholder for an omitted optional argument
//!   (`ball_string_substring`, `ball_to_string_as_exponential`) are left out
//!   rather than guessed at;
//! - a `std` base function `dart/shared/std.json` actually declares (the
//!   canonical base-function inventory);
//! - no type-name string operands (`ball_is`/`ball_as` take a Rust string
//!   literal, not an encodable expression).
//!
//! Statement-shaped lowerings (`if`/`for`/`while`/`match`) are not here at all:
//! the compiler emits them as native Rust control flow, which the encoder
//! already reads back from that syntax.

/// `ball_field_get(object, "field")` is the compiler's emission for a Ball
/// `field_access` NODE, not a base call — so it encodes back to the node rather
/// than through the table below, and only when its field operand is a string
/// literal (which is the only shape `rust/compiler` emits).
pub(crate) const BALL_FIELD_GET: &str = "ball_field_get";

/// `ball_truthy(x)` coerces a Ball value to a Rust bool at a condition site.
/// Ball performs that coercion implicitly wherever a condition is evaluated
/// (`std.and`, `std.if`, …), so it encodes back to its operand unchanged.
pub(crate) const BALL_TRUTHY: &str = "ball_truthy";

const UNARY: &[&str] = &["value"];
const BINARY: &[&str] = &["left", "right"];

/// `ball_<name>` -> `(std base function, input field per positional argument)`,
/// or `None` when the name is not a mapped runtime helper.
pub(crate) fn runtime_helper(name: &str) -> Option<(&'static str, &'static [&'static str])> {
    let entry = match name {
        // ── Arithmetic ──
        "ball_add" => ("add", BINARY),
        "ball_subtract" => ("subtract", BINARY),
        "ball_multiply" => ("multiply", BINARY),
        "ball_divide" => ("divide", BINARY),
        "ball_divide_double" => ("divide_double", BINARY),
        "ball_modulo" => ("modulo", BINARY),
        "ball_negate" => ("negate", UNARY),
        // ── Comparison ──
        "ball_equals" => ("equals", BINARY),
        "ball_not_equals" => ("not_equals", BINARY),
        "ball_less_than" => ("less_than", BINARY),
        "ball_greater_than" => ("greater_than", BINARY),
        "ball_lte" => ("lte", BINARY),
        "ball_gte" => ("gte", BINARY),
        "ball_compare_to" => ("compare_to", BINARY),
        // ── Logic / bitwise ──
        "ball_not" => ("not", UNARY),
        "ball_bitwise_and" => ("bitwise_and", BINARY),
        "ball_bitwise_or" => ("bitwise_or", BINARY),
        "ball_bitwise_xor" => ("bitwise_xor", BINARY),
        "ball_bitwise_not" => ("bitwise_not", UNARY),
        "ball_left_shift" => ("left_shift", BINARY),
        "ball_right_shift" => ("right_shift", BINARY),
        "ball_unsigned_right_shift" => ("unsigned_right_shift", BINARY),
        // ── Strings & conversion ──
        "ball_to_string" => ("to_string", UNARY),
        "ball_length" => ("length", UNARY),
        "ball_string_to_int" => ("string_to_int", UNARY),
        "ball_string_to_double" => ("string_to_double", UNARY),
        "ball_to_double" => ("to_double", UNARY),
        "ball_to_int" => ("to_int", UNARY),
        "ball_to_string_as_fixed" => ("to_string_as_fixed", &["value", "digits"] as &[&str]),
        "ball_string_code_unit_at" => ("string_code_unit_at", &["value", "index"] as &[&str]),
        "ball_null_check" => ("null_check", UNARY),
        "ball_type_of" => ("type_of", UNARY),
        "ball_throw" => ("throw", UNARY),
        "ball_string_is_empty" => ("string_is_empty", UNARY),
        "ball_string_contains" => ("string_contains", BINARY),
        "ball_string_starts_with" => ("string_starts_with", BINARY),
        "ball_string_ends_with" => ("string_ends_with", BINARY),
        "ball_string_index_of" => ("string_index_of", BINARY),
        "ball_string_last_index_of" => ("string_last_index_of", BINARY),
        "ball_string_char_code_at" => ("string_char_code_at", &["target", "index"] as &[&str]),
        "ball_string_from_char_code" => ("string_from_char_code", UNARY),
        "ball_string_to_upper" => ("string_to_upper", UNARY),
        "ball_string_to_lower" => ("string_to_lower", UNARY),
        "ball_string_trim" => ("string_trim", UNARY),
        "ball_string_trim_start" => ("string_trim_start", UNARY),
        "ball_string_trim_end" => ("string_trim_end", UNARY),
        "ball_string_replace" => ("string_replace", &["value", "from", "to"] as &[&str]),
        "ball_string_replace_all" => ("string_replace_all", &["value", "from", "to"] as &[&str]),
        "ball_string_split" => ("string_split", BINARY),
        "ball_string_runes" => ("string_runes", UNARY),
        "ball_string_repeat" => ("string_repeat", &["value", "count"] as &[&str]),
        "ball_string_pad_left" => ("string_pad_left", &["value", "width", "padding"] as &[&str]),
        "ball_string_pad_right" => (
            "string_pad_right",
            &["value", "width", "padding"] as &[&str],
        ),
        // ── Indexing ──
        "ball_index_get" => ("index", &["target", "index"] as &[&str]),
        // ── Math ──
        "ball_math_abs" => ("math_abs", UNARY),
        "ball_math_floor" => ("math_floor", UNARY),
        "ball_math_ceil" => ("math_ceil", UNARY),
        "ball_math_round" => ("math_round", UNARY),
        "ball_math_trunc" => ("math_trunc", UNARY),
        "ball_math_sqrt" => ("math_sqrt", UNARY),
        "ball_math_pow" => ("math_pow", BINARY),
        "ball_math_log" => ("math_log", UNARY),
        "ball_math_log2" => ("math_log2", UNARY),
        "ball_math_log10" => ("math_log10", UNARY),
        "ball_math_exp" => ("math_exp", UNARY),
        "ball_math_sin" => ("math_sin", UNARY),
        "ball_math_cos" => ("math_cos", UNARY),
        "ball_math_tan" => ("math_tan", UNARY),
        "ball_math_asin" => ("math_asin", UNARY),
        "ball_math_acos" => ("math_acos", UNARY),
        "ball_math_atan" => ("math_atan", UNARY),
        "ball_math_atan2" => ("math_atan2", BINARY),
        "ball_math_min" => ("math_min", BINARY),
        "ball_math_max" => ("math_max", BINARY),
        "ball_math_clamp" => ("math_clamp", &["value", "min", "max"] as &[&str]),
        "ball_math_is_nan" => ("math_is_nan", UNARY),
        "ball_math_is_finite" => ("math_is_finite", UNARY),
        "ball_math_is_infinite" => ("math_is_infinite", UNARY),
        "ball_math_sign" => ("math_sign", UNARY),
        "ball_math_gcd" => ("math_gcd", BINARY),
        "ball_math_lcm" => ("math_lcm", BINARY),
        _ => return None,
    };
    Some(entry)
}

/// Whether `name` is spelled like a Ball runtime helper at all. Used to turn an
/// UNMAPPED `ball_*` call into a loud failure instead of a call to a function
/// nobody declared — see the module doc comment.
pub(crate) fn looks_like_runtime_helper(name: &str) -> bool {
    name.starts_with("ball_")
}
