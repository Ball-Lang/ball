//! Runtime helper functions the **compiled Rust program** calls into for the
//! `std`/`std_collections`/`std_io` base-function dispatch table
//! (`rust/compiler/src/base_call.rs`, issue #37).
//!
//! ## Why these live in `ball_shared`, not in a generated preamble string
//!
//! Phase 2a (#36) embedded a small bootstrap set of these as a `&str`
//! constant (`BASE_OPS_PREAMBLE`) spliced verbatim into every compiled
//! program. That doesn't scale to the full base-function surface and can't
//! be unit-tested directly. Every language's reference implementation
//! already puts this logic in a **shared runtime library** rather than
//! generated code: Dart's operators are native (no library needed — Dart's
//! own `num`/`String` polymorphism does the dispatch), and C++ defines
//! `BallDyn::operator+`/`operator%`/... once in `cpp/shared/include/ball_dyn.h`
//! and has the compiler emit plain `a + b` that resolves through operator
//! overloading. This module is the Rust analog of `ball_dyn.h`: every
//! compiled program depends on `ball-shared` already (for `BallValue`
//! itself), so `compile_base_call` just emits calls into
//! `ball_shared::runtime::*` instead of re-deriving the same logic as text.
//!
//! ## Semantics — always match the Dart reference engine, not "whatever
//! Rust's operator does"
//!
//! Every function here was checked against either the Dart reference
//! engine (`dart/engine/lib/engine_std.dart`, the conformance oracle) or the
//! C++ reference (`cpp/shared/include/ball_dyn.h`) where the semantics
//! aren't obvious from Rust's own operators — most importantly:
//! - **`modulo` is Euclidean** (result has the sign of the divisor / is
//!   always non-negative for a positive divisor) — Dart's `int`/`double`
//!   `%` operator, *not* Rust's `%` (which keeps the sign of the dividend).
//!   Ported from `ball_dyn.h`'s `operator%`.
//! - **`divide` truncates toward zero** — this one *does* match Rust's
//!   native integer `/` directly (both truncate toward zero), confirmed
//!   against Dart's `~/` (`num.operator~/` docs: "equivalent to
//!   `(a / b).truncate()`").
//! - **`equals`/`not_equals` promote `Int`/`Double` cross-type** (Dart
//!   `0 == 0.0` is `true`) — see [`ball_shared::value::BallValue`]'s
//!   hand-written `PartialEq` impl, which every comparison here reuses.
//! - **Int arithmetic uses wrapping ops** (`wrapping_add`/...), matching
//!   Dart's fixed-width 64-bit `int` (no overflow checking) rather than
//!   Rust's debug-mode overflow panics.
//!
//! ## Scope (see the module-level scope note in `rust/compiler/src/base_call.rs`)
//!
//! This is a substantial but **not exhaustive** port of
//! `dart/shared/lib/std*.dart`'s base functions. Deliberately deferred
//! (falling back to [`ball_unsupported_base_call`] rather than a silent
//! no-op): `regex_*` (would need a new `regex` crate dependency — out of
//! this issue's scope), `list_reduce`/`list_sort`/`list_sort_by`/
//! `map_map`/`map_filter` (need genuinely multi-parameter callbacks; Ball's
//! lambda calling convention is still single-`input`-only until #38's typed
//! parameter destructuring lands), `yield`/`await` (generators/async are a
//! separate control-flow model), `goto` (no Rust equivalent without a
//! state-machine transform), and all of `std_memory` (linear-memory/pointer
//! model, not yet designed for this target).

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::value::{BallList, BallMap, BallMessage, BallValue};

// ════════════════════════════════════════════════════════════
// Internal coercion helpers
// ════════════════════════════════════════════════════════════

fn as_f64(value: &BallValue) -> f64 {
    match value {
        BallValue::Int(v) => *v as f64,
        BallValue::Double(v) => *v,
        other => panic!("ball-compiler runtime: expected a number, got {other:?}"),
    }
}

fn as_i64(value: &BallValue) -> i64 {
    match value {
        BallValue::Int(v) => *v,
        BallValue::Double(v) => *v as i64,
        other => panic!("ball-compiler runtime: expected a number, got {other:?}"),
    }
}

fn as_str(value: &BallValue) -> &str {
    match value {
        BallValue::String(s) => s,
        other => panic!("ball-compiler runtime: expected a string, got {other:?}"),
    }
}

fn as_index(value: &BallValue) -> usize {
    match value {
        BallValue::Int(v) if *v >= 0 => *v as usize,
        other => panic!("ball-compiler runtime: expected a non-negative int index, got {other:?}"),
    }
}

/// Both operands numeric (`Int`/`Double`)? Used to pick the int-fast-path vs
/// the double-promoting path in the arithmetic helpers below.
fn both_int(left: &BallValue, right: &BallValue) -> Option<(i64, i64)> {
    match (left, right) {
        (BallValue::Int(a), BallValue::Int(b)) => Some((*a, *b)),
        _ => None,
    }
}

/// Human-readable type name for panic messages (mirrors the reference
/// engines' runtime-error text closely enough to be actionable, without
/// trying to byte-match any one engine's exact wording).
fn ball_type_name(value: &BallValue) -> &'static str {
    match value {
        BallValue::Null => "Null",
        BallValue::Bool(_) => "bool",
        BallValue::Int(_) => "int",
        BallValue::Double(_) => "double",
        BallValue::String(_) => "String",
        BallValue::Bytes(_) => "bytes",
        BallValue::List(_) => "List",
        BallValue::Map(_) => "Map",
        BallValue::Function(_) => "Function",
        BallValue::Message(_) => "Message",
    }
}

// ════════════════════════════════════════════════════════════
// Truthiness / clean fallback for unimplemented base functions
// ════════════════════════════════════════════════════════════

/// `if`/`and`/`or`/`while`/`for`'s condition unwrapping. A non-`Bool`
/// condition is a malformed program (Ball's `if`/`while`/... conditions are
/// always boolean-typed by construction) — fail loud rather than guessing a
/// truthiness coercion no reference engine defines.
pub fn ball_truthy(value: BallValue) -> bool {
    match value {
        BallValue::Bool(b) => b,
        other => panic!("ball-compiler runtime: expected a bool condition, got {other:?}"),
    }
}

/// Fallback for a base function `compile_base_call` doesn't special-case.
/// Compiles to a call to *this* — not a compile-time panic — so a program
/// that never reaches the unimplemented path still compiles and runs; only
/// actually invoking it fails, loudly, naming both the function and this
/// module's scope note. See the module doc comment's "Scope" section for the
/// full deferred list.
pub fn ball_unsupported_base_call(module: &str, function: &str) -> BallValue {
    panic!(
        "ball-compiler runtime: base function '{module}.{function}' is not implemented by the \
         Rust target yet — see the scope note in rust/shared/src/runtime.rs"
    )
}

// ════════════════════════════════════════════════════════════
// Dynamic function-value dispatch (issue #39, gap #6)
// ════════════════════════════════════════════════════════════

/// Invoke a first-class function value with `input` (invariant #1 — one
/// input, one output). This is the compiled target's answer to a dynamically
/// dispatched call: a Ball `FunctionCall` whose callee is a *value* (a local
/// holding a `lambda`, a `scope.lookup(name)` result, a callback parameter),
/// not a statically-known function item, compiles to
/// `ball_call_function(<value>, <input>)` — the self-hosted engine's
/// `final bound = scope.lookup(name); bound(input)` /
/// `Function.apply(fn, args)` / `list.indexWhere(predicate)` shapes all land
/// here. A non-callable value fails loud (Ball programs never invoke a
/// non-function; the reference engines raise the same way).
pub fn ball_call_function(callee: BallValue, input: BallValue) -> BallValue {
    match callee {
        BallValue::Function(function) => function.call(input),
        other => panic!("ball-compiler runtime: value is not callable: {other:?}"),
    }
}

// ════════════════════════════════════════════════════════════
// Arithmetic
// ════════════════════════════════════════════════════════════

pub fn ball_add(left: BallValue, right: BallValue) -> BallValue {
    match (left, right) {
        (BallValue::String(a), BallValue::String(b)) => BallValue::String(a + &b),
        (BallValue::List(mut a), BallValue::List(b)) => {
            a.extend(b);
            BallValue::List(a)
        }
        (l, r) => match both_int(&l, &r) {
            Some((a, b)) => BallValue::Int(a.wrapping_add(b)),
            None => BallValue::Double(as_f64(&l) + as_f64(&r)),
        },
    }
}

pub fn ball_subtract(left: BallValue, right: BallValue) -> BallValue {
    match both_int(&left, &right) {
        Some((a, b)) => BallValue::Int(a.wrapping_sub(b)),
        None => BallValue::Double(as_f64(&left) - as_f64(&right)),
    }
}

pub fn ball_multiply(left: BallValue, right: BallValue) -> BallValue {
    match (&left, &right) {
        // Dart's `*` also repeats a String when the other operand is an int.
        (BallValue::String(s), BallValue::Int(n)) | (BallValue::Int(n), BallValue::String(s)) => {
            BallValue::String(if *n > 0 {
                s.repeat(*n as usize)
            } else {
                String::new()
            })
        }
        _ => match both_int(&left, &right) {
            Some((a, b)) => BallValue::Int(a.wrapping_mul(b)),
            None => BallValue::Double(as_f64(&left) * as_f64(&right)),
        },
    }
}

/// `divide` == Dart's `~/` (truncating division, always an `Int` result).
/// Rust's native `i64` `/` already truncates toward zero, matching Dart's
/// `~/` exactly for the int/int case.
pub fn ball_divide(left: BallValue, right: BallValue) -> BallValue {
    match both_int(&left, &right) {
        Some((a, b)) => {
            if b == 0 {
                panic!("ball-compiler runtime: IntegerDivisionByZeroException");
            }
            BallValue::Int(a / b)
        }
        None => BallValue::Int((as_f64(&left) / as_f64(&right)).trunc() as i64),
    }
}

/// `divide_double` == Dart's `/` (always a `Double` result, even for two
/// `Int` operands).
pub fn ball_divide_double(left: BallValue, right: BallValue) -> BallValue {
    BallValue::Double(as_f64(&left) / as_f64(&right))
}

/// Euclidean modulo — see the module doc comment. Ported from
/// `cpp/shared/include/ball_dyn.h`'s `BallDyn::operator%`.
pub fn ball_modulo(left: BallValue, right: BallValue) -> BallValue {
    match both_int(&left, &right) {
        Some((a, b)) => {
            if b == 0 {
                panic!("ball-compiler runtime: modulo by zero");
            }
            let r = a % b;
            BallValue::Int(if r < 0 { r + b.abs() } else { r })
        }
        None => {
            let (a, b) = (as_f64(&left), as_f64(&right));
            let r = a % b;
            BallValue::Double(if r < 0.0 { r + b.abs() } else { r })
        }
    }
}

pub fn ball_negate(value: BallValue) -> BallValue {
    match value {
        BallValue::Int(a) => BallValue::Int(a.wrapping_neg()),
        BallValue::Double(a) => BallValue::Double(-a),
        other => panic!("ball-compiler runtime: unsupported operand for negate: {other:?}"),
    }
}

// ════════════════════════════════════════════════════════════
// Comparison — reuses BallValue's own (numeric-cross-type-aware) PartialEq
// ════════════════════════════════════════════════════════════

pub fn ball_equals(left: BallValue, right: BallValue) -> BallValue {
    BallValue::Bool(left == right)
}

pub fn ball_not_equals(left: BallValue, right: BallValue) -> BallValue {
    BallValue::Bool(left != right)
}

/// Shared ordering: numeric operands compare by value (`Int`/`Double`
/// promote, matching `equals`'s cross-type rule); `String`s compare
/// lexicographically (Dart's `String.compareTo`).
fn compare(left: &BallValue, right: &BallValue) -> std::cmp::Ordering {
    match (left, right) {
        (BallValue::String(a), BallValue::String(b)) => a.cmp(b),
        _ => as_f64(left).partial_cmp(&as_f64(right)).unwrap_or_else(|| {
            panic!("ball-compiler runtime: cannot order {left:?} and {right:?}")
        }),
    }
}

pub fn ball_less_than(left: BallValue, right: BallValue) -> BallValue {
    BallValue::Bool(compare(&left, &right).is_lt())
}

pub fn ball_greater_than(left: BallValue, right: BallValue) -> BallValue {
    BallValue::Bool(compare(&left, &right).is_gt())
}

pub fn ball_lte(left: BallValue, right: BallValue) -> BallValue {
    BallValue::Bool(compare(&left, &right).is_le())
}

pub fn ball_gte(left: BallValue, right: BallValue) -> BallValue {
    BallValue::Bool(compare(&left, &right).is_ge())
}

pub fn ball_compare_to(left: BallValue, right: BallValue) -> BallValue {
    BallValue::Int(match compare(&left, &right) {
        std::cmp::Ordering::Less => -1,
        std::cmp::Ordering::Equal => 0,
        std::cmp::Ordering::Greater => 1,
    })
}

// ════════════════════════════════════════════════════════════
// Logic / bitwise
// ════════════════════════════════════════════════════════════
//
// `and`/`or` are NOT here — they must short-circuit (invariant #4), which a
// runtime function call can't do (Rust evaluates every call argument before
// the call). `base_call.rs::compile_and`/`compile_or` emit native `&&`/`||`
// directly instead. See that module for the laziness discussion.

