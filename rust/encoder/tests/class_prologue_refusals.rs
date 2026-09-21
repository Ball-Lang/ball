//! Negative gates for the **class-prologue** refusals `rust/encoder` grew with
//! issue #692 (PR #739) — issue #789.
//!
//! `compiled_collection_ctors.rs` is the positive half of that slice: seven
//! tests, every one of them asserting a SUCCESSFUL re-encode of the compiler's
//! `pub fn __ball_register_types()` prologue. The three refusals the same PR
//! added had nothing at all:
//!
//! 1. `runtime_ctors::superclass_registrations` — the prologue's signature must
//!    be empty, and every statement in it must be
//!    `ball_register_superclass(<str literal>, <str literal>);`.
//! 2. `lib.rs::apply_superclass_registrations` — a registration must resolve to
//!    EXACTLY ONE declared `TypeDefinition` in the file.
//! 3. `lib.rs::Encoder::encode_call` — `__ball_register_types` may only appear
//!    as a bare statement in `fn main()`.
//!
//! ## Why the existing tests cannot see any of this
//!
//! Both whole-corpus legs (`roundtrip_conformance.rs` and
//! `compile_reencode_roundtrip.rs`) feed the encoder `rust/compiler`'s OWN
//! output, which is well-formed by construction: a no-parameter prologue whose
//! every statement is a two-string-literal registration naming a class the same
//! file declares, called once as a bare statement from `fn main()`. Neither leg
//! can reach a malformed prologue, so a refusal could stop firing — or start
//! firing on the wrong condition — with nothing in CI red.
//!
//! ## Why every assertion names a MESSAGE substring
//!
//! A refusal test that only asks "did it panic?" goes green on any panic at
//! all, including one raised passes earlier for an unrelated reason (a parse
//! failure, an unsupported item). Each case here therefore pins a substring of
//! the exact message its target emits, so message drift — or a different panic
//! standing in for the intended one — fails instead of passing quietly. The
//! shapes are all hand-written Rust on purpose: `rust/compiler` emits none of
//! them, which is precisely why no generated corpus can stand in.
use std::panic;

use ball_lang_encoder::encode;
use ball_lang_shared::proto::google::protobuf::value::Kind;

// ════════════════════════════════════════════════════════════
// Sources — every one a shape `rust/compiler` never emits
// ════════════════════════════════════════════════════════════

/// A prologue that declares a parameter. `rust/compiler` emits
/// `pub fn __ball_register_types()` with an empty signature.
const PROLOGUE_WITH_PARAMETER: &str = r#"
struct Animal { name: i64 }
struct Dog { name: i64 }

pub fn __ball_register_types(which: i64) {
    ball_register_superclass("Dog", "Animal");
}

fn main() {
    __ball_register_types(1);
}
"#;

/// A prologue statement that is not an expression-statement CALL at all.
const PROLOGUE_WITH_A_LET: &str = r#"
struct Animal { name: i64 }
struct Dog { name: i64 }

pub fn __ball_register_types() {
    let smuggled = 1;
    ball_register_superclass("Dog", "Animal");
}

fn main() {
    __ball_register_types();
}
"#;

/// A prologue statement that IS a call, but to another function entirely.
const PROLOGUE_WITH_A_FOREIGN_CALL: &str = r#"
struct Animal { name: i64 }
struct Dog { name: i64 }

pub fn __ball_register_types() {
    register_something_else("Dog", "Animal");
}

fn main() {
    __ball_register_types();
}
"#;

/// The right callee, the wrong arity.
const PROLOGUE_WITH_A_ONE_ARGUMENT_REGISTRATION: &str = r#"
struct Animal { name: i64 }
struct Dog { name: i64 }

pub fn __ball_register_types() {
    ball_register_superclass("Dog");
}

fn main() {
    __ball_register_types();
}
"#;

/// A CHILD argument that is a constant reference, not a string literal.
const PROLOGUE_WITH_A_COMPUTED_CHILD: &str = r#"
struct Animal { name: i64 }
struct Dog { name: i64 }

const CHILD: &str = "Dog";

pub fn __ball_register_types() {
    ball_register_superclass(CHILD, "Animal");
}

fn main() {
    __ball_register_types();
}
"#;

/// A PARENT argument that is a constant reference, not a string literal.
const PROLOGUE_WITH_A_COMPUTED_PARENT: &str = r#"
struct Animal { name: i64 }
struct Dog { name: i64 }

