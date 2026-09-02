//! Characterization tests for the Rust encoder's **documented scope gaps**
//! (issue #491, slice 1 — measurement only, no behavior change).
//!
//! `rust/encoder/src/lib.rs`'s module doc comment scopes the encoder to
//! single-file programs with a `fn main()`, same-file call resolution,
//! named-field structs, fieldless enum variants and receiver-bearing
//! associated items — and **fails loud** (a panic, never a silent skip) the
//! moment source falls outside that boundary. Issue #491's real-code study
//! (196 files from 10 popular crates) drove real library code through it and
//! got 0/196 encodes, every failure landing on one of those panics.
//!
//! Nothing in CI ever *observed* those panics: `rust/encoder/tests/
//! end_to_end.rs`'s fixtures are all single-file `fn main` programs, because
//! the shared conformance corpus is single-file-main-only by construction. The
//! gates existed; the inputs that trigger them did not. These tests supply the
//! inputs, so the module-doc gap list and the enforced-in-CI list can no longer
//! drift apart — and each one is a ready goalpost: when a later slice closes
//! its gap, the `#[should_panic]` here flips into a real "encodes and
//! round-trips" assertion, so a slice cannot merge without visibly moving it.
//!
//! Each `expected =` pins the **shortest stable substring** of today's panic,
//! not the whole sentence, so a legitimate reword of the surrounding prose does
//! not break the test.
//!
//! ## Deliberately NOT pinned here
//!
//! - **No `fn main()` (library mode).** Already covered end-to-end on this same
//!   `cargo test --workspace` leg by `rust/cli/tests/cli_encode.rs::
//!   missing_fn_main_exits_2`, which asserts the CLI's intentional exit-2
//!   (`catch_panic_message` wraps `encode`'s panic). A second pin here would add
//!   no coverage.
//! - **Compiler support for receiver-less associated functions.** That is
//!   already implemented and conformance-tested — `rust/compiler/src/
//!   type_emit.rs::method_prologue`'s `is_static` bypass, fixture
//!   `tests/conformance/105_static_methods.ball.json` (issue #288). The gap
//!   pinned below is *encoder-side mapping only*: turning `Point::new(...)`
//!   syntax into that already-supported `is_static` shape.

/// Source is only ever encoded, never compiled, so every snippet here is
/// minimal — the panic must fire on the shape, not on anything downstream.
fn encode(source: &str) {
    let _ = ball_lang_encoder::encode(source);
}

// ── types.rs: struct shapes (slice 5) ────────────────────────────────────────

/// 15 of 196 study files. `types.rs`'s struct encoding is named-fields-only.
#[test]
#[should_panic(expected = "only a struct with named fields is supported")]
fn tuple_struct_is_a_documented_gap() {
    encode("struct Pair(i32, i32);\nfn main() { let _p = Pair(1, 2); }");
}

/// The same panic site, reached by a unit struct.
#[test]
#[should_panic(expected = "only a struct with named fields is supported")]
fn unit_struct_is_a_documented_gap() {
    encode("struct Marker;\nfn main() { let _m = Marker; }");
}

// ── types.rs: enum shapes (slice 6) ──────────────────────────────────────────

/// 10 of 196 study files. `types.rs`'s enum encoding is fieldless-variants-only.
#[test]
#[should_panic(expected = "an enum variant carrying data is not supported")]
fn data_carrying_enum_variant_is_a_documented_gap() {
    encode("enum Shape { Circle(f64), Square }\nfn main() { let _s = Shape::Square; }");
}

// ── types.rs: receiver-less associated items (slice 4) ───────────────────────

/// 26 of 196 study files — the single largest error class. The COMPILER
/// already supports this shape (`is_static`, issue #288); the encoder does not
/// yet map `Point::new(...)` syntax onto it.
#[test]
#[should_panic(expected = "an associated function with no `self` receiver (`Point::new`)")]
fn impl_associated_fn_without_receiver_is_a_documented_gap() {
    encode(
        "struct Point { x: i32, y: i32 }\n\
         impl Point { fn new(x: i32, y: i32) -> Point { Point { x, y } } }\n\
         fn main() { let p = Point::new(1, 2); println!(\"{}\", p.x); }",
    );
}

/// The trait-block sibling of the same gap (a distinct panic site).
#[test]
#[should_panic(expected = "no `self` receiver inside a `trait`")]
fn trait_associated_fn_without_receiver_is_a_documented_gap() {
    encode("trait Maker { fn make() -> i32; }\nfn main() {}");
}

// ── lib.rs: call-target resolution (slice 3) ─────────────────────────────────

/// 24 of 196 study files: a call whose target lives in another file/module has
/// no same-file `FunctionDefinition` to resolve against.
#[test]
#[should_panic(expected = "unsupported call target")]
fn cross_file_call_target_is_a_documented_gap() {
    encode("fn main() { println!(\"{}\", other_file::helper(1)); }");
}

// ── lib.rs: item- and macro-level scope ──────────────────────────────────────

/// Item-level `const`/`static`/`type` (and item-position macro invocations)
/// are outside issue #43's declaration scope.
#[test]
#[should_panic(expected = "unsupported top-level item")]
fn top_level_const_is_a_documented_gap() {
    encode("const LIMIT: i32 = 10;\nfn main() { println!(\"{}\", LIMIT); }");
}

/// 6 of 196 study files. Only `println!`/`format!`/`vec!` are mapped
/// (`methods.rs::encode_macro`).
#[test]
#[should_panic(expected = "unsupported macro invocation")]
fn unmapped_macro_invocation_is_a_documented_gap() {
    encode("fn main() { assert!(1 + 1 == 2); }");
}