pub fn ball_not(value: BallValue) -> BallValue {
    match value {
        BallValue::Bool(a) => BallValue::Bool(!a),
        other => panic!("ball-compiler runtime: unsupported operand for not: {other:?}"),
    }
}

pub fn ball_bitwise_and(left: BallValue, right: BallValue) -> BallValue {
    BallValue::Int(as_i64(&left) & as_i64(&right))
}

pub fn ball_bitwise_or(left: BallValue, right: BallValue) -> BallValue {
    BallValue::Int(as_i64(&left) | as_i64(&right))
}

pub fn ball_bitwise_xor(left: BallValue, right: BallValue) -> BallValue {
    BallValue::Int(as_i64(&left) ^ as_i64(&right))
}

pub fn ball_bitwise_not(value: BallValue) -> BallValue {
    BallValue::Int(!as_i64(&value))
}

/// Dart's `<<`/`>>` on `int` are arithmetic (sign-extending) shifts — same as
/// Rust's native `i64` `<<`/`>>`.
pub fn ball_left_shift(left: BallValue, right: BallValue) -> BallValue {
    BallValue::Int(as_i64(&left).wrapping_shl(as_i64(&right) as u32))
}

pub fn ball_right_shift(left: BallValue, right: BallValue) -> BallValue {
    BallValue::Int(as_i64(&left).wrapping_shr(as_i64(&right) as u32))
}

/// Dart's `>>>` (added in Dart 2.14) is a *logical* (zero-filling) right
/// shift — cast through `u64` to avoid sign extension, matching
/// `ball_dyn.h`'s equivalent (which Dart's own `>>>` spec requires).
pub fn ball_unsigned_right_shift(left: BallValue, right: BallValue) -> BallValue {
    let shift = as_i64(&right) as u32;
    BallValue::Int(((as_i64(&left) as u64).wrapping_shr(shift)) as i64)
}

// ════════════════════════════════════════════════════════════
// Null safety
// ════════════════════════════════════════════════════════════
//
// `null_coalesce` (`??`) is NOT here either — Dart's `??` doesn't evaluate
// its right operand when the left is non-null, so (matching `and`/`or`)
// `base_call.rs::compile_null_coalesce` emits an inline `if` instead of a
// runtime call.

pub fn ball_null_check(value: BallValue) -> BallValue {
    if value == BallValue::Null {
        panic!("ball-compiler runtime: null check operator used on a null value");
    }
    value
}

// ════════════════════════════════════════════════════════════
// to_string / length / parsing
// ════════════════════════════════════════════════════════════

/// `to_string`/`int_to_string`/`double_to_string` all delegate to
/// `BallValue`'s own `Display`, which already matches every reference
/// engine's stdout formatting.
pub fn ball_to_string(value: BallValue) -> BallValue {
    // A `StringBuffer`'s `.toString()` returns its accumulated text, not the
    // backing message's `{content: …}` rendering (see `dartsdk::write`).
    if let BallValue::Message(msg) = &value {
        if msg.type_name == "main:StringBuffer" {
            return BallValue::String(dartsdk::string_buffer_text(&value));
        }
    }
    BallValue::String(value.to_string())
}

/// `length` — polymorphic over `String`/`List`/`Map`/`Bytes`.
///
/// **Known limitation:** Dart's `String.length` counts UTF-16 code units;
/// this counts Unicode scalar values (`str::chars().count()`) instead, so
/// the two diverge for astral-plane characters (surrogate pairs). Every
/// ASCII/BMP string — the entire #37 test corpus — is unaffected.
pub fn ball_length(value: BallValue) -> BallValue {
    BallValue::Int(match &value {
        BallValue::String(s) => s.chars().count() as i64,
        BallValue::List(list) => list.len() as i64,
        BallValue::Map(map) => map.len() as i64,
        BallValue::Bytes(bytes) => bytes.len() as i64,
        other => panic!("ball-compiler runtime: no length for {other:?}"),
    })
}

pub fn ball_string_to_int(value: BallValue) -> BallValue {
    BallValue::Int(as_str(&value).parse().unwrap_or_else(|_| {
        panic!(
            "ball-compiler runtime: cannot parse '{}' as int",
            as_str(&value)
        )
    }))
}

pub fn ball_string_to_double(value: BallValue) -> BallValue {
    BallValue::Double(as_str(&value).parse().unwrap_or_else(|_| {
        panic!(
            "ball-compiler runtime: cannot parse '{}' as double",
            as_str(&value)
        )
    }))
}

// ════════════════════════════════════════════════════════════
// field_access / index / iteration — read paths
// ════════════════════════════════════════════════════════════

/// **Virtual properties** — issue #38's enum emission needs `<Enum>.values`
/// (a `List`) and `.length` on it (`Color.values.length`), which is a
/// `field_access` on a `List`, not a `std_collections.list_length` *call*.
/// Only `"length"` is implemented (the one virtual property #38's required
/// fixtures exercise); `Map`/`Message` are deliberately excluded from this
/// fast path so a real map/message key literally named `"length"` is never
/// shadowed — it still resolves through the ordinary field-map lookup below.
/// A fuller virtual-property surface (`.isEmpty`, `.first`, ...) is future
/// work, same shape as every other documented scope boundary in this module.
pub fn ball_field_get(value: BallValue, field: &str) -> BallValue {
    if field == "length" {
        match &value {
            BallValue::List(list) => return BallValue::Int(list.len() as i64),
            BallValue::String(s) => return BallValue::Int(s.chars().count() as i64),
            BallValue::Bytes(b) => return BallValue::Int(b.len() as i64),
            _ => {}
        }
    }
    match value {
        BallValue::Map(map) => map.get(field).cloned().unwrap_or(BallValue::Null),
        BallValue::Message(message) => message
            .fields
            .get(field)
            .cloned()
            .unwrap_or(BallValue::Null),
        other => panic!("ball-compiler runtime: field access on a non-message value: {other:?}"),
    }
}

/// Read a call argument out of a function/method's single `input` message
/// (invariant #1), preferring the parameter's declared **name** and falling
/// back to its **positional slot** (`arg0`/`arg1`/…). The reference encoders
/// name a *positional* argument `arg{i}` (`dart/encoder/lib/encoder.dart`'s
/// `_encodeArgList`), so that is the common path; but a hand-authored program
/// (or a future encoder) may instead pass it under the parameter's own name,
/// and the self-hosted engine's own `_evalLambda` positional binding resolves
/// exactly this either-or (`input[paramName] ?? input['arg'+i]`), so the
/// compiled parameter prologue mirrors it. When neither key is present the
/// argument was omitted (an optional parameter with no supplied value) → Null.
/// A non-message `input` never carries multiple arguments (a lone positional
/// argument is passed *directly*, bound without this helper), so it likewise
/// yields Null rather than panicking.
pub fn ball_arg_get(input: BallValue, named_key: &str, positional_key: &str) -> BallValue {
    match &input {
        BallValue::Map(map) => map
            .get(named_key)
            .or_else(|| map.get(positional_key))
            .cloned()
            .unwrap_or(BallValue::Null),
        BallValue::Message(message) => message
            .fields
            .get(named_key)
            .or_else(|| message.fields.get(positional_key))
            .cloned()
            .unwrap_or(BallValue::Null),
        _ => BallValue::Null,
    }
}

/// The `type_name` tag of a `BallValue::Message` — the receiver's *actual*
/// runtime class, read by the compiler's per-method-name dispatcher (issue
/// #38: `main:Circle.area`/`main:Rectangle.area` share the short name
/// `area`, so a call site that only knows it has *some* `Shape` can't be
/// resolved to one concrete Rust function at compile time the way a real
/// vtable would — `compile_method_dispatchers`, in `rust/compiler/src/lib.rs`,
/// emits one free `area(input)` function per short name that matches on this
/// tag and routes to the right `impl <Type>::area`). A non-`Message`
/// receiver has no `type_name` to dispatch on at all — that's always a
/// malformed program (a method call on a value that was never constructed
/// as a typed instance), so this fails loud rather than guessing.
pub fn ball_message_type_name(value: &BallValue) -> String {
    match value {
        BallValue::Message(message) => message.type_name.clone(),
        other => panic!(
            "ball-compiler runtime: method call on a non-message value (no type to dispatch on): {other:?}"
        ),
    }
}

/// Mutable slot for `field`, auto-vivifying it to `Null` if absent (matches
/// a fresh `assign` establishing a field that didn't exist yet). Used by
/// [`crate::runtime`]'s callers (the compiler's `lvalue` module) to build a
/// `&mut BallValue` for `obj.field = ...`.
pub fn ball_field_get_mut<'a>(value: &'a mut BallValue, field: &str) -> &'a mut BallValue {
    match value {
        BallValue::Map(map) => map.entry(field.to_string()).or_insert(BallValue::Null),
        BallValue::Message(message) => message
            .fields
            .entry(field.to_string())
            .or_insert(BallValue::Null),
        other => panic!("ball-compiler runtime: field access on a non-message value: {other:?}"),
    }
}

pub fn ball_index_get(target: BallValue, index: BallValue) -> BallValue {
    match target {
        BallValue::List(list) => list[as_index(&index)].clone(),
        BallValue::Map(map) => map
            .get(&index_key(&index))
            .cloned()
            .unwrap_or(BallValue::Null),
        BallValue::String(s) => {
            let i = as_index(&index);
            BallValue::String(
                s.chars()
                    .nth(i)
                    .unwrap_or_else(|| {
                        panic!("ball-compiler runtime: string index {i} out of range")
                    })
                    .to_string(),
            )
        }
        other => panic!("ball-compiler runtime: index access on unsupported value: {other:?}"),
    }
}

/// Mutable slot for `target[index]`, auto-vivifying a `Map` entry (matches
/// [`ball_field_get_mut`]'s auto-vivification for a fresh key) but requiring
/// an in-bounds index for a `List` (there is no sensible "vivify" for a
/// list — Dart's `list[i] = v` on an out-of-bounds `i` throws too).
pub fn ball_index_get_mut(target: &mut BallValue, index: BallValue) -> &mut BallValue {
    match target {
        BallValue::List(list) => {
            let i = as_index(&index);
            &mut list[i]
        }
        BallValue::Map(map) => map.entry(index_key(&index)).or_insert(BallValue::Null),
        other => panic!("ball-compiler runtime: index access on unsupported value: {other:?}"),
    }
}

fn index_key(index: &BallValue) -> String {
    match index {
        BallValue::String(s) => s.clone(),
        other => other.to_string(),
    }
}

/// `for_in` — iterate a `List` element-by-element (the common case) or a
/// `Map`'s entries (each entry surfaced as a 2-element `[key, value]` list,
/// matching how the reference engines expose `Map.entries`).
pub fn ball_iterate(value: BallValue) -> BallList {
    match value {
        BallValue::List(list) => list,
        BallValue::Map(map) => map
            .into_iter()
            .map(|(k, v)| BallValue::List(vec![BallValue::String(k), v]))
            .collect(),
        other => panic!("ball-compiler runtime: '{other:?}' is not iterable"),
    }
}

// ════════════════════════════════════════════════════════════
// Type operations (`is` / `is_not` / `as`)
// ════════════════════════════════════════════════════════════
//
// Only Ball's primitive/collection type names and message `type_name` tags
// are recognized. Real class-hierarchy-aware `is`/`as` (subtype checks
// against a `TypeDefinition`'s `superclass`/`interfaces`) needs the type
// emission #38 adds — until then, an unrecognized (user) type name matches
// only an exact `Message.type_name` tag.
pub fn ball_is_type(value: &BallValue, type_name: &str) -> bool {
    match type_name {
        "int" => matches!(value, BallValue::Int(_)),
        "double" => matches!(value, BallValue::Double(_)),
        "num" => matches!(value, BallValue::Int(_) | BallValue::Double(_)),
        "String" | "string" => matches!(value, BallValue::String(_)),
        "bool" => matches!(value, BallValue::Bool(_)),
        "List" | "list" => matches!(value, BallValue::List(_)),
        "Map" | "map" => matches!(value, BallValue::Map(_)),
        "Null" | "null" => matches!(value, BallValue::Null),
        "Object" | "dynamic" | "var" => true,
        other => matches!(value, BallValue::Message(message) if message.type_name == other),
    }
}

pub fn ball_is(value: BallValue, type_name: &str) -> BallValue {
    BallValue::Bool(ball_is_type(&value, type_name))
}

pub fn ball_is_not(value: BallValue, type_name: &str) -> BallValue {
    BallValue::Bool(!ball_is_type(&value, type_name))
}

/// Dart's `as` is a strict cast (not a numeric coercion): it throws unless
/// the value already has the target type (or the target is `num` and the
/// value is `int`/`double`, or the target is `Object`/`dynamic`).
pub fn ball_as(value: BallValue, type_name: &str) -> BallValue {
    if ball_is_type(&value, type_name) {
        return value;
    }
    panic!(
        "ball-compiler runtime: type '{}' is not a subtype of type '{type_name}' in type cast",
        ball_type_name(&value)
    );
}

// ════════════════════════════════════════════════════════════
// Strings (pure manipulation)
// ════════════════════════════════════════════════════════════

