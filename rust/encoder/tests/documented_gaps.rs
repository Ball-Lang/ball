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
//! unverified. Seven are flipped today: receiver-less associated functions and
//! cross-file call targets (PR #526), non-`Fn` items inside an `impl` block,
//! tuple + unit structs, and — newest — module-scope `const`/`static`/`type`
//! aliases and non-`Fn` items inside a `trait` block. The deeper proofs live
//! in `rust/encoder/tests/static_methods.rs`,
//! `rust/encoder/tests/cross_module_calls.rs`,
//! `rust/encoder/tests/mixed_impl_items.rs`,
//! `rust/encoder/tests/tuple_and_unit_structs.rs` and
//! `rust/encoder/tests/mixed_module_items.rs`; the flipped tests here
//! remain the goalposts that keep this file's gap list honest.
//!
//! **Closing a gap can create a new one, and that pin is owed in the same
//! PR.** Skipping a module-scope `const` declaration made a *reference* to one
//! newly reachable as a dangling `reference(name)`, so the encoder fails loud
//! at the use site and
//! `reference_to_a_skipped_top_level_const_is_a_documented_gap` pins that.
//! Likewise `top_level_macro_invocation_is_a_documented_gap` pins the carve-out
//! that deliberately was NOT skipped alongside it.
//!
//! **Slice numbering is not used here on purpose.** #491's issue body numbers
//! its slices one way and the PRs that landed self-labelled *different* work
//! with the same ordinals (what the issue calls "slice 5" — tuple/unit structs
//! — merged long after a PR titled "slice 5" that closed non-`Fn` impl items,
//! a gap found organically and never in the issue's list). Naming each gap by
//! its content, not its ordinal, is what keeps this file readable.
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
//!
//! `methods.rs`' cross-file METHOD-call gap — 24 of 196 study files, the
//! largest remaining bucket — used to be listed above as unpinned. It is
//! pinned now, at the bottom of this file, *without* being closed: a gate
//! nothing observes is a missing-test bug on its own, independent of whether
//! the behaviour ever changes.

/// Source is only ever encoded, never compiled, so every snippet here is
/// minimal — the panic must fire on the shape, not on anything downstream.
fn encode(source: &str) {
    let _ = ball_lang_encoder::encode(source);
}

// ── types.rs: struct shapes ──────────────────────────────────────────────────

/// **CLOSED** by issue #491's tuple-and-unit-struct slice — 14 of the 110
/// scored files in the live Tier A funnel, the largest declaration-shape
/// bucket. A tuple struct now declares its elements under their positional
/// index (`"0"`, `"1"` — the very names `member_name` has always produced for
/// a `p.0` *read*), and `Pair(1, 2)` encodes as a `message_creation` rather
/// than as a call to a nonexistent function. Flipped from `#[should_panic]`
/// to a positive assertion in the PR that closed it, per this file's own doc
/// comment; the encode → compile → run proof lives in
/// `rust/encoder/tests/tuple_and_unit_structs.rs`.
#[test]
fn tuple_struct_encodes() {
    encode("struct Pair(i32, i32);\nfn main() { let _p = Pair(1, 2); }");
}

/// The same call site, reached by a unit struct — zero declared fields, and a
/// bare `Marker` used as a *value* encodes as an empty `message_creation`
/// instead of falling through to a reference to a variable nobody declared.
#[test]
fn unit_struct_encodes() {
    encode("struct Marker;\nfn main() { let _m = Marker; }");
}

// ── types.rs: enum shapes ────────────────────────────────────────────────────

/// 5 of the 110 scored Tier A files. `types.rs`'s enum encoding is
/// fieldless-variants-only, and closing it is deliberately NOT bundled with
/// the tuple/unit-struct slice above: a Rust sum type needs BOTH an ADT
/// representation decision for construction (Ball's `TypeDefinition` has no
/// variant-with-payload shape; the nearest neighbour is a `superclass`-per-
/// variant class hierarchy, which no encoder or compiler precedent uses yet)
/// AND new `match`-arm support for type-tag patterns with field binding —
/// `control_flow.rs::encode_match` has exactly two arms today
/// (`is_option_result_pattern` and `encode_literal_switch_match`), so matching
/// a user enum's variant name panics even in the *fieldless* case. Unlike the
/// receiver-less-associated-fn slice, which merely mapped syntax onto issue
/// #288's already-shipped `is_static` shape, this one has no compiler-side
/// precedent to reuse.
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

