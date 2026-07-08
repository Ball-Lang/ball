//! Runtime value model for the Ball Rust implementation (issue #35).
//!
//! Every Ball value at runtime is one of the [`BallValue`] variants. This
//! mirrors `dart/engine/lib/ball_value.dart` (the Dart reference's typed
//! value hierarchy) and `cpp/shared/include/ball_shared.h`'s
//! `BallValue`/`BallList`/`BallMap` aliases, adapted to Rust's ownership
//! model: instead of a single dynamic `std::any`/`Object?`, values are a
//! plain `enum` so the compiler/engine can pattern-match exhaustively.

use std::fmt;
use std::sync::Arc;

use indexmap::IndexMap;

use crate::proto::ball::v1::expression::Expr;
use crate::proto::ball::v1::{Expression, FunctionCall};

/// An ordered list of Ball values. Equivalent to Dart's `BallList`/C++'s
/// `BallList = std::vector<BallValue>`.
pub type BallList = Vec<BallValue>;

/// A string-keyed, **insertion-ordered** map of Ball values.
///
/// Every reference engine preserves insertion order for Ball's `map` type
/// (Dart's `LinkedHashMap`-backed `Map`, C++'s `BallOrderedMap`, JS's native
/// `Map`/object property order). `indexmap::IndexMap` gives the same
/// guarantee in Rust: iterating a `BallMap` after building it yields entries
/// in the order they were first inserted, even after further mutation.
pub type BallMap = IndexMap<String, BallValue>;

/// A descriptor-backed message instance — the runtime materialization of a
/// `MessageCreation` expression once its `type_name` is a real
/// `TypeDefinition` (as opposed to a plain untyped `MessageCreation` used to
/// carry a base function's named arguments, which lowers to a bare
/// [`BallMap`] via [`extract_fields`]).
///
/// Mirrors the Dart engine's convention of tagging a field map with a
/// `__type__` key (see `dart/engine/lib/engine_eval.dart`) but as a proper
/// struct instead of a stringly-typed sentinel field.
#[derive(Debug, Clone, PartialEq)]
pub struct BallMessage {
    /// The originating `TypeDefinition.name`.
    pub type_name: String,
    /// Field name -> value, insertion-ordered like every other Ball map.
    pub fields: BallMap,
}

/// A first-class callable value — a compiled Ball `lambda`, or a top-level
/// function referenced as a value — wrapping a **native Rust closure**.
///
/// The compiled-target engine (issue #39) invokes function values directly
/// through this closure (`ball_call_function`), so — unlike a tree-walking
/// interpreter, which could re-enter an AST — the callable *must* be a real
/// `Fn`, not a name/definition handle (there is no interpreter to re-enter,
/// and no runtime registry mapping a function name string back to its
/// compiled Rust item). The closure is stored behind an `Arc` so
/// `BallFunction` (and thus [`BallValue`]) stays:
/// - `Clone` — an `Arc` clone shares the one closure (a `BallValue` is
///   `.clone()`d on every read; see the compiler's `compile_reference`);
/// - `Send + Sync` — required because `ball_throw` panics with a `BallValue`
///   payload via `panic_any`, which needs `Any + Send`, and every reference
///   engine's `throw` can carry *any* value, including a closure.
///
/// The wrapped closure is `'static`: a compiled `move |input| { … }` lambda
/// captures owned, already-`.clone()`d `BallValue`s, and a top-level function
/// coerces from its `fn` item (also `'static`).
#[derive(Clone)]
pub struct BallFunction {
    /// Cosmetic label for `Debug`/`Display` — a bound function's name, or
    /// empty for an anonymous lambda. Never affects call behavior or
    /// equality (functions are compared by closure identity — see
    /// [`PartialEq`]).
    pub name: String,
    /// The native callable. `Arc<dyn Fn …>` keeps this cheaply `Clone`able
    /// and `Send + Sync` (see the type doc comment).
    pub callable: Arc<dyn Fn(BallValue) -> BallValue + Send + Sync>,
}

impl BallFunction {
    /// Wrap a native Rust closure as a callable Ball function value. `name`
    /// is cosmetic (a lambda passes `""`); `callable` is the compiled body
    /// (`move |input| { … }`) or a top-level function's `fn` item.
    pub fn new(
        name: impl Into<String>,
        callable: impl Fn(BallValue) -> BallValue + Send + Sync + 'static,
    ) -> Self {
        BallFunction {
            name: name.into(),
            callable: Arc::new(callable),
        }
    }

    /// Invoke the wrapped closure with `input` (invariant #1 — one input,
    /// one output).
    pub fn call(&self, input: BallValue) -> BallValue {
        (self.callable)(input)
    }
}