pub fn ball_string_is_empty(value: BallValue) -> BallValue {
    BallValue::Bool(as_str(&value).is_empty())
}

pub fn ball_string_contains(left: BallValue, right: BallValue) -> BallValue {
    BallValue::Bool(as_str(&left).contains(as_str(&right)))
}

pub fn ball_string_starts_with(left: BallValue, right: BallValue) -> BallValue {
    BallValue::Bool(as_str(&left).starts_with(as_str(&right)))
}

pub fn ball_string_ends_with(left: BallValue, right: BallValue) -> BallValue {
    BallValue::Bool(as_str(&left).ends_with(as_str(&right)))
}

/// Character-index (not byte-index) search, so multi-byte UTF-8 doesn't skew
/// the result — matches Dart's UTF-16-code-unit indexing for the common
/// (BMP) case. Returns `-1` when not found (Dart's `String.indexOf`).
pub fn ball_string_index_of(left: BallValue, right: BallValue) -> BallValue {
    let haystack = as_str(&left);
    let needle = as_str(&right);
    BallValue::Int(match haystack.find(needle) {
        Some(byte_index) => haystack[..byte_index].chars().count() as i64,
        None => -1,
    })
}

pub fn ball_string_last_index_of(left: BallValue, right: BallValue) -> BallValue {
    let haystack = as_str(&left);
    let needle = as_str(&right);
    BallValue::Int(match haystack.rfind(needle) {
        Some(byte_index) => haystack[..byte_index].chars().count() as i64,
        None => -1,
    })
}

pub fn ball_string_substring(value: BallValue, start: BallValue, end: BallValue) -> BallValue {
    let chars: Vec<char> = as_str(&value).chars().collect();
    let start_index = as_index(&start).min(chars.len());
    let end_index = if end == BallValue::Null {
        chars.len()
    } else {
        as_index(&end).min(chars.len())
    };
    BallValue::String(
        chars[start_index..end_index.max(start_index)]
            .iter()
            .collect(),
    )
}

pub fn ball_string_char_code_at(target: BallValue, index: BallValue) -> BallValue {
    let chars: Vec<char> = as_str(&target).chars().collect();
    let i = as_index(&index);
    BallValue::Int(
        *chars
            .get(i)
            .unwrap_or_else(|| panic!("ball-compiler runtime: string index {i} out of range"))
            as i64,
    )
}

pub fn ball_string_from_char_code(value: BallValue) -> BallValue {
    let code = as_i64(&value) as u32;
    BallValue::String(
        char::from_u32(code)
            .unwrap_or_else(|| panic!("ball-compiler runtime: invalid char code {code}"))
            .to_string(),
    )
}

pub fn ball_string_to_upper(value: BallValue) -> BallValue {
    BallValue::String(as_str(&value).to_uppercase())
}

pub fn ball_string_to_lower(value: BallValue) -> BallValue {
    BallValue::String(as_str(&value).to_lowercase())
}

pub fn ball_string_trim(value: BallValue) -> BallValue {
    BallValue::String(as_str(&value).trim().to_string())
}

pub fn ball_string_trim_start(value: BallValue) -> BallValue {
    BallValue::String(as_str(&value).trim_start().to_string())
}

pub fn ball_string_trim_end(value: BallValue) -> BallValue {
    BallValue::String(as_str(&value).trim_end().to_string())
}

pub fn ball_string_replace(value: BallValue, from: BallValue, to: BallValue) -> BallValue {
    BallValue::String(as_str(&value).replacen(as_str(&from), as_str(&to), 1))
}

pub fn ball_string_replace_all(value: BallValue, from: BallValue, to: BallValue) -> BallValue {
    BallValue::String(as_str(&value).replace(as_str(&from), as_str(&to)))
}

pub fn ball_string_split(left: BallValue, right: BallValue) -> BallValue {
    let separator = as_str(&right);
    let parts: Vec<BallValue> = if separator.is_empty() {
        as_str(&left)
            .chars()
            .map(|c| BallValue::String(c.to_string()))
            .collect()
    } else {
        as_str(&left)
            .split(separator)
            .map(|s| BallValue::String(s.to_string()))
            .collect()
    };
    BallValue::List(parts)
}

pub fn ball_string_runes(value: BallValue) -> BallValue {
    BallValue::List(
        as_str(&value)
            .chars()
            .map(|c| BallValue::Int(c as i64))
            .collect(),
    )
}

pub fn ball_string_repeat(value: BallValue, count: BallValue) -> BallValue {
    let n = as_i64(&count);
    BallValue::String(if n > 0 {
        as_str(&value).repeat(n as usize)
    } else {
        String::new()
    })
}

pub fn ball_string_pad_left(value: BallValue, width: BallValue, padding: BallValue) -> BallValue {
    let s = as_str(&value);
    let target_width = as_index(&width);
    let pad_char = padding_char(&padding);
    let current_len = s.chars().count();
    if current_len >= target_width {
        return BallValue::String(s.to_string());
    }
    let mut out: String = std::iter::repeat_n(pad_char, target_width - current_len).collect();
    out.push_str(s);
    BallValue::String(out)
}

pub fn ball_string_pad_right(value: BallValue, width: BallValue, padding: BallValue) -> BallValue {
    let s = as_str(&value);
    let target_width = as_index(&width);
    let pad_char = padding_char(&padding);
    let current_len = s.chars().count();
    if current_len >= target_width {
        return BallValue::String(s.to_string());
    }
    let mut out = s.to_string();
    out.extend(std::iter::repeat_n(pad_char, target_width - current_len));
    BallValue::String(out)
}

fn padding_char(padding: &BallValue) -> char {
    match padding {
        BallValue::Null => ' ',
        BallValue::String(s) => s.chars().next().unwrap_or(' '),
        other => panic!("ball-compiler runtime: invalid pad character {other:?}"),
    }
}

// ════════════════════════════════════════════════════════════
// Math
// ════════════════════════════════════════════════════════════

pub fn ball_math_abs(value: BallValue) -> BallValue {
    match value {
        BallValue::Int(v) => BallValue::Int(v.wrapping_abs()),
        BallValue::Double(v) => BallValue::Double(v.abs()),
        other => panic!("ball-compiler runtime: math_abs on non-number {other:?}"),
    }
}

pub fn ball_math_floor(value: BallValue) -> BallValue {
    match value {
        BallValue::Int(v) => BallValue::Int(v),
        other => BallValue::Int(as_f64(&other).floor() as i64),
    }
}

pub fn ball_math_ceil(value: BallValue) -> BallValue {
    match value {
        BallValue::Int(v) => BallValue::Int(v),
        other => BallValue::Int(as_f64(&other).ceil() as i64),
    }
}

/// Dart's `num.round()` rounds ties away from zero — Rust's `f64::round()`
/// does too, so this maps directly.
pub fn ball_math_round(value: BallValue) -> BallValue {
    match value {
        BallValue::Int(v) => BallValue::Int(v),
        other => BallValue::Int(as_f64(&other).round() as i64),
    }
}

pub fn ball_math_trunc(value: BallValue) -> BallValue {
    match value {
        BallValue::Int(v) => BallValue::Int(v),
        other => BallValue::Int(as_f64(&other).trunc() as i64),
    }
}

pub fn ball_math_sqrt(value: BallValue) -> BallValue {
    BallValue::Double(as_f64(&value).sqrt())
}

pub fn ball_math_pow(left: BallValue, right: BallValue) -> BallValue {
    BallValue::Double(as_f64(&left).powf(as_f64(&right)))
}

pub fn ball_math_log(value: BallValue) -> BallValue {
    BallValue::Double(as_f64(&value).ln())
}

pub fn ball_math_log2(value: BallValue) -> BallValue {
    BallValue::Double(as_f64(&value).log2())
}

pub fn ball_math_log10(value: BallValue) -> BallValue {
    BallValue::Double(as_f64(&value).log10())
}

pub fn ball_math_exp(value: BallValue) -> BallValue {
    BallValue::Double(as_f64(&value).exp())
}

pub fn ball_math_sin(value: BallValue) -> BallValue {
    BallValue::Double(as_f64(&value).sin())
}

pub fn ball_math_cos(value: BallValue) -> BallValue {
    BallValue::Double(as_f64(&value).cos())
}

pub fn ball_math_tan(value: BallValue) -> BallValue {
    BallValue::Double(as_f64(&value).tan())
}

pub fn ball_math_asin(value: BallValue) -> BallValue {
    BallValue::Double(as_f64(&value).asin())
}

pub fn ball_math_acos(value: BallValue) -> BallValue {
    BallValue::Double(as_f64(&value).acos())
}

pub fn ball_math_atan(value: BallValue) -> BallValue {
    BallValue::Double(as_f64(&value).atan())
}

pub fn ball_math_atan2(left: BallValue, right: BallValue) -> BallValue {
    BallValue::Double(as_f64(&left).atan2(as_f64(&right)))
}

pub fn ball_math_min(left: BallValue, right: BallValue) -> BallValue {
    if compare(&left, &right).is_le() {
        left
    } else {
        right
    }
}

pub fn ball_math_max(left: BallValue, right: BallValue) -> BallValue {
    if compare(&left, &right).is_ge() {
        left
    } else {
        right
    }
}

pub fn ball_math_clamp(value: BallValue, min: BallValue, max: BallValue) -> BallValue {
    if compare(&value, &min).is_lt() {
        min
    } else if compare(&value, &max).is_gt() {
        max
    } else {
        value
    }
}

pub fn ball_math_is_nan(value: BallValue) -> BallValue {
    BallValue::Bool(as_f64(&value).is_nan())
}

pub fn ball_math_is_finite(value: BallValue) -> BallValue {
    BallValue::Bool(as_f64(&value).is_finite())
}

pub fn ball_math_is_infinite(value: BallValue) -> BallValue {
    BallValue::Bool(as_f64(&value).is_infinite())
}

pub fn ball_math_sign(value: BallValue) -> BallValue {
    match value {
        BallValue::Int(v) => BallValue::Int(v.signum()),
        other => BallValue::Double(
            as_f64(&other).signum() * if as_f64(&other) == 0.0 { 0.0 } else { 1.0 },
        ),
    }
}

fn gcd(a: i64, b: i64) -> i64 {
    let (mut a, mut b) = (a.abs(), b.abs());
    while b != 0 {
        (a, b) = (b, a % b);
    }
    a
}

pub fn ball_math_gcd(left: BallValue, right: BallValue) -> BallValue {
    BallValue::Int(gcd(as_i64(&left), as_i64(&right)))
}

pub fn ball_math_lcm(left: BallValue, right: BallValue) -> BallValue {
    let (a, b) = (as_i64(&left), as_i64(&right));
    let g = gcd(a, b);
    BallValue::Int(if g == 0 { 0 } else { (a / g * b).abs() })
}

// ════════════════════════════════════════════════════════════
// std_collections — non-mutating (safe to compile from a `.clone()` read)
// ════════════════════════════════════════════════════════════

fn as_list(value: BallValue) -> BallList {
    match value {
        BallValue::List(list) => list,
        other => panic!("ball-compiler runtime: expected a list, got {other:?}"),
    }
}

pub fn ball_list_get(list: BallValue, index: BallValue) -> BallValue {
    as_list(list)[as_index(&index)].clone()
}

pub fn ball_list_length(list: BallValue) -> BallValue {
    BallValue::Int(as_list(list).len() as i64)
}

pub fn ball_list_is_empty(list: BallValue) -> BallValue {
    BallValue::Bool(as_list(list).is_empty())
}

pub fn ball_list_first(list: BallValue) -> BallValue {
    as_list(list)
        .into_iter()
        .next()
        .unwrap_or_else(|| panic!("ball-compiler runtime: .first on an empty list"))
}

pub fn ball_list_last(list: BallValue) -> BallValue {
    as_list(list)
        .into_iter()
        .next_back()
        .unwrap_or_else(|| panic!("ball-compiler runtime: .last on an empty list"))
}

pub fn ball_list_single(list: BallValue) -> BallValue {
    let list = as_list(list);
    if list.len() != 1 {
        panic!(
            "ball-compiler runtime: .single on a list with {} elements",
            list.len()
        );
    }
    list.into_iter().next().expect("length checked above")
}

pub fn ball_list_contains(list: BallValue, value: BallValue) -> BallValue {
    BallValue::Bool(as_list(list).contains(&value))
}

pub fn ball_list_index_of(list: BallValue, value: BallValue) -> BallValue {
    BallValue::Int(
        as_list(list)
            .iter()
            .position(|item| *item == value)
            .map(|i| i as i64)
            .unwrap_or(-1),
    )
}

/// Apply a Ball function *value* to each element. Since #39's function-value
/// model (see [`ball_call_function`]), a compiled `lambda` is a
/// `BallValue::Function`, not a native Rust closure — so every
/// callback-taking collection helper takes the callback as a `BallValue` and
/// dispatches through [`ball_call_function`], exactly as the reference
/// engines pass a `BallValue`-typed callback around.
pub fn ball_list_map(list: BallValue, callback: BallValue) -> BallValue {
    BallValue::List(
        as_list(list)
            .into_iter()
            .map(|item| ball_call_function(callback.clone(), item))
            .collect(),
    )
}