/// **CLOSED** by issue #491's slice 5 — 14 of the 110 scored files in the
/// live Tier A funnel. A non-`Fn` item inside an `impl` block (an associated
/// `const`/`type`, or an item-position macro) is now SKIPPED instead of
/// aborting the block, matching the tolerance the sibling pre-pass
/// `collect_impl_method_params` always had. Flipped from `#[should_panic]`
/// to a positive assertion in the PR that closed it, per this file's own doc
/// comment; the encode → compile → run proof lives in
/// `rust/encoder/tests/mixed_impl_items.rs`.
#[test]
fn non_method_item_in_impl_encodes() {
    encode(
        "struct Point { x: i32 }\n\
         impl Point { const CAP: i32 = 4; fn get_x(&self) -> i32 { self.x } }\n\
         fn main() { let p = Point { x: 1 }; println!(\"{}\", p.get_x()); }",
    );
}

/// The `impl`-block sibling gap that is STILL open, and is a structurally
/// different one: an `impl` whose *self type* is not a plain named type
/// (`impl<I> Trait for (I::Item,)` — 8 of the 110 scored Tier A files, e.g.
/// `itertools/adaptors/mod.rs`). Ball's class model keys members on an
/// owner's short *name*, so a tuple/GAT self type has no owner to register
/// them under — closing it needs a representation decision, not the
/// tolerance tweak slice 5 applied above.
#[test]
#[should_panic(expected = "unsupported `impl` self type")]
fn impl_for_a_non_named_self_type_is_a_documented_gap() {
    encode(
        "struct Pair;\nimpl From<Pair> for (i32, i32) { fn zero(&self) -> i32 { 0 } }\nfn main() {}",
    );
}

/// The trait-block sibling, **narrowed** to the signature-only sub-case.
///
/// The example below has no default body, and that is now the load-bearing
/// half: `ball-lang-compiler`'s `compile_struct_def` and
/// `compile_method_dispatchers` both skip every `is_abstract` member, so a
/// signature-only static trait item would have no dispatcher for a
/// `Maker::make()` call site to resolve to. Closing THAT still needs
/// compiler-side work with no #288-style precedent.
///
/// What used to be lumped in here and no longer is: a **default-bodied**
/// receiver-less trait fn. Those two compiler passes filter on `is_abstract`
/// alone — never on whether a member's owner is a `trait` — so a concrete
/// trait member is architecturally the same thing as `impl Point { fn
/// new(..) }`, and needs zero compiler change. `types.rs`'s guard therefore
/// keys on the missing BODY, not on the missing receiver; the encode →
/// compile → `cargo build` → run proof is
/// `static_methods.rs::default_bodied_trait_fn_without_receiver_encodes_and_round_trips`.
/// This test stays `#[should_panic]`: the PR that separated the two narrowed
/// this gap, it did not close it.
#[test]
#[should_panic(expected = "no `self` receiver inside a `trait`")]
fn trait_associated_fn_without_receiver_is_a_documented_gap() {
    encode("trait Maker { fn make() -> i32; }\nfn main() {}");
}

