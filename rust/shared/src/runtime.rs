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

use crate::value::{BallList, BallMap, BallValue};

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

pub fn ball_list_map<F: Fn(BallValue) -> BallValue>(list: BallValue, callback: F) -> BallValue {
    BallValue::List(as_list(list).into_iter().map(callback).collect())
}

pub fn ball_list_filter<F: Fn(BallValue) -> BallValue>(list: BallValue, callback: F) -> BallValue {
    BallValue::List(
        as_list(list)
            .into_iter()
            .filter(|item| ball_truthy(callback(item.clone())))
            .collect(),
    )
}

pub fn ball_list_find<F: Fn(BallValue) -> BallValue>(list: BallValue, callback: F) -> BallValue {
    as_list(list)
        .into_iter()
        .find(|item| ball_truthy(callback(item.clone())))
        .unwrap_or_else(|| panic!("ball-compiler runtime: list_find found no matching element"))
}

pub fn ball_list_any<F: Fn(BallValue) -> BallValue>(list: BallValue, callback: F) -> BallValue {
    BallValue::Bool(
        as_list(list)
            .into_iter()
            .any(|item| ball_truthy(callback(item))),
    )
}

pub fn ball_list_all<F: Fn(BallValue) -> BallValue>(list: BallValue, callback: F) -> BallValue {
    BallValue::Bool(
        as_list(list)
            .into_iter()
            .all(|item| ball_truthy(callback(item))),
    )
}

pub fn ball_list_none<F: Fn(BallValue) -> BallValue>(list: BallValue, callback: F) -> BallValue {
    BallValue::Bool(
        !as_list(list)
            .into_iter()
            .any(|item| ball_truthy(callback(item))),
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

pub fn ball_list_flat_map<F: Fn(BallValue) -> BallValue>(
    list: BallValue,
    callback: F,
) -> BallValue {
    let mut out = Vec::new();
    for item in as_list(list) {
        out.extend(as_list(callback(item)));
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
    fn list_map_applies_a_generic_callback() {
        let list = BallValue::List(vec![BallValue::Int(1), BallValue::Int(2)]);
        let doubled = ball_list_map(list, |v| ball_multiply(v, BallValue::Int(2)));
        assert_eq!(
            doubled,
            BallValue::List(vec![BallValue::Int(2), BallValue::Int(4)])
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