const PARENT: &str = "Animal";

pub fn __ball_register_types() {
    ball_register_superclass("Dog", PARENT);
}

fn main() {
    __ball_register_types();
}
"#;

/// The child class is declared inside a nested `pub mod`, which single-file
/// encoding skips entirely — the registration resolves to ZERO declared types.
const CHILD_DECLARED_IN_A_NESTED_MODULE: &str = r#"
struct Animal { name: i64 }

pub mod kennel {
    pub struct Dog { pub name: i64 }
}

pub fn __ball_register_types() {
    ball_register_superclass("Dog", "Animal");
}

fn main() {
    __ball_register_types();
}
"#;

/// Two declared types match the registered short name `Dog`: the short name
/// itself, and the `_`-joined module qualifier `compile_struct_def` emits for a
/// Ball `kennel:Dog`.
const CHILD_MATCHING_TWO_DECLARED_TYPES: &str = r#"
struct Animal { name: i64 }
struct Dog { name: i64 }
struct kennel_Dog { name: i64 }

pub fn __ball_register_types() {
    ball_register_superclass("Dog", "Animal");
}

fn main() {
    __ball_register_types();
}
"#;

/// The prologue called in VALUE position — a `let` initializer.
const PROLOGUE_CALLED_IN_VALUE_POSITION: &str = r#"
struct Animal { name: i64 }
struct Dog { name: i64 }

pub fn __ball_register_types() {
    ball_register_superclass("Dog", "Animal");
}

fn main() {
    let registered = __ball_register_types();
}
"#;

/// The prologue called as a bare statement from a function that is not
/// `fn main()`.
const PROLOGUE_CALLED_FROM_ANOTHER_FUNCTION: &str = r#"
struct Animal { name: i64 }
struct Dog { name: i64 }

pub fn __ball_register_types() {
    ball_register_superclass("Dog", "Animal");
}

fn register_late() {
    __ball_register_types();
}

fn main() {
    register_late();
}
"#;

/// The prologue called as a bare statement from a NESTED block inside
/// `fn main()` — an `if` arm, i.e. conditionally.
const PROLOGUE_CALLED_FROM_A_NESTED_BLOCK: &str = r#"
struct Animal { name: i64 }
struct Dog { name: i64 }

pub fn __ball_register_types() {
    ball_register_superclass("Dog", "Animal");
}

fn main() {
    if 1 < 2 {
        __ball_register_types();
    }
}
"#;

/// The shape `rust/compiler` actually emits — the positive floor.
const COMPILER_SHAPED_PROLOGUE: &str = r#"
struct Animal { name: i64 }
struct Dog { name: i64 }

pub fn __ball_register_types() {
    ball_register_superclass("Dog", "Animal");
}

fn main() {
    __ball_register_types();
    let d = Dog { name: 7 };
}
"#;

// ════════════════════════════════════════════════════════════
// Harness
// ════════════════════════════════════════════════════════════

/// Encode `source`, require that it is REFUSED, and return the refusal's own
/// message so the caller can pin a substring of it.
///
/// `catch_unwind` rather than `#[should_panic]` (issue #789 sanctions either):
/// it keeps the *actual* message in hand, so a mismatch reports both the
/// expected and the observed text instead of libtest's bare "panic did not
/// contain expected string", and it lets one case assert on two independent
/// parts of the same message.
fn refusal(source: &str) -> String {
    let outcome = panic::catch_unwind(|| encode(source));
    let payload = match outcome {
        Ok(_) => panic!(
            "ball-lang-encoder accepted a source it is documented to refuse, and returned a \
             Program instead of failing loud"
        ),
        Err(payload) => payload,
    };
    if let Some(text) = payload.downcast_ref::<&'static str>() {
        return (*text).to_string();
    }
    if let Some(text) = payload.downcast_ref::<String>() {
        return text.clone();
    }
    panic!("the refusal carried a payload that is neither `&str` nor `String`")
}

/// [`refusal`], plus the substring assertion every case needs.
fn assert_refused(source: &str, expected: &str) -> String {
    let message = refusal(source);
    assert!(
        message.contains(expected),
        "the source was refused, but with a different message.\n  expected substring: \
         {expected}\n  actual message:     {message}"
    );
    message
}