pub fn ball_list_filter(list: BallValue, callback: BallValue) -> BallValue {
    BallValue::List(
        as_list(list)
            .into_iter()
            .filter(|item| ball_truthy(ball_call_function(callback.clone(), item.clone())))
            .collect(),
    )
}

pub fn ball_list_find(list: BallValue, callback: BallValue) -> BallValue {
    as_list(list)
        .into_iter()
        .find(|item| ball_truthy(ball_call_function(callback.clone(), item.clone())))
        .unwrap_or_else(|| panic!("ball-compiler runtime: list_find found no matching element"))
}

pub fn ball_list_any(list: BallValue, callback: BallValue) -> BallValue {
    BallValue::Bool(
        as_list(list)
            .into_iter()
            .any(|item| ball_truthy(ball_call_function(callback.clone(), item))),
    )
}

pub fn ball_list_all(list: BallValue, callback: BallValue) -> BallValue {
    BallValue::Bool(
        as_list(list)
            .into_iter()
            .all(|item| ball_truthy(ball_call_function(callback.clone(), item))),
    )
}

pub fn ball_list_none(list: BallValue, callback: BallValue) -> BallValue {
    BallValue::Bool(
        !as_list(list)
            .into_iter()
            .any(|item| ball_truthy(ball_call_function(callback.clone(), item))),
    )
}

pub fn ball_list_reverse(list: BallValue) -> BallValue {
    let mut items = as_list(list);
    items.reverse();
    BallValue::List(items)
}

pub fn ball_list_slice(list: BallValue, start: BallValue, end: BallValue) -> BallValue {
    let items = as_list(list);
    let start_index = as_index(&start).min(items.len());
    let end_index = if end == BallValue::Null {
        items.len()
    } else {
        as_index(&end).min(items.len())
    };
    BallValue::List(items[start_index..end_index.max(start_index)].to_vec())
}

pub fn ball_list_flat_map(list: BallValue, callback: BallValue) -> BallValue {
    let mut out = Vec::new();
    for item in as_list(list) {
        out.extend(as_list(ball_call_function(callback.clone(), item)));
    }
    BallValue::List(out)
}

pub fn ball_list_take(list: BallValue, count: BallValue) -> BallValue {
    BallValue::List(as_list(list).into_iter().take(as_index(&count)).collect())
}

pub fn ball_list_drop(list: BallValue, count: BallValue) -> BallValue {
    BallValue::List(as_list(list).into_iter().skip(as_index(&count)).collect())
}

pub fn ball_list_concat(left: BallValue, right: BallValue) -> BallValue {
    let mut items = as_list(left);
    items.extend(as_list(right));
    BallValue::List(items)
}

// ── mutating (take a `&mut BallValue` slot — see rust/compiler/src/lvalue.rs) ──

pub fn ball_list_push(list: &mut BallValue, value: BallValue) -> BallValue {
    match list {
        BallValue::List(items) => {
            items.push(value);
            list.clone()
        }
        other => panic!("ball-compiler runtime: list_push on a non-list value: {other:?}"),
    }
}

pub fn ball_list_pop(list: &mut BallValue) -> BallValue {
    match list {
        BallValue::List(items) => items
            .pop()
            .unwrap_or_else(|| panic!("ball-compiler runtime: .removeLast() on an empty list")),
        other => panic!("ball-compiler runtime: list_pop on a non-list value: {other:?}"),
    }
}

pub fn ball_list_insert(list: &mut BallValue, index: BallValue, value: BallValue) -> BallValue {
    match list {
        BallValue::List(items) => {
            items.insert(as_index(&index), value);
            list.clone()
        }
        other => panic!("ball-compiler runtime: list_insert on a non-list value: {other:?}"),
    }
}

pub fn ball_list_remove_at(list: &mut BallValue, index: BallValue) -> BallValue {
    match list {
        BallValue::List(items) => items.remove(as_index(&index)),
        other => panic!("ball-compiler runtime: list_remove_at on a non-list value: {other:?}"),
    }
}

// ════════════════════════════════════════════════════════════
// std_collections — maps
// ════════════════════════════════════════════════════════════

fn as_map(value: BallValue) -> BallMap {
    match value {
        BallValue::Map(map) => map,
        other => panic!("ball-compiler runtime: expected a map, got {other:?}"),
    }
}

pub fn ball_map_get(map: BallValue, key: BallValue) -> BallValue {
    as_map(map)
        .get(&index_key(&key))
        .cloned()
        .unwrap_or(BallValue::Null)
}

pub fn ball_map_contains_key(map: BallValue, key: BallValue) -> BallValue {
    BallValue::Bool(as_map(map).contains_key(&index_key(&key)))
}

pub fn ball_map_keys(map: BallValue) -> BallValue {
    BallValue::List(as_map(map).into_keys().map(BallValue::String).collect())
}

pub fn ball_map_values(map: BallValue) -> BallValue {
    BallValue::List(as_map(map).into_values().collect())
}

pub fn ball_map_entries(map: BallValue) -> BallValue {
    BallValue::List(
        as_map(map)
            .into_iter()
            .map(|(k, v)| BallValue::List(vec![BallValue::String(k), v]))
            .collect(),
    )
}

pub fn ball_map_from_entries(entries: BallValue) -> BallValue {
    let mut map = BallMap::new();
    for entry in as_list(entries) {
        let pair = as_list(entry);
        if pair.len() != 2 {
            panic!("ball-compiler runtime: map_from_entries expects [key, value] pairs");
        }
        map.insert(index_key(&pair[0]), pair[1].clone());
    }
    BallValue::Map(map)
}

pub fn ball_map_merge(left: BallValue, right: BallValue) -> BallValue {
    let mut merged = as_map(left);
    for (key, value) in as_map(right) {
        merged.insert(key, value);
    }
    BallValue::Map(merged)
}

pub fn ball_map_is_empty(map: BallValue) -> BallValue {
    BallValue::Bool(as_map(map).is_empty())
}

pub fn ball_map_length(map: BallValue) -> BallValue {
    BallValue::Int(as_map(map).len() as i64)
}

pub fn ball_map_set(map: &mut BallValue, key: BallValue, value: BallValue) -> BallValue {
    match map {
        BallValue::Map(entries) => {
            entries.insert(index_key(&key), value.clone());
            value
        }
        other => panic!("ball-compiler runtime: map_set on a non-map value: {other:?}"),
    }
}

pub fn ball_map_delete(map: &mut BallValue, key: BallValue) -> BallValue {
    match map {
        BallValue::Map(entries) => entries
            .shift_remove(&index_key(&key))
            .unwrap_or(BallValue::Null),
        other => panic!("ball-compiler runtime: map_delete on a non-map value: {other:?}"),
    }
}

pub fn ball_string_join(list: BallValue, separator: BallValue) -> BallValue {
    let separator_str = match separator {
        BallValue::Null => String::new(),
        other => as_str(&other).to_string(),
    };
    BallValue::String(
        as_list(list)
            .iter()
            .map(|item| item.to_string())
            .collect::<Vec<_>>()
            .join(&separator_str),
    )
}

// ════════════════════════════════════════════════════════════
// std_collections — sets
// ════════════════════════════════════════════════════════════
//
// `BallValue` has no dedicated `Set` variant (the value model — issue #35 —
// only defines `Null`/`Bool`/`Int`/`Double`/`String`/`Bytes`/`List`/`Map`/
// `Function`/`Message`). A `Set` is represented as a `List` with
// insertion-order-preserving, duplicate-free membership — the same
// simplification the value model already makes for every other "no
// dedicated variant" case. Adding a real `Set` variant is a `ball_shared`
// schema decision out of this issue's scope.

pub fn ball_set_create(list: BallValue) -> BallValue {
    let mut out: BallList = Vec::new();
    for item in as_list(list) {
        if !out.contains(&item) {
            out.push(item);
        }
    }
    BallValue::List(out)
}

pub fn ball_set_add(set: &mut BallValue, value: BallValue) -> BallValue {
    match set {
        BallValue::List(items) => {
            if !items.contains(&value) {
                items.push(value);
            }
            set.clone()
        }
        other => panic!("ball-compiler runtime: set_add on a non-set value: {other:?}"),
    }
}

pub fn ball_set_remove(set: &mut BallValue, value: BallValue) -> BallValue {
    match set {
        BallValue::List(items) => {
            let before = items.len();
            items.retain(|item| *item != value);
            BallValue::Bool(items.len() != before)
        }
        other => panic!("ball-compiler runtime: set_remove on a non-set value: {other:?}"),
    }
}

pub fn ball_set_contains(set: BallValue, value: BallValue) -> BallValue {
    BallValue::Bool(as_list(set).contains(&value))
}

pub fn ball_set_union(left: BallValue, right: BallValue) -> BallValue {
    let mut out = as_list(left);
    for item in as_list(right) {
        if !out.contains(&item) {
            out.push(item);
        }
    }
    BallValue::List(out)
}

pub fn ball_set_intersection(left: BallValue, right: BallValue) -> BallValue {
    let right_items = as_list(right);
    BallValue::List(
        as_list(left)
            .into_iter()
            .filter(|item| right_items.contains(item))
            .collect(),
    )
}

pub fn ball_set_difference(left: BallValue, right: BallValue) -> BallValue {
    let right_items = as_list(right);
    BallValue::List(
        as_list(left)
            .into_iter()
            .filter(|item| !right_items.contains(item))
            .collect(),
    )
}

pub fn ball_set_length(set: BallValue) -> BallValue {
    BallValue::Int(as_list(set).len() as i64)
}

pub fn ball_set_is_empty(set: BallValue) -> BallValue {
    BallValue::Bool(as_list(set).is_empty())
}

pub fn ball_set_to_list(set: BallValue) -> BallValue {
    BallValue::List(as_list(set))
}

// ════════════════════════════════════════════════════════════
// std_io
// ════════════════════════════════════════════════════════════

pub fn ball_print_error(message: BallValue) -> BallValue {
    eprintln!("{message}");
    BallValue::Null
}

pub fn ball_read_line() -> BallValue {
    let mut line = String::new();
    match std::io::stdin().read_line(&mut line) {
        Ok(0) => BallValue::String(String::new()), // EOF
        Ok(_) => BallValue::String(line.trim_end_matches(['\n', '\r']).to_string()),
        Err(_) => BallValue::String(String::new()),
    }
}

pub fn ball_exit(code: BallValue) -> ! {
    std::process::exit(as_i64(&code) as i32)
}

pub fn ball_panic(message: BallValue) -> ! {
    eprintln!("{message}");
    std::process::exit(1)
}

pub fn ball_sleep_ms(milliseconds: BallValue) -> BallValue {
    std::thread::sleep(std::time::Duration::from_millis(
        as_i64(&milliseconds).max(0) as u64,
    ));
    BallValue::Null
}

pub fn ball_timestamp_ms() -> BallValue {
    BallValue::Int(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0),
    )
}

/// A small, dependency-free xorshift64* PRNG (seeded once from the wall
/// clock). Not cryptographically secure and not seeded/reproducible the way
/// `dart:math`'s `Random` can be — good enough for `random_int`/
/// `random_double`'s "some non-deterministic number" contract without
/// pulling in the `rand` crate for this issue.
static RNG_STATE: AtomicU64 = AtomicU64::new(0);

fn next_random_u64() -> u64 {
    let mut seed = RNG_STATE.load(Ordering::Relaxed);
    if seed == 0 {
        seed = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(0x9E3779B97F4A7C15)
            | 1;
    }
    seed ^= seed << 13;
    seed ^= seed >> 7;
    seed ^= seed << 17;
    RNG_STATE.store(seed, Ordering::Relaxed);
    seed
}

pub fn ball_random_int(min: BallValue, max: BallValue) -> BallValue {
    let lo = as_i64(&min);
    let hi = as_i64(&max);
    if hi <= lo {
        return BallValue::Int(lo);
    }
    let span = (hi - lo) as u64;
    BallValue::Int(lo + (next_random_u64() % span) as i64)
}

pub fn ball_random_double() -> BallValue {
    BallValue::Double((next_random_u64() >> 11) as f64 / (1u64 << 53) as f64)
}

pub fn ball_env_get(name: BallValue) -> BallValue {
    BallValue::String(std::env::var(as_str(&name)).unwrap_or_default())
}

pub fn ball_args_get() -> BallValue {
    BallValue::List(std::env::args().skip(1).map(BallValue::String).collect())
}

// ════════════════════════════════════════════════════════════
// Exceptions (`throw`) — `try`'s own codegen (in `base_call.rs`) wraps a
// `std::panic::catch_unwind` around the compiled body and downcasts the
// payload back to a `BallValue` via `ball_catch_payload`.
// ════════════════════════════════════════════════════════════

pub fn ball_throw(value: BallValue) -> ! {
    std::panic::panic_any(value)
}

/// Recover a thrown [`BallValue`] from a caught [`std::panic::catch_unwind`]
/// payload. A payload that isn't a [`BallValue`] means the panic came from
/// somewhere else in the runtime (an `unwrap()`/bounds-check/... failure,
/// not a Ball `throw`) — re-wrap its message as a Ball string so `catch`
/// still sees *something* rather than silently losing the failure.
pub fn ball_catch_payload(payload: Box<dyn std::any::Any + Send>) -> BallValue {
    match payload.downcast::<BallValue>() {
        Ok(value) => *value,
        Err(payload) => {
            let message = if let Some(s) = payload.downcast_ref::<&str>() {
                s.to_string()
            } else if let Some(s) = payload.downcast_ref::<String>() {
                s.clone()
            } else {
                "ball-compiler runtime: non-Ball panic caught by try/catch".to_string()
            };
            BallValue::String(message)
        }
    }
}