/// Two function values are equal iff they share the *same* underlying
/// closure (`Arc` pointer identity). A by-value model has no structural way
/// to compare two distinct closures, and the reference engines' `identical`
/// on functions is likewise reference identity — so this matches Dart's
/// closure `==` (same function instance) rather than claiming any two
/// closures with equal behavior are equal.
impl PartialEq for BallFunction {
    fn eq(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.callable, &other.callable)
    }
}

/// `dyn Fn` is not `Debug`, so this prints the cosmetic label instead of the
/// closure itself (matching [`Display`]).
impl fmt::Debug for BallFunction {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{self}")
    }
}

impl fmt::Display for BallFunction {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.name.is_empty() {
            write!(f, "<lambda>")
        } else {
            write!(f, "<function {}>", self.name)
        }
    }
}

/// The root runtime value type. Every expression in a Ball program evaluates
/// to one of these variants.
#[derive(Debug, Clone)]
pub enum BallValue {
    /// Ball's `null`.
    Null,
    /// A boolean value.
    Bool(bool),
    /// A 64-bit signed integer (Ball's `int`).
    Int(i64),
    /// A 64-bit float (Ball's `double`).
    Double(f64),
    /// A UTF-8 string.
    String(String),
    /// Raw bytes (Ball's `bytes` literal). Reference engines materialize a
    /// bytes literal as a list of individual byte integers (see
    /// `dart/engine/lib/engine_eval.dart`'s `bytesValue.toList()`), so
    /// [`fmt::Display`] renders it identically to a list of ints.
    Bytes(Vec<u8>),
    /// An ordered list of values.
    List(BallList),
    /// A string-keyed, insertion-ordered map of values.
    Map(BallMap),
    /// A first-class function value wrapping a native Rust closure (a
    /// compiled `lambda`, or a top-level function referenced as a value).
    Function(BallFunction),
    /// A descriptor-backed message instance.
    Message(BallMessage),
}

/// Hand-written (not `#[derive]`d) so `Int`/`Double` compare by numeric value
/// across variants — Dart's `num.==` treats `0 == 0.0` as `true` (both `int`
/// and `double` are `num`), and the reference engines/compilers all honor
/// this: see `cpp/shared/include/ball_dyn.h`'s `BallDyn::operator==` ("Numeric
/// cross-type equality: Dart `0 == 0.0` is true.") and
/// `dart/engine/lib/engine_std.dart`'s `equals` dispatch, which is Dart's own
/// native `==` and therefore gets this for free. Every other pairing falls
/// back to ordinary per-variant structural equality (derived-`PartialEq`
/// shaped, just written out explicitly since the numeric arm can't be
/// expressed by `#[derive]`).
impl PartialEq for BallValue {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (BallValue::Int(a), BallValue::Double(b))
            | (BallValue::Double(b), BallValue::Int(a)) => (*a as f64) == *b,
            (BallValue::Null, BallValue::Null) => true,
            (BallValue::Bool(a), BallValue::Bool(b)) => a == b,
            (BallValue::Int(a), BallValue::Int(b)) => a == b,
            (BallValue::Double(a), BallValue::Double(b)) => a == b,
            (BallValue::String(a), BallValue::String(b)) => a == b,
            (BallValue::Bytes(a), BallValue::Bytes(b)) => a == b,
            (BallValue::List(a), BallValue::List(b)) => a == b,
            (BallValue::Map(a), BallValue::Map(b)) => a == b,
            (BallValue::Function(a), BallValue::Function(b)) => a == b,
            (BallValue::Message(a), BallValue::Message(b)) => a == b,
            _ => false,
        }
    }
}

impl fmt::Display for BallValue {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            BallValue::Null => write!(f, "null"),
            BallValue::Bool(value) => write!(f, "{value}"),
            BallValue::Int(value) => write!(f, "{value}"),
            BallValue::Double(value) => write!(f, "{}", format_double(*value)),
            BallValue::String(value) => write!(f, "{value}"),
            BallValue::Bytes(bytes) => {
                write!(f, "[")?;
                for (index, byte) in bytes.iter().enumerate() {
                    if index > 0 {
                        write!(f, ", ")?;
                    }
                    write!(f, "{byte}")?;
                }
                write!(f, "]")
            }
            BallValue::List(items) => {
                write!(f, "[")?;
                for (index, item) in items.iter().enumerate() {
                    if index > 0 {
                        write!(f, ", ")?;
                    }
                    write!(f, "{item}")?;
                }
                write!(f, "]")
            }
            BallValue::Map(map) => write_entries(f, map.iter()),
            BallValue::Function(function) => write!(f, "{function}"),
            BallValue::Message(message) => write_entries(f, message.fields.iter()),
        }
    }
}