// ════════════════════════════════════════════════════════════
// 1. `superclass_registrations` — the prologue's own shape
// ════════════════════════════════════════════════════════════

/// The prologue is DROPPED from the encoded Program, so accepting a
/// parameterised one would silently lose whatever that parameter was for.
#[test]
fn prologue_with_a_parameter_is_refused() {
    assert_refused(
        PROLOGUE_WITH_PARAMETER,
        "ball-lang-encoder: `__ball_register_types` is the compiler's class prologue and takes no parameters; this one declares 1",
    );
}

/// The `let … else` arm's `panic!`, whose message differs from the
/// wrong-callee `assert!` below and is therefore pinned separately.
#[test]
fn prologue_statement_that_is_not_a_call_is_refused() {
    assert_refused(
        PROLOGUE_WITH_A_LET,
        "ball-lang-encoder: `__ball_register_types` may contain only `ball_register_superclass(child, parent);` statements — it is the compiler's class prologue and is dropped from the encoded Program, so anything else in it would be silently lost",
    );
}

/// The `assert!`, whose message ends in a colon rather than the em dash the
/// `panic!` above carries.
#[test]
fn prologue_call_to_another_function_is_refused() {
    assert_refused(
        PROLOGUE_WITH_A_FOREIGN_CALL,
        "ball-lang-encoder: `__ball_register_types` may contain only `ball_register_superclass(child, parent);` statements:",
    );
}

/// Shares the `assert!` above, and is a case of its own because callee and
/// arity are two independent halves of one boolean: dropping either half would
/// leave the other still green.
#[test]
fn prologue_registration_with_one_argument_is_refused() {
    assert_refused(
        PROLOGUE_WITH_A_ONE_ARGUMENT_REGISTRATION,
        "ball-lang-encoder: `__ball_register_types` may contain only `ball_register_superclass(child, parent);` statements:",
    );
}

/// A registration is inverted into a `TypeDefinition`'s `metadata.superclass`
/// at ENCODE time, so a class name only known at run time has no inverse.
#[test]
fn prologue_registration_with_a_computed_child_is_refused() {
    assert_refused(
        PROLOGUE_WITH_A_COMPUTED_CHILD,
        "ball-lang-encoder: `ball_register_superclass`'s child argument must be a string literal",
    );
}

/// The sibling of the child case, separate for the same reason the arity case
/// is: two independent operands.
#[test]
fn prologue_registration_with_a_computed_parent_is_refused() {
    assert_refused(
        PROLOGUE_WITH_A_COMPUTED_PARENT,
        "ball-lang-encoder: `ball_register_superclass`'s parent argument must be a string literal",
    );
}

// ════════════════════════════════════════════════════════════
// 2. `apply_superclass_registrations` — resolving the child
// ════════════════════════════════════════════════════════════

/// ZERO matches, reached exactly the way `apply_superclass_registrations`' own
/// doc comment names it: the child class is declared inside a nested
/// `pub mod`, which single-file encoding skips entirely. Without the refusal
/// the relationship would simply evaporate — the prologue is dropped, and
/// nothing is left carrying the `metadata.superclass` it was to become.
///
/// The message's `--crate` hint is asserted too: it is the only thing telling a
/// caller what to do instead, so losing it would leave a dead end.
#[test]
fn registration_naming_a_type_in_a_nested_module_is_refused() {
    let message = assert_refused(
        CHILD_DECLARED_IN_A_NESTED_MODULE,
        "ball-lang-encoder: `__ball_register_types`'s registration of `Dog` (superclass `Animal`) resolves to 0 declared types in this file, not exactly one",
    );
    assert!(
        message.contains("use `ball encode --crate <dir>` instead"),
        "the zero-match refusal must name the crate-mode remedy; got: {message}"
    );
}

/// TWO matches. The resolver accepts both the SHORT name and a `_`-joined
/// module qualifier, so a file declaring both is genuinely ambiguous: writing
/// the metadata onto whichever the loop happened to see last would be a coin
/// flip, not an encoding.
#[test]
fn registration_matching_two_declared_types_is_refused() {
    assert_refused(
        CHILD_MATCHING_TWO_DECLARED_TYPES,
        "ball-lang-encoder: `__ball_register_types`'s registration of `Dog` (superclass `Animal`) resolves to 2 declared types in this file, not exactly one",
    );
}