/// `a ?? b` / `a ??= b` — the null-coalescing operator. Yields `left` unless
/// it is `null`, otherwise `right` (Dart's `??`: a non-null left short-circuits
/// and `right` is never observed for its value). Emitted by the compiler's
/// `lvalue` module for `??=` (`compiler/src/lvalue.rs`) and by
/// `compile_null_coalesce`; both previously referenced this helper without a
/// definition (issue #39 — a `cannot find function ball_null_coalesce`).
pub fn ball_null_coalesce(left: BallValue, right: BallValue) -> BallValue {
    if left == BallValue::Null { right } else { left }
}

pub use dartsdk::*;

/// Dart-SDK method + type helpers (issue #39 — self-host gap #2).
///
/// The self-hosted engine (`dart/self_host/engine.ball.json`) is authored
/// against the full Dart SDK: it calls `String`/`List`/`Map`/`Set`/`num`/
/// `int`/`double`/`RegExp`/`DateTime`/`File` methods and static constructors
/// which the Ball compiler lowers verbatim as free-function calls
/// `<method>({self: <receiver>, arg0: <a0>, arg1: <a1>, …})` — a method's
/// receiver rides in the packed `input` message under `self`, positional
/// arguments are `arg0`/`arg1`/…, named arguments under their own name (the
/// universal invariant-#1 calling convention; see [`ball_arg_get`]). A
/// *static* receiver (`int.tryParse`, `List.filled`, `DateTime.now`) lowers
/// its type name to a bare value reference, so each SDK type also needs an
/// in-scope marker value.
///
/// Semantics match Dart's exactly (`dart/engine/lib/engine_std.dart` /
/// `dart/shared/lib/std*.dart`, the conformance oracle). Where the Rust value
/// model can't express a Dart construct faithfully the divergence is noted
/// inline: a `Set` shares the `List` representation (issue #35), so a method
/// that would dedup on a genuine `Set` is documented; object *identity* can't
/// exist in a by-value model, so `identical` falls back to structural
/// equality. Receiver mutation does not propagate back to the caller's binding
/// (the receiver arrives cloned under `self`) — that is the separate
/// borrow-checker/dynamic-value gap (#39 gap #6); these helpers still compute
/// and return the correct *result* value.
mod dartsdk {
    #![allow(non_snake_case, non_upper_case_globals)]

    use std::sync::LazyLock;

    use super::*;

    // ── input unpacking ──────────────────────────────────────

    /// Read a keyed field (`self`/`arg0`/`arg1`/a named parameter) out of a
    /// method call's packed `input` message. Absent ⇒ `Null` (an omitted
    /// optional argument), matching [`ball_arg_get`]'s convention.
    fn m_get(input: &BallValue, key: &str) -> BallValue {
        match input {
            BallValue::Map(map) => map.get(key).cloned().unwrap_or(BallValue::Null),
            BallValue::Message(msg) => msg.fields.get(key).cloned().unwrap_or(BallValue::Null),
            _ => BallValue::Null,
        }
    }

    // ── SDK type markers (static receivers) ──────────────────
    //
    // A static call `int.tryParse(s)` lowers `int` to a bare value read, so
    // each type needs an in-scope marker. The marker is the type's own name
    // (a `String`), which the polymorphic helpers below (`tryParse`/`parse`/
    // `unmodifiable`) read to dispatch. `String` lives in the *value*
    // namespace and never collides with the prelude's `String` *type*.

    pub static int: LazyLock<BallValue> = LazyLock::new(|| BallValue::String("int".to_string()));
    pub static double: LazyLock<BallValue> =
        LazyLock::new(|| BallValue::String("double".to_string()));
    pub static num: LazyLock<BallValue> = LazyLock::new(|| BallValue::String("num".to_string()));
    pub static List: LazyLock<BallValue> = LazyLock::new(|| BallValue::String("List".to_string()));
    pub static Map: LazyLock<BallValue> = LazyLock::new(|| BallValue::String("Map".to_string()));
    pub static Set: LazyLock<BallValue> = LazyLock::new(|| BallValue::String("Set".to_string()));
    pub static String: LazyLock<BallValue> =
        LazyLock::new(|| BallValue::String("String".to_string()));
    pub static Function: LazyLock<BallValue> =
        LazyLock::new(|| BallValue::String("Function".to_string()));
    pub static DateTime: LazyLock<BallValue> =
        LazyLock::new(|| BallValue::String("DateTime".to_string()));

    /// `dart:io`'s `FileMode` enum (`FileMode.write`/`.append`/…) — the values
    /// `File.writeAsStringSync(…, mode: FileMode.append)` reads. Mirrors the
    /// oneof-discriminator enum namespaces: a message whose members are the
    /// enum arm's own name string.
    pub static io_FileMode: LazyLock<BallValue> = LazyLock::new(|| {
        let mut fields = BallMap::new();
        for name in ["read", "write", "append", "writeOnly", "writeOnlyAppend"] {
            fields.insert(name.to_string(), BallValue::String(name.to_string()));
        }
        BallValue::Message(BallMessage {
            type_name: "io_FileMode".to_string(),
            fields,
        })
    });

    // ── num / int / double parsing ───────────────────────────
    //
    // Dart's `int.parse`/`num.parse`/`double.parse` allow surrounding
    // whitespace and an optional leading sign; the `try*` forms return `null`
    // instead of throwing. `num.tryParse` returns an `int` when the source is
    // an integer literal and a `double` otherwise.

    fn parse_int_dart(s: &str) -> Option<i64> {
        s.trim().parse::<i64>().ok()
    }

    fn parse_double_dart(s: &str) -> Option<f64> {
        let t = s.trim();
        match t {
            "Infinity" | "+Infinity" => Some(f64::INFINITY),
            "-Infinity" => Some(f64::NEG_INFINITY),
            "NaN" => Some(f64::NAN),
            // Rust's own `f64` parser also accepts "inf"/"nan", which Dart does
            // *not*; the engine only ever feeds numeric literals, so the extra
            // spellings are unreachable and harmless.
            _ => t.parse::<f64>().ok(),
        }
    }

    fn parse_num_dart(s: &str) -> Option<BallValue> {
        let t = s.trim();
        if let Ok(i) = t.parse::<i64>() {
            return Some(BallValue::Int(i));
        }
        parse_double_dart(t).map(BallValue::Double)
    }

    fn marker_str(v: &BallValue) -> &str {
        match v {
            BallValue::String(m) => m.as_str(),
            _ => "num",
        }
    }

    /// `int.tryParse(s)` / `double.tryParse(s)` / `num.tryParse(s)` — `self` is
    /// the numeric type marker, `arg0` the source string. Returns `Null` on a
    /// non-string source or a parse failure.
    pub fn tryParse(input: BallValue) -> BallValue {
        let ty = m_get(&input, "self");
        let source = m_get(&input, "arg0");
        let BallValue::String(s) = &source else {
            return BallValue::Null;
        };
        match marker_str(&ty) {
            "int" => parse_int_dart(s)
                .map(BallValue::Int)
                .unwrap_or(BallValue::Null),
            "double" => parse_double_dart(s)
                .map(BallValue::Double)
                .unwrap_or(BallValue::Null),
            _ => parse_num_dart(s).unwrap_or(BallValue::Null),
        }
    }

    /// `int.parse(s)` / `num.parse(s)` / `double.parse(s)` — the throwing form
    /// (Dart raises `FormatException` on a bad source; this fails loud).
    pub fn parse(input: BallValue) -> BallValue {
        let result = tryParse(input.clone());
        if result == BallValue::Null {
            let source = m_get(&input, "arg0");
            panic!("ball-compiler runtime: FormatException: cannot parse '{source}' as a number");
        }
        result
    }

    /// `num.remainder(other)` — the *truncated* remainder (sign of the
    /// dividend), distinct from `%` (which is Euclidean in Ball). Integer
    /// operands yield an `int`; any `double` operand yields a `double`.
    pub fn remainder(input: BallValue) -> BallValue {
        let a = m_get(&input, "self");
        let b = m_get(&input, "arg0");
        match (&a, &b) {
            (BallValue::Int(x), BallValue::Int(y)) => {
                if *y == 0 {
                    panic!("ball-compiler runtime: integer remainder by zero");
                }
                BallValue::Int(x.wrapping_rem(*y))
            }
            _ => BallValue::Double(as_f64(&a) % as_f64(&b)),
        }
    }

    /// `String.fromCharCode(code)` — a one-character string from a UTF-16/rune
    /// code point (`self` is the `String` type marker, `arg0` the code).
    pub fn fromCharCode(input: BallValue) -> BallValue {
        ball_string_from_char_code(m_get(&input, "arg0"))
    }

    // ── RegExp ───────────────────────────────────────────────
    //
    // The engine constructs a `RegExp(pattern)` as an anonymous message
    // `{arg0: <pattern>}`; a match is materialized as
    // `{__ball_regexp_match__ groups: [<full>, <g1>, …]}` so `group(i)` is a
    // list read. Dart's `RegExp` throws a `FormatException` on an invalid
    // pattern — here compilation fails loud at first use.

    fn regex_pattern_of(v: &BallValue) -> std::string::String {
        match v {
            BallValue::String(s) => s.clone(),
            BallValue::Map(map) => map
                .get("arg0")
                .or_else(|| map.get("pattern"))
                .or_else(|| map.get("source"))
                .map(|x| x.to_string())
                .unwrap_or_default(),
            BallValue::Message(msg) => msg
                .fields
                .get("arg0")
                .or_else(|| msg.fields.get("pattern"))
                .or_else(|| msg.fields.get("source"))
                .map(|x| x.to_string())
                .unwrap_or_default(),
            other => panic!("ball-compiler runtime: RegExp receiver is not a pattern: {other:?}"),
        }
    }

    fn compile_regex(pattern: &str) -> regex::Regex {
        regex::Regex::new(pattern)
            .unwrap_or_else(|e| panic!("ball-compiler runtime: invalid RegExp /{pattern}/: {e}"))
    }

    fn regex_match_value(caps: &regex::Captures) -> BallValue {
        let mut groups: BallList = Vec::new();
        for i in 0..caps.len() {
            match caps.get(i) {
                Some(m) => groups.push(BallValue::String(m.as_str().to_string())),
                None => groups.push(BallValue::Null),
            }
        }
        let mut fields = BallMap::new();
        fields.insert("groups".to_string(), BallValue::List(groups));
        BallValue::Message(BallMessage {
            type_name: "__ball_regexp_match__".to_string(),
            fields,
        })
    }

    /// `RegExp.firstMatch(subject)` — the first match, or `Null` if none.
    pub fn firstMatch(input: BallValue) -> BallValue {
        let pattern = regex_pattern_of(&m_get(&input, "self"));
        let subject = m_get(&input, "arg0");
        let re = compile_regex(&pattern);
        match re.captures(as_str(&subject)) {
            Some(caps) => regex_match_value(&caps),
            None => BallValue::Null,
        }
    }

    /// `RegExp.allMatches(subject)` — every non-overlapping match, in order.
    pub fn allMatches(input: BallValue) -> BallValue {
        let pattern = regex_pattern_of(&m_get(&input, "self"));
        let subject = m_get(&input, "arg0");
        let re = compile_regex(&pattern);
        BallValue::List(
            re.captures_iter(as_str(&subject))
                .map(|caps| regex_match_value(&caps))
                .collect(),
        )
    }

    /// `RegExpMatch.group(i)` — group 0 is the whole match; a group that did
    /// not participate is `Null` (`self` is the match, `arg0` the index).
    pub fn group(input: BallValue) -> BallValue {
        let match_value = m_get(&input, "self");
        let index = as_index(&m_get(&input, "arg0"));
        match m_get(&match_value, "groups") {
            BallValue::List(groups) => groups.get(index).cloned().unwrap_or(BallValue::Null),
            _ => BallValue::Null,
        }
    }

    // ── List / Map / Set methods ─────────────────────────────
    //
    // Receiver mutation is not observed by the caller (the receiver is cloned
    // into `self` — gap #6); each helper returns the correct *result* value,
    // and returns the mutated collection so a `cascade` (`..addAll(x)`) reads
    // the receiver it expects.

    /// `List.addAll(iterable)` / `Map.addAll(other)`. `Set.addAll` shares the
    /// `List` path and therefore does *not* dedup (the value model has no
    /// distinct `Set` — issue #35).
    pub fn addAll(input: BallValue) -> BallValue {
        let receiver = m_get(&input, "self");
        let other = m_get(&input, "arg0");
        match receiver {
            BallValue::Map(mut map) => {
                match other {
                    BallValue::Map(entries) => {
                        for (k, v) in entries {
                            map.insert(k, v);
                        }
                    }
                    BallValue::Message(msg) => {
                        for (k, v) in msg.fields {
                            map.insert(k, v);
                        }
                    }
                    _ => {}
                }
                BallValue::Map(map)
            }
            BallValue::List(mut list) => {
                list.extend(as_list(other));
                BallValue::List(list)
            }
            other => panic!("ball-compiler runtime: addAll on unsupported receiver: {other:?}"),
        }
    }