/// Shared `{key: value, ...}` rendering for [`BallValue::Map`] and
/// [`BallValue::Message`].
fn write_entries<'a>(
    f: &mut fmt::Formatter<'_>,
    entries: impl Iterator<Item = (&'a String, &'a BallValue)>,
) -> fmt::Result {
    write!(f, "{{")?;
    for (index, (key, value)) in entries.enumerate() {
        if index > 0 {
            write!(f, ", ")?;
        }
        write!(f, "{key}: {value}")?;
    }
    write!(f, "}}")
}

/// Format a Ball `double` the way every reference engine's stdout does.
///
/// Ports the special cases from the C++ self-host's `ball_to_string(double)`
/// (`cpp/shared/include/ball_emit_runtime.h`), which itself matches Dart's
/// `double.toString()`: NaN/Infinity spellings, signed zero (`-0.0` is
/// distinct from `0.0` — see issue #101), and whole numbers always keeping a
/// trailing `.0` (Rust's own `f64` `Display` drops it, e.g. `5.0.to_string()
/// == "5"`).
///
/// For the general fractional case this defers to Rust's native `f64`
/// `Display`, which — like Dart's and JS's double-to-string — produces the
/// shortest decimal that round-trips back to the same bits, so it agrees
/// with the reference engines for every ordinary magnitude. Dart switches to
/// exponential notation above roughly `1e21` (and for very small
/// subnormals); Rust's `Display` never does. Matching that exact threshold
/// is deferred to the engine/conformance phases (issues #39/#40), where it
/// can be verified against the corpus instead of guessed here.
pub(crate) fn format_double(value: f64) -> String {
    if value.is_nan() {
        return "NaN".to_string();
    }
    if value.is_infinite() {
        return if value.is_sign_negative() {
            "-Infinity".to_string()
        } else {
            "Infinity".to_string()
        };
    }
    if value == 0.0 {
        return if value.is_sign_negative() {
            "-0.0".to_string()
        } else {
            "0.0".to_string()
        };
    }
    if value.fract() == 0.0 && value.abs() < 1e16 {
        return format!("{}.0", value as i64);
    }
    value.to_string()
}

