//! Characterization tests for the Rust encoder's **documented scope gaps**
//! (issue #491, slice 1 — measurement only, no behavior change).
//!
//! `rust/encoder/src/lib.rs`'s module doc comment scopes the encoder to
//! single-file programs with a `fn main()`, named-field structs and fieldless
//! enum variants — and **fails loud** (a panic, never a silent skip) the
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
//! ## Closed gaps keep their test, flipped
//!
//! When a slice closes a gap, its test here flips from `#[should_panic]` to a
//! positive "encodes successfully" assertion in the **same PR** — leaving it
//! asserting the old panic text would silently regress a closed gap back to
//! unverified. Two are flipped today (issue #491, slice 3): receiver-less
//! associated functions and cross-file call targets. The deeper proofs for
//! both live in `rust/encoder/tests/static_methods.rs` and
//! `rust/encoder/tests/cross_module_calls.rs`; the flipped tests here remain
//! the goalposts that keep this file's gap list honest.
//!
//! ## Deliberately NOT pinned here
//!
//! - **No `fn main()` (library mode).** Already covered end-to-end on this same
//!   `cargo test --workspace` leg by `rust/cli/tests/cli_encode.rs::
//!   missing_fn_main_exits_2`, which asserts the CLI's intentional exit-2
//!   (`catch_panic_message` wraps `encode`'s panic). A second pin here would add
//!   no coverage.
//! - **Compiler support for receiver-less associated functions.** That was
//!   already implemented and conformance-tested — `rust/compiler/src/
//!   type_emit.rs::method_prologue`'s `is_static` bypass, fixture
//!   `tests/conformance/105_static_methods.ball.json` (issue #288). What was
//!   missing was *encoder-side mapping only*: turning `Point::new(...)`
//!   syntax into that already-supported `is_static` shape — closed by slice 3.
//! - **`methods.rs`' cross-file METHOD-call gap** (`receiver.method(args)`
//!   whose method name isn't in the `collect_impl_method_params` pre-pass —
//!   24 of 196 study files, the largest remaining bucket). It has no pin here
//!   yet; adding one belongs with the slice that closes it.

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

// ── types.rs: receiver-less associated items ─────────────────────────────────

/// **CLOSED** by issue #491's slice 3 — 26 of 196 study files, the single
/// largest error class. The COMPILER already supported this shape
/// (`is_static`, issue #288); the encoder now maps `Point::new(...)` syntax
/// onto it. Flipped from `#[should_panic]` to a positive assertion in the
/// same PR that closed it, per this file's own doc comment; the full
/// encode → compile → run proof lives in
/// `rust/encoder/tests/static_methods.rs`.
#[test]
fn impl_associated_fn_without_receiver_encodes() {
    encode(
        "struct Point { x: i32, y: i32 }\n\
         impl Point { fn new(x: i32, y: i32) -> Point { Point { x, y } } }\n\
         fn main() { let p = Point::new(1, 2); println!(\"{}\", p.x); }",
    );
}

/// The trait-block sibling is still a gap, deliberately: `ball-lang-compiler`'s
/// `compile_method_dispatchers` skips every `is_abstract` member, so a
/// signature-only static trait item would have no dispatcher for a
/// `Maker::make()` call site to resolve to. Closing it needs compiler-side
/// work with no #288-style precedent — see `types.rs`'s module doc comment.
#[test]
#[should_panic(expected = "no `self` receiver inside a `trait`")]
fn trait_associated_fn_without_receiver_is_a_documented_gap() {
    encode("trait Maker { fn make() -> i32; }\nfn main() {}");
}

// ── lib.rs: call-target resolution ───────────────────────────────────────────

/// **CLOSED** by issue #491's slice 3 — 15 of 196 study files, per that
/// issue's own `unsupported call target (only same-file functions)` row. (The
/// table's larger 24-file row is the SEPARATE `unsupported method call,
/// callee not in this file` gap: `methods.rs`'s own panic on a
/// `receiver.method(args)` whose method name isn't in the
/// `collect_impl_method_params` pre-pass. That bucket is untouched here and
/// has no pin in this file yet — it is the recommended next slice.)
///
/// A cross-file call now encodes as an unresolved `ModuleImport` rather than
/// panicking; the structural assertions live in
/// `rust/encoder/tests/cross_module_calls.rs`.
#[test]
fn cross_file_call_target_encodes() {
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