// ════════════════════════════════════════════════════════════
// 3. `encode_call` — where the prologue may be invoked
// ════════════════════════════════════════════════════════════

/// `block.rs` drops the prologue call only where it is a bare statement; in a
/// `let` initializer it reaches `encode_call`, which refuses it rather than
/// emitting a call to a function this encoder deliberately does not encode — a
/// Program that would only fail at run time.
#[test]
fn prologue_called_in_value_position_is_refused() {
    assert_refused(
        PROLOGUE_CALLED_IN_VALUE_POSITION,
        "ball-lang-encoder: `__ball_register_types` is the compiler's class prologue, which this encoder inverts into each class's `metadata.superclass` and drops; it may only appear as a bare statement in `fn main()`",
    );
}

/// A BARE-STATEMENT call from a function that is not `fn main()`.
///
/// This is the shape the refusal's own message promises to reject — "it may
/// only appear as a bare statement in `fn main()`" — and therefore the one
/// `block.rs`'s statement drop must NOT swallow. `rust/compiler` emits the call
/// from `compile_entry_main` and nowhere else, so a call from any other body is
/// hand-written Rust asking for something this encoder cannot express: the
/// registrations are hoisted to file scope and applied to the `TypeDefinition`s
/// there, so a call site that looked conditional, ordered, or repeated would be
/// silently flattened into that one static answer — the #55 class of defect.
#[test]
fn prologue_called_from_another_function_is_refused() {
    assert_refused(
        PROLOGUE_CALLED_FROM_ANOTHER_FUNCTION,
        "ball-lang-encoder: `__ball_register_types` is the compiler's class prologue, which this encoder inverts into each class's `metadata.superclass` and drops; it may only appear as a bare statement in `fn main()`",
    );
}

/// The same drop, one level down: a bare-statement call from a NESTED block
/// inside `fn main()`. The prologue's effect is file-scoped, so a conditional
/// registration is not something this encoder can honour; the drop must be
/// pinned to `fn main()`'s own top-level statement list, not to "any bare
/// statement anywhere", or the condition is silently discarded.
#[test]
fn prologue_called_from_a_nested_block_in_main_is_refused() {
    assert_refused(
        PROLOGUE_CALLED_FROM_A_NESTED_BLOCK,
        "ball-lang-encoder: `__ball_register_types` is the compiler's class prologue, which this encoder inverts into each class's `metadata.superclass` and drops; it may only appear as a bare statement in `fn main()`",
    );
}

// ════════════════════════════════════════════════════════════
// Positive floor — the refusals must not swallow the real shape
// ════════════════════════════════════════════════════════════

/// The shape `rust/compiler` actually emits still encodes: a no-parameter
/// prologue of literal registrations, called once as a bare statement from
/// `fn main()`, inverted onto the child's `metadata.superclass` and dropped.
///
/// Without this floor every refusal above could be "satisfied" by an encoder
/// that refuses the prologue outright — eleven green negative tests and a dead
/// feature.
#[test]
fn the_compilers_own_prologue_shape_still_encodes() {
    let program = encode(COMPILER_SHAPED_PROLOGUE);

    let main_module = program
        .modules
        .iter()
        .find(|module| module.name == "main")
        .expect("the encoded Program declares a `main` module");

    // The prologue is not a user function: it must not survive as one.
    assert!(
        !main_module
            .functions
            .iter()
            .any(|function| function.name == "__ball_register_types"),
        "the class prologue must be dropped, not encoded as a user function; got {:?}",
        main_module
            .functions
            .iter()
            .map(|function| function.name.as_str())
            .collect::<Vec<_>>()
    );

    // …and its one registration must have landed on `Dog`.
    let dog = main_module
        .type_defs
        .iter()
        .find(|type_def| type_def.name.rsplit(':').next() == Some("Dog"))
        .expect("the encoded Program declares a `Dog` type");
    let superclass = dog
        .metadata
        .as_ref()
        .and_then(|metadata| metadata.fields.get("superclass"))
        .and_then(|value| value.kind.as_ref())
        .and_then(|kind| match kind {
            Kind::StringValue(text) => Some(text.as_str()),
            _ => None,
        });
    assert_eq!(
        superclass,
        Some("Animal"),
        "`ball_register_superclass(\"Dog\", \"Animal\")` inverts to `Dog`'s metadata.superclass"
    );
}