    /// `List.remove(value)` / `Set.remove(value)` → `bool` (was it present);
    /// `Map.remove(key)` → the removed value (or `Null`).
    pub fn remove(input: BallValue) -> BallValue {
        let receiver = m_get(&input, "self");
        let target = m_get(&input, "arg0");
        match receiver {
            BallValue::Map(mut map) => map
                .shift_remove(&index_key(&target))
                .unwrap_or(BallValue::Null),
            BallValue::List(mut list) => match list.iter().position(|item| *item == target) {
                Some(pos) => {
                    list.remove(pos);
                    BallValue::Bool(true)
                }
                None => BallValue::Bool(false),
            },
            other => panic!("ball-compiler runtime: remove on unsupported receiver: {other:?}"),
        }
    }

    /// `List.clear()` / `Map.clear()` / `Set.clear()` — the emptied receiver.
    pub fn clear(input: BallValue) -> BallValue {
        match m_get(&input, "self") {
            BallValue::Map(_) => BallValue::Map(BallMap::new()),
            BallValue::List(_) => BallValue::List(BallList::new()),
            other => other,
        }
    }

    /// `List.setAll(index, iterable)` — overwrite elements starting at `index`
    /// (Dart throws if it would run past the end).
    pub fn setAll(input: BallValue) -> BallValue {
        let mut list = as_list(m_get(&input, "self"));
        let start = as_index(&m_get(&input, "arg0"));
        for (offset, item) in as_list(m_get(&input, "arg1")).into_iter().enumerate() {
            let index = start + offset;
            if index >= list.len() {
                panic!("ball-compiler runtime: setAll range past end of list");
            }
            list[index] = item;
        }
        BallValue::List(list)
    }

    /// `Iterable.cast<T>()` — a re-typed view; in the dynamic value model the
    /// receiver is returned unchanged.
    pub fn cast(input: BallValue) -> BallValue {
        m_get(&input, "self")
    }

    /// `Iterable.toSet()` — an insertion-ordered, de-duplicated `Set` (the
    /// `List`-backed set representation, matching `ball_set_create`).
    pub fn toSet(input: BallValue) -> BallValue {
        ball_set_create(m_get(&input, "self"))
    }

    /// `List.unmodifiable(x)` / `Map.unmodifiable(x)` / `Set.unmodifiable(x)` —
    /// a copy of `x` (unmodifiability is not enforced by the value model). A
    /// `Set` copy de-duplicates.
    pub fn unmodifiable(input: BallValue) -> BallValue {
        let collection = m_get(&input, "arg0");
        match m_get(&input, "self") {
            BallValue::String(ref m) if m == "Set" => ball_set_create(collection),
            _ => collection,
        }
    }

    /// `List.filled(count, value)` — a `count`-length list of `value`.
    pub fn filled(input: BallValue) -> BallValue {
        let count = as_index(&m_get(&input, "arg0"));
        let value = m_get(&input, "arg1");
        BallValue::List(vec![value; count])
    }

    /// `Iterable.elementAt(index)` — the element at `index` (Dart throws
    /// `RangeError` when out of bounds).
    pub fn elementAt(input: BallValue) -> BallValue {
        let list = as_list(m_get(&input, "self"));
        let index = as_index(&m_get(&input, "arg0"));
        list.get(index).cloned().unwrap_or_else(|| {
            panic!("ball-compiler runtime: elementAt index {index} out of range")
        })
    }

    /// `Set.union(other)`.
    pub fn union_(input: BallValue) -> BallValue {
        ball_set_union(m_get(&input, "self"), m_get(&input, "arg0"))
    }

    /// `Set.intersection(other)`.
    pub fn intersection(input: BallValue) -> BallValue {
        ball_set_intersection(m_get(&input, "self"), m_get(&input, "arg0"))
    }

    /// `Set.difference(other)`.
    pub fn difference(input: BallValue) -> BallValue {
        ball_set_difference(m_get(&input, "self"), m_get(&input, "arg0"))
    }

    /// Top-level `identical(a, b)`. A by-value model has no object identity,
    /// so this is structural equality (`a == b`) — exact for primitives, and
    /// the closest faithful answer for the engine's own comparisons.
    pub fn identical(input: BallValue) -> BallValue {
        ball_equals(m_get(&input, "arg0"), m_get(&input, "arg1"))
    }

    // ── DateTime ─────────────────────────────────────────────

    /// `DateTime.now()` — surfaced as `{millisecondsSinceEpoch,
    /// microsecondsSinceEpoch}` (the only fields the engine's profiling reads).
    pub fn now(_input: BallValue) -> BallValue {
        let elapsed = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default();
        let mut fields = BallMap::new();
        fields.insert(
            "millisecondsSinceEpoch".to_string(),
            BallValue::Int(elapsed.as_millis() as i64),
        );
        fields.insert(
            "microsecondsSinceEpoch".to_string(),
            BallValue::Int(elapsed.as_micros() as i64),
        );
        BallValue::Map(fields)
    }

    // ── dart:math free functions (`dart_math::*`) ────────────
    //
    // The engine calls these as `dart_math::sqrt(x)` (module-qualified); the
    // compiler's empty-namespace-module re-export makes them resolve here.
    // Unary functions receive the number directly; `atan2` receives an
    // `{arg0, arg1}` message.

    pub fn sqrt(input: BallValue) -> BallValue {
        ball_math_sqrt(input)
    }
    pub fn sin(input: BallValue) -> BallValue {
        ball_math_sin(input)
    }
    pub fn cos(input: BallValue) -> BallValue {
        ball_math_cos(input)
    }
    pub fn tan(input: BallValue) -> BallValue {
        ball_math_tan(input)
    }
    pub fn asin(input: BallValue) -> BallValue {
        ball_math_asin(input)
    }
    pub fn acos(input: BallValue) -> BallValue {
        ball_math_acos(input)
    }
    pub fn atan(input: BallValue) -> BallValue {
        ball_math_atan(input)
    }
    pub fn log(input: BallValue) -> BallValue {
        ball_math_log(input)
    }
    pub fn exp(input: BallValue) -> BallValue {
        ball_math_exp(input)
    }
    pub fn atan2(input: BallValue) -> BallValue {
        ball_math_atan2(m_get(&input, "arg0"), m_get(&input, "arg1"))
    }

    // ── dart:io (`dart_io::File`/`Directory` + sync ops) ─────
    //
    // A `File`/`Directory` is a message tagged with its kind holding the
    // path; the `*Sync` operations are genuine filesystem side effects (Dart's
    // `*Sync` throws on error — these fail loud).

    fn path_arg(v: &BallValue) -> std::string::String {
        match v {
            BallValue::String(s) => s.clone(),
            BallValue::Map(map) => map
                .get("path")
                .or_else(|| map.get("arg0"))
                .map(|x| x.to_string())
                .unwrap_or_default(),
            BallValue::Message(msg) => msg
                .fields
                .get("path")
                .or_else(|| msg.fields.get("arg0"))
                .map(|x| x.to_string())
                .unwrap_or_default(),
            other => other.to_string(),
        }
    }

    fn fs_handle(kind: &str, path: std::string::String) -> BallValue {
        let mut fields = BallMap::new();
        fields.insert("path".to_string(), BallValue::String(path));
        BallValue::Message(BallMessage {
            type_name: kind.to_string(),
            fields,
        })
    }

    /// `File(path)`.
    pub fn File(input: BallValue) -> BallValue {
        fs_handle("__ball_io_file__", path_arg(&input))
    }

    /// `Directory(path)`.
    pub fn Directory(input: BallValue) -> BallValue {
        fs_handle("__ball_io_directory__", path_arg(&input))
    }

    /// `File.existsSync()` / `Directory.existsSync()`.
    pub fn existsSync(input: BallValue) -> BallValue {
        let path = path_arg(&m_get(&input, "self"));
        BallValue::Bool(std::path::Path::new(&path).exists())
    }

    /// `File.readAsStringSync()`.
    pub fn readAsStringSync(input: BallValue) -> BallValue {
        let path = path_arg(&m_get(&input, "self"));
        match std::fs::read_to_string(&path) {
            Ok(contents) => BallValue::String(contents),
            Err(e) => panic!("ball-compiler runtime: readAsStringSync('{path}') failed: {e}"),
        }
    }