/// **CLOSED** — 3 of the 110 scored files in the live Tier A funnel stopped
/// FIRST on `encode_item_trait`'s `only method signatures are supported
/// inside a `trait` block` panic. An associated `const`/`type` inside a
/// `trait` declares nothing Ball models, exactly like its `impl`-block
/// sibling, so it is skipped and the block's real methods keep encoding.
/// Before this slice one associated const aborted the whole file.
///
/// This gap had no pin of its own before the PR that closed it — the panic
/// was reachable only incidentally, through the receiver-less-fn
/// characterization above, which exercises a *different* failure inside the
/// same function. A gate nothing observes is a missing-test bug in its own
/// right, so the pin is added here in the same PR, already flipped. The
/// encode → compile → run proof lives in
/// `rust/encoder/tests/mixed_module_items.rs`.
#[test]
fn trait_associated_const_and_type_encode() {
    encode(
        "trait Shape { const SIDES: i32 = 4; type Unit; fn tag(&self) -> i32 { 1 } }\n\
         fn main() {}",
    );
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

/// **CLOSED** for `const`/`static`/`type` alias — 7 of the 110 scored files
/// in the live Tier A funnel had a top-level `type` alias as their FIRST
/// blocker. A declaration Ball models nothing for is now SKIPPED rather than
/// aborting the whole file, mirroring `types.rs::encode_item_impl`'s
/// identical tolerance for non-`Fn` items one level down. The encode →
/// compile → run proof lives in `rust/encoder/tests/mixed_module_items.rs`.
#[test]
fn top_level_const_static_and_type_alias_encode() {
    encode(
        "const LIMIT: i32 = 10;\nstatic GREETING: i32 = 2;\ntype Coord = i32;\n\
         fn main() { println!(\"{}\", 1); }",
    );
}

/// The other half of that closure, and the reason it is safe: skipping the
/// DECLARATION must never make a *reference* to it silently encode as a read
/// of a binding nobody declared. A bare `LIMIT` is a single-segment path, so
/// (unlike an `impl` block's `Self::CAP`, which lands on the two-segment
/// "unsupported path expression" panic) nothing downstream would have caught
/// it — `encode_path_expr`'s `reference(name)` fallback would have produced a
/// dangling reference. The encoder therefore remembers what it skipped and
/// fails loud at the use site instead.
#[test]
#[should_panic(expected = "names a top-level `const`")]
fn reference_to_a_skipped_top_level_const_is_a_documented_gap() {
    encode("const LIMIT: i32 = 10;\nfn main() { println!(\"{}\", LIMIT); }");
}

/// A top-level **macro invocation** is deliberately NOT folded into the skip
/// above. A macro at item level can be the very thing that DEFINES a type the
/// rest of the file references — `bitflags::bitflags! { ... }` produces the
/// `TestFlags` every `bitflags/tests/*.rs` file then calls into, which is 28
/// of the 110 scored Tier A files. Skipping it would orphan those references
/// into a confusing downstream panic naming a type that looks like it should
/// exist, instead of a clean boundary here. Closing this bucket needs macro
/// *expansion*, a materially bigger feature.
#[test]
#[should_panic(expected = "unsupported top-level item")]
fn top_level_macro_invocation_is_a_documented_gap() {
    encode("some_derive_helper!();\nfn main() { println!(\"{}\", 1); }");
}

/// 6 of 196 study files. Only `println!`/`format!`/`vec!` are mapped
/// (`methods.rs::encode_macro`).
#[test]
#[should_panic(expected = "unsupported macro invocation")]
fn unmapped_macro_invocation_is_a_documented_gap() {
    encode("fn main() { assert!(1 + 1 == 2); }");
}

// ── methods.rs: instance-method resolution ───────────────────────────────────

/// The single largest remaining bucket of issue #491 — **24 of 196 study
/// files**, bigger than the 26-file associated-fn bucket was after that one
/// closed — and, until now, the only gap in this file's list with no pin at
/// all. `methods.rs::encode_method_call`'s catch-all fires for a
/// `receiver.method(args)` whose method is neither a recognized built-in arm
/// nor a same-file `impl` method name recorded by the
/// `collect_impl_method_params` pre-pass; the overwhelmingly common real-world
/// cause is that the method IS user-defined, just in another file.
///
/// Behaviour is unchanged by the PR that added this test — the gate already
/// existed, nothing observed it. It is deliberately NOT closed here: unlike
/// the cross-file *free-function* call (`other_file::helper(1)`, closed
/// earlier), `receiver.method(args)` carries no module-qualifying path segment
/// for a syntax-only encoder to attribute the callee to, so closing it needs a
/// multi-file-aware encoding mode — a design decision, not a dispatch-table
/// arm. See `methods.rs`'s module doc comment for the neighbouring PERMANENT
/// carve-outs, which this bucket is explicitly not one of.
#[test]
#[should_panic(expected = "unsupported method call")]
fn cross_file_method_call_is_a_documented_gap() {
    encode(
        "struct Foo { x: i32 }\n\
         impl Foo { fn get(&self) -> i32 { self.x } }\n\
         fn main() { let f = Foo { x: 1 }; println!(\"{}\", f.other_method()); }",
    );
}