/// Pull named fields out of a `FunctionCall`'s input expression — the
/// universal base-function calling convention (see CLAUDE.md's "Base
/// functions have no body" invariant and `dart/compiler/lib/compiler.dart`'s
/// `_extractFields`, which this mirrors exactly):
///
/// - No input at all -> an empty map.
/// - The input is a `MessageCreation` -> `{field.name: field.value, ...}`
///   for each `FieldValuePair` (a field with no explicit value maps to a
///   default/empty [`Expression`], matching Dart protobuf's auto-vivifying
///   getter semantics).
/// - Any other input expression (a unary base function's single argument)
///   -> `{"value": input}`.
pub fn extract_fields(call: &FunctionCall) -> IndexMap<String, Expression> {
    let Some(input) = call.input.as_deref() else {
        return IndexMap::new();
    };
    if let Some(Expr::MessageCreation(message_creation)) = &input.expr {
        return message_creation
            .fields
            .iter()
            .map(|field| (field.name.clone(), field.value.clone().unwrap_or_default()))
            .collect();
    }
    let mut fields = IndexMap::with_capacity(1);
    fields.insert("value".to_string(), input.clone());
    fields
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::proto::ball::v1::{FieldValuePair, Literal, MessageCreation};

    fn int_literal(value: i64) -> Expression {
        Expression {
            expr: Some(Expr::Literal(Literal {
                value: Some(crate::proto::ball::v1::literal::Value::IntValue(value)),
            })),
        }
    }

    #[test]
    fn ball_map_preserves_insertion_order() {
        let mut map = BallMap::new();
        map.insert("z".to_string(), BallValue::Int(1));
        map.insert("a".to_string(), BallValue::Int(2));
        map.insert("m".to_string(), BallValue::Int(3));

        let keys: Vec<&str> = map.keys().map(String::as_str).collect();
        assert_eq!(
            keys,
            vec!["z", "a", "m"],
            "insertion order must survive a build -> iterate round trip"
        );

        // Overwriting an existing key must not move it to the end (matches
        // Dart's LinkedHashMap / JS Map semantics).
        map.insert("z".to_string(), BallValue::Int(99));
        let keys_after_overwrite: Vec<&str> = map.keys().map(String::as_str).collect();
        assert_eq!(keys_after_overwrite, vec!["z", "a", "m"]);
        assert_eq!(map["z"], BallValue::Int(99));
    }

    #[test]
    fn display_matches_reference_engine_formatting() {
        assert_eq!(BallValue::Null.to_string(), "null");
        assert_eq!(BallValue::Bool(true).to_string(), "true");
        assert_eq!(BallValue::Int(42).to_string(), "42");
        assert_eq!(BallValue::String("hi".to_string()).to_string(), "hi");
        assert_eq!(BallValue::Bytes(vec![1, 2, 3]).to_string(), "[1, 2, 3]");

        // Doubles: whole numbers always keep a trailing `.0`.
        assert_eq!(BallValue::Double(5.0).to_string(), "5.0");
        assert_eq!(BallValue::Double(-2.0).to_string(), "-2.0");
        // Signed zero is distinct (issue #101 parity).
        assert_eq!(BallValue::Double(0.0).to_string(), "0.0");
        assert_eq!(BallValue::Double(-0.0).to_string(), "-0.0");
        // NaN / Infinity spellings.
        assert_eq!(BallValue::Double(f64::NAN).to_string(), "NaN");
        assert_eq!(BallValue::Double(f64::INFINITY).to_string(), "Infinity");
        assert_eq!(
            BallValue::Double(f64::NEG_INFINITY).to_string(),
            "-Infinity"
        );
        // Ordinary fractional values round-trip through the shortest decimal.
        assert_eq!(BallValue::Double(3.25).to_string(), "3.25");
        assert_eq!(BallValue::Double(0.1).to_string(), "0.1");

        let list = BallValue::List(vec![BallValue::Int(1), BallValue::Int(2)]);
        assert_eq!(list.to_string(), "[1, 2]");

        let mut map = BallMap::new();
        map.insert("a".to_string(), BallValue::Int(1));
        map.insert("b".to_string(), BallValue::String("x".to_string()));
        assert_eq!(BallValue::Map(map).to_string(), "{a: 1, b: x}");

        let function = BallValue::Function(BallFunction::new("print", |input| input));
        assert_eq!(function.to_string(), "<function print>");

        let lambda = BallValue::Function(BallFunction::new("", |input| input));
        assert_eq!(lambda.to_string(), "<lambda>");

        let mut fields = BallMap::new();
        fields.insert("x".to_string(), BallValue::Int(1));
        let message = BallValue::Message(BallMessage {
            type_name: "Point".to_string(),
            fields,
        });
        assert_eq!(message.to_string(), "{x: 1}");
    }

    #[test]
    fn extract_fields_from_message_creation_input() {
        let call = FunctionCall {
            module: String::new(),
            function: "add".to_string(),
            input: Some(Box::new(Expression {
                expr: Some(Expr::MessageCreation(MessageCreation {
                    type_name: "BinaryInput".to_string(),
                    fields: vec![
                        FieldValuePair {
                            name: "left".to_string(),
                            value: Some(int_literal(1)),
                        },
                        FieldValuePair {
                            name: "right".to_string(),
                            value: Some(int_literal(2)),
                        },
                    ],
                    metadata: None,
                })),
            })),
            type_args: vec![],
        };

        let fields = extract_fields(&call);
        assert_eq!(fields.len(), 2);
        assert_eq!(fields.keys().collect::<Vec<_>>(), vec!["left", "right"]);
        assert_eq!(fields["left"], int_literal(1));
        assert_eq!(fields["right"], int_literal(2));
    }

    #[test]
    fn extract_fields_from_non_message_input_maps_to_value_key() {
        let call = FunctionCall {
            module: String::new(),
            function: "negate".to_string(),
            input: Some(Box::new(int_literal(5))),
            type_args: vec![],
        };

        let fields = extract_fields(&call);
        assert_eq!(fields.len(), 1);
        assert_eq!(fields["value"], int_literal(5));
    }

    #[test]
    fn numeric_cross_type_equality_matches_dart_num_semantics() {
        assert_eq!(BallValue::Int(0), BallValue::Double(0.0));
        assert_eq!(BallValue::Double(2.0), BallValue::Int(2));
        assert_ne!(BallValue::Int(2), BallValue::Double(2.5));
        assert_ne!(BallValue::Int(1), BallValue::Bool(true));
        // Nested (list/map) equality recurses through the same numeric rule.
        assert_eq!(
            BallValue::List(vec![BallValue::Int(1)]),
            BallValue::List(vec![BallValue::Double(1.0)])
        );
    }

    #[test]
    fn extract_fields_with_no_input_is_empty() {
        let call = FunctionCall {
            module: String::new(),
            function: "read_line".to_string(),
            input: None,
            type_args: vec![],
        };
        assert!(extract_fields(&call).is_empty());
    }
}