    /// `File.writeAsStringSync(contents, {mode})` — `FileMode.append` appends,
    /// every other mode truncates.
    pub fn writeAsStringSync(input: BallValue) -> BallValue {
        use std::io::Write;
        let path = path_arg(&m_get(&input, "self"));
        let contents = m_get(&input, "arg0").to_string();
        let mode = m_get(&input, "mode");
        let append = matches!(&mode, BallValue::String(m) if m == "append");
        let result = if append {
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&path)
                .and_then(|mut file| file.write_all(contents.as_bytes()))
        } else {
            std::fs::write(&path, contents.as_bytes())
        };
        if let Err(e) = result {
            panic!("ball-compiler runtime: writeAsStringSync('{path}') failed: {e}");
        }
        BallValue::Null
    }

    /// `File.writeAsBytesSync(bytes)`.
    pub fn writeAsBytesSync(input: BallValue) -> BallValue {
        let path = path_arg(&m_get(&input, "self"));
        let bytes = match m_get(&input, "arg0") {
            BallValue::Bytes(b) => b,
            BallValue::List(list) => list.iter().map(|v| as_i64(v) as u8).collect(),
            other => {
                panic!("ball-compiler runtime: writeAsBytesSync expected bytes, got {other:?}")
            }
        };
        if let Err(e) = std::fs::write(&path, bytes) {
            panic!("ball-compiler runtime: writeAsBytesSync('{path}') failed: {e}");
        }
        BallValue::Null
    }

    /// `Directory.createSync({recursive})`.
    pub fn createSync(input: BallValue) -> BallValue {
        let path = path_arg(&m_get(&input, "self"));
        let recursive = ball_truthy(m_get(&input, "recursive"));
        let result = if recursive {
            std::fs::create_dir_all(&path)
        } else {
            std::fs::create_dir(&path)
        };
        if let Err(e) = result {
            panic!("ball-compiler runtime: createSync('{path}') failed: {e}");
        }
        BallValue::Null
    }

    /// `File.deleteSync()` / `Directory.deleteSync()`.
    pub fn deleteSync(input: BallValue) -> BallValue {
        let path = path_arg(&m_get(&input, "self"));
        let path_ref = std::path::Path::new(&path);
        let result = if path_ref.is_dir() {
            std::fs::remove_dir_all(path_ref)
        } else {
            std::fs::remove_file(path_ref)
        };
        if let Err(e) = result {
            panic!("ball-compiler runtime: deleteSync('{path}') failed: {e}");
        }
        BallValue::Null
    }

    // ── StringBuffer (`dart:core` StringBuffer) ──────────────
    //
    // The engine builds a `StringBuffer` to render type descriptions
    // (`_describeType`). It is a `main:StringBuffer` message whose accumulated
    // text lives under `content` (an initial `StringBuffer(x)` argument arrives
    // under `arg0`). `write` appends the stringified argument; the compiler
    // lowers the buffer's `.toString()` to [`ball_to_string`], which
    // special-cases this message shape (see that fn) to return the text.
    //
    // **Known limitation (by-value model, #39 gap #6):** the receiver arrives
    // cloned under `self`, so an `sb.write(x);` statement whose result is
    // discarded does not mutate the caller's binding — `write` returns the
    // correctly-appended buffer, but a fresh buffer written to only through
    // discarded statements renders as its initial content. Faithful in-place
    // accumulation needs shared mutability, tracked with the other
    // receiver-mutation divergences.

    /// The text a `StringBuffer` message currently holds: its accumulated
    /// `content`, falling back to the constructor's initial `arg0` value, then
    /// the empty string.
    pub(crate) fn string_buffer_text(buffer: &BallValue) -> std::string::String {
        let field = |name: &str| match buffer {
            BallValue::Message(msg) => msg.fields.get(name).cloned(),
            BallValue::Map(map) => map.get(name).cloned(),
            _ => None,
        };
        match field("content").or_else(|| field("arg0")) {
            Some(BallValue::Null) | None => std::string::String::new(),
            Some(value) => value.to_string(),
        }
    }

    /// `StringBuffer.write(obj)` — append `obj`'s string form to the buffer,
    /// returning the updated `main:StringBuffer` message.
    pub fn write(input: BallValue) -> BallValue {
        let buffer = m_get(&input, "self");
        let mut text = string_buffer_text(&buffer);
        text.push_str(&m_get(&input, "arg0").to_string());
        let mut fields = BallMap::new();
        fields.insert("content".to_string(), BallValue::String(text));
        BallValue::Message(BallMessage {
            type_name: "main:StringBuffer".to_string(),
            fields,
        })
    }

    // ── Function.apply / Iterable.indexWhere (function values) ─
    //
    // Both invoke a first-class function *value* — the engine's own
    // `Function.apply(fn, args)` (used by `std.invoke`) and
    // `list.indexWhere(predicate)` (pattern matching). They route through
    // [`ball_call_function`], keeping invariant #1 (one input, one output):
    // `Function.apply` passes the single element of the positional-args list.

    /// `Function.apply(fn, positionalArguments)` — invoke `fn` with the lone
    /// element of `positionalArguments` (invariant #1: a Ball function takes a
    /// single input), or `null` when the list is empty.
    pub fn apply(input: BallValue) -> BallValue {
        let callee = m_get(&input, "arg0");
        let args = as_list(m_get(&input, "arg1"));
        let arg = args.into_iter().next().unwrap_or(BallValue::Null);
        ball_call_function(callee, arg)
    }

    /// `Iterable.indexWhere(test)` — the index of the first element for which
    /// `test` is truthy, or `-1` if none.
    pub fn indexWhere(input: BallValue) -> BallValue {
        let list = as_list(m_get(&input, "self"));
        let predicate = m_get(&input, "arg0");
        for (index, element) in list.into_iter().enumerate() {
            if ball_truthy(ball_call_function(predicate.clone(), element)) {
                return BallValue::Int(index as i64);
            }
        }
        BallValue::Int(-1)
    }

    // ── proto-message presence + serialization ───────────────
    //
    // The self-hosted engine inspects Ball-AST messages with proto presence
    // checks (`field.hasValue()`, `access.hasObject()`) and measures a
    // program's serialized size (`program.writeToBuffer().length`). Presence
    // mirrors `ball_proto.dart` (proto3: a message/string/collection field is
    // "present" when set and non-empty).

    /// Proto presence of field `name` on `obj` (proto3 semantics: present ⇒
    /// set and non-default/non-empty). Mirrors `ball_proto.dart` /
    /// `ball_engine::ball_proto::has_field`.
    fn proto_has_field(obj: &BallValue, name: &str) -> BallValue {
        let field = match obj {
            BallValue::Map(map) => map.get(name),
            BallValue::Message(msg) => msg.fields.get(name),
            _ => None,
        };
        let present = match field {
            None | Some(BallValue::Null) => false,
            Some(BallValue::String(s)) => !s.is_empty(),
            Some(BallValue::List(l)) => !l.is_empty(),
            Some(BallValue::Map(m)) => !m.is_empty(),
            Some(_) => true,
        };
        BallValue::Bool(present)
    }

    /// `Expression.hasValue()` / `LetBinding.hasValue()` / … — presence of a
    /// `value` field.
    pub fn hasValue(input: BallValue) -> BallValue {
        proto_has_field(&m_get(&input, "self"), "value")
    }

    /// `FieldAccess.hasObject()` — presence of an `object` field.
    pub fn hasObject(input: BallValue) -> BallValue {
        proto_has_field(&m_get(&input, "self"), "object")
    }

    /// `Message.writeToBuffer()` — a byte buffer of the message's serialized
    /// form. The engine reads only its `.length` (a program-size limit check),
    /// so this returns the UTF-8 bytes of the canonical JSON rendering — an
    /// exact byte count for that encoding, sufficient for the size guard.
    pub fn writeToBuffer(input: BallValue) -> BallValue {
        let message = m_get(&input, "self");
        let json = ball_value_to_json_string(&message);
        BallValue::Bytes(json.into_bytes())
    }

    // ── dart:convert JsonEncoder / JsonDecoder ───────────────

    /// `JsonEncoder.convert(value)` / `JsonDecoder.convert(text)` — dispatched
    /// on the receiver's `main:JsonEncoder` / `main:JsonDecoder` type. Encoding
    /// produces Dart-`JsonEncoder`-compatible compact JSON (no whitespace,
    /// map keys in insertion order); decoding parses a JSON string to a
    /// `BallValue`.
    pub fn convert(input: BallValue) -> BallValue {
        let receiver = m_get(&input, "self");
        let arg = m_get(&input, "arg0");
        let type_name = match &receiver {
            BallValue::Message(msg) => msg.type_name.as_str(),
            _ => "",
        };
        if type_name.ends_with("JsonDecoder") {
            let text = as_str(&arg);
            match serde_json::from_str::<serde_json::Value>(text) {
                Ok(value) => json_value_to_ball(&value),
                Err(e) => panic!("ball-compiler runtime: JsonDecoder.convert failed: {e}"),
            }
        } else {
            BallValue::String(ball_value_to_json_string(&arg))
        }
    }

    /// Render `value` as compact JSON (Dart `JsonEncoder().convert` shape),
    /// preserving map insertion order.
    fn ball_value_to_json_string(value: &BallValue) -> std::string::String {
        let mut out = std::string::String::new();
        write_json(value, &mut out);
        out
    }

    fn write_json(value: &BallValue, out: &mut std::string::String) {
        use std::fmt::Write as _;
        match value {
            BallValue::Null => out.push_str("null"),
            BallValue::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
            BallValue::Int(i) => {
                let _ = write!(out, "{i}");
            }
            BallValue::Double(d) => out.push_str(&crate::value::format_double(*d)),
            BallValue::String(s) => write_json_string(s, out),
            BallValue::Bytes(bytes) => {
                out.push('[');
                for (i, b) in bytes.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    let _ = write!(out, "{b}");
                }
                out.push(']');
            }
            BallValue::List(list) => {
                out.push('[');
                for (i, item) in list.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    write_json(item, out);
                }
                out.push(']');
            }
            BallValue::Map(map) => write_json_object(map.iter(), out),
            BallValue::Message(msg) => write_json_object(msg.fields.iter(), out),
            BallValue::Function(_) => out.push_str("null"),
        }
    }

    fn write_json_object<'a>(
        entries: impl Iterator<Item = (&'a std::string::String, &'a BallValue)>,
        out: &mut std::string::String,
    ) {
        out.push('{');
        for (i, (key, value)) in entries.enumerate() {
            if i > 0 {
                out.push(',');
            }
            write_json_string(key, out);
            out.push(':');
            write_json(value, out);
        }
        out.push('}');
    }

    fn write_json_string(s: &str, out: &mut std::string::String) {
        out.push('"');
        for ch in s.chars() {
            match ch {
                '"' => out.push_str("\\\""),
                '\\' => out.push_str("\\\\"),
                '\n' => out.push_str("\\n"),
                '\r' => out.push_str("\\r"),
                '\t' => out.push_str("\\t"),
                c if (c as u32) < 0x20 => {
                    use std::fmt::Write as _;
                    let _ = write!(out, "\\u{:04x}", c as u32);
                }
                c => out.push(c),
            }
        }
        out.push('"');
    }

    fn json_value_to_ball(value: &serde_json::Value) -> BallValue {
        match value {
            serde_json::Value::Null => BallValue::Null,
            serde_json::Value::Bool(b) => BallValue::Bool(*b),
            serde_json::Value::Number(n) => {
                if let Some(i) = n.as_i64() {
                    BallValue::Int(i)
                } else {
                    BallValue::Double(n.as_f64().unwrap_or(0.0))
                }
            }
            serde_json::Value::String(s) => BallValue::String(s.clone()),
            serde_json::Value::Array(items) => {
                BallValue::List(items.iter().map(json_value_to_ball).collect())
            }
            serde_json::Value::Object(fields) => {
                let mut map = BallMap::new();
                for (key, value) in fields {
                    map.insert(key.clone(), json_value_to_ball(value));
                }
                BallValue::Map(map)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── arithmetic ──
    #[test]
    fn add_promotes_int_and_double() {
        assert_eq!(
            ball_add(BallValue::Int(1), BallValue::Int(2)),
            BallValue::Int(3)
        );
        assert_eq!(
            ball_add(BallValue::Int(1), BallValue::Double(2.5)),
            BallValue::Double(3.5)
        );
        assert_eq!(
            ball_add(BallValue::String("a".into()), BallValue::String("b".into())),
            BallValue::String("ab".into())
        );
        assert_eq!(
            ball_add(
                BallValue::List(vec![BallValue::Int(1)]),
                BallValue::List(vec![BallValue::Int(2)])
            ),
            BallValue::List(vec![BallValue::Int(1), BallValue::Int(2)])
        );
    }

    #[test]
    fn divide_truncates_toward_zero_like_dart_tilde_slash() {
        assert_eq!(
            ball_divide(BallValue::Int(7), BallValue::Int(2)),
            BallValue::Int(3)
        );
        assert_eq!(
            ball_divide(BallValue::Int(-7), BallValue::Int(2)),
            BallValue::Int(-3)
        );
        assert_eq!(
            ball_divide(BallValue::Int(7), BallValue::Int(-2)),
            BallValue::Int(-3)
        );
    }

    #[test]
    fn divide_double_always_returns_a_double() {
        assert_eq!(
            ball_divide_double(BallValue::Int(1), BallValue::Int(2)),
            BallValue::Double(0.5)
        );
    }

    #[test]
    fn modulo_is_euclidean_like_dart_percent() {
        assert_eq!(
            ball_modulo(BallValue::Int(-7), BallValue::Int(3)),
            BallValue::Int(2)
        );
        assert_eq!(
            ball_modulo(BallValue::Int(7), BallValue::Int(-3)),
            BallValue::Int(1)
        );
        assert_eq!(
            ball_modulo(BallValue::Int(7), BallValue::Int(3)),
            BallValue::Int(1)
        );
    }

    #[test]
    fn arithmetic_wraps_on_overflow_like_dart_int() {
        assert_eq!(
            ball_add(BallValue::Int(i64::MAX), BallValue::Int(1)),
            BallValue::Int(i64::MIN)
        );
    }

    // ── comparison ──
    #[test]
    fn equals_promotes_int_and_double_cross_type() {
        assert_eq!(
            ball_equals(BallValue::Int(1), BallValue::Double(1.0)),
            BallValue::Bool(true)
        );
        assert_eq!(
            ball_not_equals(BallValue::Int(1), BallValue::Double(1.5)),
            BallValue::Bool(true)
        );
    }

    #[test]
    fn ordering_promotes_numeric_and_compares_strings_lexicographically() {
        assert_eq!(
            ball_less_than(BallValue::Int(1), BallValue::Double(1.5)),
            BallValue::Bool(true)
        );
        assert_eq!(
            ball_less_than(BallValue::String("a".into()), BallValue::String("b".into())),
            BallValue::Bool(true)
        );
    }

    // ── bitwise ──
    #[test]
    fn unsigned_right_shift_is_logical_not_arithmetic() {
        // -1i64 >>> 60 should zero-fill down to a small positive number, not
        // stay -1 (which a sign-extending `>>` would produce).
        let result = ball_unsigned_right_shift(BallValue::Int(-1), BallValue::Int(60));
        assert_eq!(result, BallValue::Int(15));
    }

    // ── field / index ──
    #[test]
    fn field_get_mut_auto_vivifies_and_mutates_in_place() {
        let mut map = BallValue::Map(BallMap::new());
        *ball_field_get_mut(&mut map, "x") = BallValue::Int(5);
        assert_eq!(ball_field_get(map, "x"), BallValue::Int(5));
    }

    #[test]
    fn index_get_mut_mutates_a_list_element_in_place() {
        let mut list = BallValue::List(vec![BallValue::Int(1), BallValue::Int(2)]);
        *ball_index_get_mut(&mut list, BallValue::Int(1)) = BallValue::Int(99);
        assert_eq!(
            list,
            BallValue::List(vec![BallValue::Int(1), BallValue::Int(99)])
        );
    }

    // ── collections ──
    #[test]
    fn list_push_mutates_the_underlying_list() {
        let mut list = BallValue::List(vec![BallValue::Int(1)]);
        ball_list_push(&mut list, BallValue::Int(2));
        assert_eq!(
            list,
            BallValue::List(vec![BallValue::Int(1), BallValue::Int(2)])
        );
    }

    #[test]
    fn list_map_applies_a_function_value_callback() {
        let list = BallValue::List(vec![BallValue::Int(1), BallValue::Int(2)]);
        // The callback is a Ball function *value* (a `BallValue::Function`
        // wrapping a native closure), dispatched via `ball_call_function` —
        // matching what the compiler now emits for a `lambda` (#39).
        let doubler = BallValue::Function(crate::BallFunction::new("", |v| {
            ball_multiply(v, BallValue::Int(2))
        }));
        let doubled = ball_list_map(list, doubler);
        assert_eq!(
            doubled,
            BallValue::List(vec![BallValue::Int(2), BallValue::Int(4)])
        );
    }

    #[test]
    fn ball_call_function_invokes_a_wrapped_closure() {
        let inc = BallValue::Function(crate::BallFunction::new("inc", |v| {
            ball_add(v, BallValue::Int(1))
        }));
        assert_eq!(
            ball_call_function(inc, BallValue::Int(41)),
            BallValue::Int(42)
        );
    }

    #[test]
    fn set_add_deduplicates() {
        let mut set = BallValue::List(vec![BallValue::Int(1)]);
        ball_set_add(&mut set, BallValue::Int(1));
        ball_set_add(&mut set, BallValue::Int(2));
        assert_eq!(
            set,
            BallValue::List(vec![BallValue::Int(1), BallValue::Int(2)])
        );
    }

    // ── virtual properties / method dispatch tag (issue #38) ──
    #[test]
    fn field_get_length_is_a_virtual_property_on_list_string_and_bytes() {
        let list = BallValue::List(vec![
            BallValue::Int(1),
            BallValue::Int(2),
            BallValue::Int(3),
        ]);
        assert_eq!(ball_field_get(list, "length"), BallValue::Int(3));
        assert_eq!(
            ball_field_get(BallValue::String("héllo".into()), "length"),
            BallValue::Int(5)
        );
        assert_eq!(
            ball_field_get(BallValue::Bytes(vec![1, 2]), "length"),
            BallValue::Int(2)
        );
    }

    #[test]
    fn field_get_length_does_not_shadow_a_real_map_or_message_key() {
        let mut map = BallMap::new();
        map.insert(
            "length".to_string(),
            BallValue::String("not a count".into()),
        );
        assert_eq!(
            ball_field_get(BallValue::Map(map), "length"),
            BallValue::String("not a count".into())
        );
    }

    #[test]
    fn message_type_name_reads_the_tag_used_for_method_dispatch() {
        let mut fields = BallMap::new();
        fields.insert("radius".to_string(), BallValue::Double(5.0));
        let circle = BallValue::Message(crate::value::BallMessage {
            type_name: "main:Circle".to_string(),
            fields,
        });
        assert_eq!(ball_message_type_name(&circle), "main:Circle");
    }

    // ── throw / catch payload ──
    #[test]
    fn catch_payload_recovers_a_thrown_ball_value() {
        let result = std::panic::catch_unwind(|| ball_throw(BallValue::String("boom".into())));
        let payload = result.expect_err("ball_throw must panic");
        assert_eq!(
            ball_catch_payload(payload),
            BallValue::String("boom".into())
        );
    }

    // ── strings ──
    #[test]
    fn string_index_of_is_char_indexed() {
        assert_eq!(
            ball_string_index_of(
                BallValue::String("héllo".into()),
                BallValue::String("llo".into())
            ),
            BallValue::Int(2)
        );
    }

    #[test]
    fn string_pad_left_and_right() {
        assert_eq!(
            ball_string_pad_left(
                BallValue::String("5".into()),
                BallValue::Int(3),
                BallValue::String("0".into())
            ),
            BallValue::String("005".into())
        );
        assert_eq!(
            ball_string_pad_right(
                BallValue::String("5".into()),
                BallValue::Int(3),
                BallValue::String("0".into())
            ),
            BallValue::String("500".into())
        );
    }

    // ── math ──
    #[test]
    fn math_gcd_and_lcm() {
        assert_eq!(
            ball_math_gcd(BallValue::Int(12), BallValue::Int(18)),
            BallValue::Int(6)
        );
        assert_eq!(
            ball_math_lcm(BallValue::Int(4), BallValue::Int(6)),
            BallValue::Int(12)
        );
    }
}

/// Dart-SDK method/type helpers (issue #39 gap #2). Each helper is called with
/// the exact packed `input` message shape the compiler emits — a `Map` whose
/// `self` slot is the receiver and `arg0`/`arg1`/named slots the arguments.
#[cfg(test)]
mod dartsdk_tests {
    use super::*;

    /// Build the packed method-call `input` message (`{key: value, …}`).
    fn call(pairs: &[(&str, BallValue)]) -> BallValue {
        let mut map = BallMap::new();
        for (key, value) in pairs {
            map.insert((*key).to_string(), value.clone());
        }
        BallValue::Map(map)
    }

    fn s(text: &str) -> BallValue {
        BallValue::String(text.to_string())
    }

    #[test]
    fn null_coalesce_prefers_non_null_left() {
        assert_eq!(
            ball_null_coalesce(BallValue::Null, BallValue::Int(7)),
            BallValue::Int(7)
        );
        assert_eq!(
            ball_null_coalesce(BallValue::Int(3), BallValue::Int(7)),
            BallValue::Int(3)
        );
    }

    #[test]
    fn try_parse_int_double_num() {
        // int.tryParse
        assert_eq!(
            tryParse(call(&[("self", int.clone()), ("arg0", s("  42 "))])),
            BallValue::Int(42)
        );
        assert_eq!(
            tryParse(call(&[("self", int.clone()), ("arg0", s("nope"))])),
            BallValue::Null
        );
        assert_eq!(
            tryParse(call(&[("self", int.clone()), ("arg0", s("3.5"))])),
            BallValue::Null // "3.5" is not a valid int
        );
        // double.tryParse
        assert_eq!(
            tryParse(call(&[("self", double.clone()), ("arg0", s("3.5"))])),
            BallValue::Double(3.5)
        );
        // num.tryParse: integer literal -> int, fractional -> double
        assert_eq!(
            tryParse(call(&[("self", num.clone()), ("arg0", s("10"))])),
            BallValue::Int(10)
        );
        assert_eq!(
            tryParse(call(&[("self", num.clone()), ("arg0", s("10.5"))])),
            BallValue::Double(10.5)
        );
    }

    #[test]
    fn parse_throws_on_bad_source() {
        assert_eq!(
            parse(call(&[("self", int.clone()), ("arg0", s("100"))])),
            BallValue::Int(100)
        );
        let bad =
            std::panic::catch_unwind(|| parse(call(&[("self", int.clone()), ("arg0", s("x"))])));
        assert!(bad.is_err());
    }

    #[test]
    fn remainder_is_truncated_sign_of_dividend() {
        // int.remainder keeps the dividend's sign (unlike Euclidean `%`).
        assert_eq!(
            remainder(call(&[
                ("self", BallValue::Int(-7)),
                ("arg0", BallValue::Int(3))
            ])),
            BallValue::Int(-1)
        );
        assert_eq!(
            remainder(call(&[
                ("self", BallValue::Double(5.5)),
                ("arg0", BallValue::Int(2))
            ])),
            BallValue::Double(1.5)
        );
    }

    #[test]
    fn from_char_code_builds_string() {
        assert_eq!(
            fromCharCode(call(&[
                ("self", String.clone()),
                ("arg0", BallValue::Int(65))
            ])),
            s("A")
        );
    }

    #[test]
    fn regex_first_match_and_group() {
        // RegExp is the anonymous `{arg0: pattern}` message the engine builds.
        let regexp = call(&[("arg0", s(r"^(\w+)\[(\d+)\]$"))]);
        let matched = firstMatch(call(&[("self", regexp.clone()), ("arg0", s("items[7]"))]));
        // group(0) whole match, group(1)/group(2) captures.
        assert_eq!(
            group(call(&[
                ("self", matched.clone()),
                ("arg0", BallValue::Int(0))
            ])),
            s("items[7]")
        );
        assert_eq!(
            group(call(&[
                ("self", matched.clone()),
                ("arg0", BallValue::Int(1))
            ])),
            s("items")
        );
        assert_eq!(
            group(call(&[
                ("self", matched.clone()),
                ("arg0", BallValue::Int(2))
            ])),
            s("7")
        );
        // No match -> Null.
        assert_eq!(
            firstMatch(call(&[("self", regexp), ("arg0", s("nope"))])),
            BallValue::Null
        );
    }

    #[test]
    fn add_all_list_and_map() {
        let list = BallValue::List(vec![BallValue::Int(1), BallValue::Int(2)]);
        let extra = BallValue::List(vec![BallValue::Int(3)]);
        assert_eq!(
            addAll(call(&[("self", list), ("arg0", extra)])),
            BallValue::List(vec![
                BallValue::Int(1),
                BallValue::Int(2),
                BallValue::Int(3)
            ])
        );
        let mut base = BallMap::new();
        base.insert("a".to_string(), BallValue::Int(1));
        let mut more = BallMap::new();
        more.insert("b".to_string(), BallValue::Int(2));
        let merged = addAll(call(&[
            ("self", BallValue::Map(base)),
            ("arg0", BallValue::Map(more)),
        ]));
        let BallValue::Map(result) = merged else {
            panic!("expected map");
        };
        assert_eq!(result.get("a"), Some(&BallValue::Int(1)));
        assert_eq!(result.get("b"), Some(&BallValue::Int(2)));
    }

    #[test]
    fn remove_list_returns_bool_map_returns_value() {
        let list = BallValue::List(vec![BallValue::Int(1), BallValue::Int(2)]);
        assert_eq!(
            remove(call(&[("self", list.clone()), ("arg0", BallValue::Int(2))])),
            BallValue::Bool(true)
        );
        assert_eq!(
            remove(call(&[("self", list), ("arg0", BallValue::Int(9))])),
            BallValue::Bool(false)
        );
        let mut map = BallMap::new();
        map.insert("k".to_string(), s("v"));
        assert_eq!(
            remove(call(&[("self", BallValue::Map(map)), ("arg0", s("k"))])),
            s("v")
        );
    }

    #[test]
    fn to_set_dedups_preserving_order() {
        let list = BallValue::List(vec![
            BallValue::Int(2),
            BallValue::Int(1),
            BallValue::Int(2),
            BallValue::Int(3),
        ]);
        assert_eq!(
            toSet(call(&[("self", list)])),
            BallValue::List(vec![
                BallValue::Int(2),
                BallValue::Int(1),
                BallValue::Int(3)
            ])
        );
    }

    #[test]
    fn filled_and_element_at_and_set_all() {
        let filled_list = filled(call(&[
            ("self", List.clone()),
            ("arg0", BallValue::Int(3)),
            ("arg1", s("x")),
        ]));
        assert_eq!(filled_list, BallValue::List(vec![s("x"), s("x"), s("x")]));
        assert_eq!(
            elementAt(call(&[
                ("self", filled_list.clone()),
                ("arg0", BallValue::Int(1))
            ])),
            s("x")
        );
        let target = BallValue::List(vec![
            BallValue::Int(0),
            BallValue::Int(0),
            BallValue::Int(0),
        ]);
        let replacement = BallValue::List(vec![BallValue::Int(8), BallValue::Int(9)]);
        assert_eq!(
            setAll(call(&[
                ("self", target),
                ("arg0", BallValue::Int(1)),
                ("arg1", replacement)
            ])),
            BallValue::List(vec![
                BallValue::Int(0),
                BallValue::Int(8),
                BallValue::Int(9)
            ])
        );
    }

    #[test]
    fn set_operations() {
        let a = BallValue::List(vec![
            BallValue::Int(1),
            BallValue::Int(2),
            BallValue::Int(3),
        ]);
        let b = BallValue::List(vec![
            BallValue::Int(2),
            BallValue::Int(3),
            BallValue::Int(4),
        ]);
        assert_eq!(
            union_(call(&[("self", a.clone()), ("arg0", b.clone())])),
            BallValue::List(vec![
                BallValue::Int(1),
                BallValue::Int(2),
                BallValue::Int(3),
                BallValue::Int(4)
            ])
        );
        assert_eq!(
            intersection(call(&[("self", a.clone()), ("arg0", b.clone())])),
            BallValue::List(vec![BallValue::Int(2), BallValue::Int(3)])
        );
        assert_eq!(
            difference(call(&[("self", a), ("arg0", b)])),
            BallValue::List(vec![BallValue::Int(1)])
        );
    }

    #[test]
    fn identical_is_structural_for_primitives() {
        assert_eq!(
            identical(call(&[
                ("arg0", BallValue::Int(5)),
                ("arg1", BallValue::Int(5))
            ])),
            BallValue::Bool(true)
        );
        assert_eq!(
            identical(call(&[("arg0", s("a")), ("arg1", s("b"))])),
            BallValue::Bool(false)
        );
    }

    #[test]
    fn now_exposes_epoch_fields() {
        let now_value = now(BallValue::Null);
        assert!(matches!(
            ball_field_get(now_value.clone(), "millisecondsSinceEpoch"),
            BallValue::Int(_)
        ));
        assert!(matches!(
            ball_field_get(now_value, "microsecondsSinceEpoch"),
            BallValue::Int(_)
        ));
    }

    #[test]
    fn dart_math_helpers() {
        assert_eq!(sqrt(BallValue::Int(9)), BallValue::Double(3.0));
        assert_eq!(
            atan2(call(&[
                ("arg0", BallValue::Int(0)),
                ("arg1", BallValue::Int(1))
            ])),
            BallValue::Double(0.0)
        );
    }

    #[test]
    fn file_mode_marker_has_append() {
        assert_eq!(ball_field_get(io_FileMode.clone(), "append"), s("append"));
    }

    #[test]
    fn file_roundtrip_write_read_exists_delete() {
        let dir = std::env::temp_dir();
        let path = dir
            .join(format!("ball_dartsdk_test_{}.txt", std::process::id()))
            .to_string_lossy()
            .into_owned();
        let file = File(s(&path));
        assert_eq!(
            existsSync(call(&[("self", file.clone())])),
            BallValue::Bool(false)
        );
        writeAsStringSync(call(&[("self", file.clone()), ("arg0", s("hello"))]));
        assert_eq!(
            existsSync(call(&[("self", file.clone())])),
            BallValue::Bool(true)
        );
        assert_eq!(
            readAsStringSync(call(&[("self", file.clone())])),
            s("hello")
        );
        // append mode
        writeAsStringSync(call(&[
            ("self", file.clone()),
            ("arg0", s(" world")),
            ("mode", s("append")),
        ]));
        assert_eq!(
            readAsStringSync(call(&[("self", file.clone())])),
            s("hello world")
        );
        deleteSync(call(&[("self", file.clone())]));
        assert_eq!(existsSync(call(&[("self", file)])), BallValue::Bool(false));
    }
}
