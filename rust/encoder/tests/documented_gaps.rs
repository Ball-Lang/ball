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
//! unverified. **Eight** are flipped today: receiver-less associated functions
//! and cross-file call targets (PR #526), non-`Fn` items inside an `impl`
//! block, tuple + unit structs, module-scope `const`/`static`/`type` aliases,
//! non-`Fn` items inside a `trait` block, and — newest — the cross-file
//! METHOD call, closed by the crate-aware `encode_crate`. The deeper proofs
//! live in `rust/encoder/tests/static_methods.rs`,
//! `rust/encoder/tests/cross_module_calls.rs`,
//! `rust/encoder/tests/mixed_impl_items.rs`,
//! `rust/encoder/tests/tuple_and_unit_structs.rs`,
//! `rust/encoder/tests/mixed_module_items.rs` and
//! `rust/encoder/tests/crate_encoding.rs`; the flipped tests here
//! remain the goalposts that keep this file's gap list honest.
//!
//! **Count them, don't quote a number from memory.** `grep -c '^#\[should_panic'
//! rust/encoder/tests/documented_gaps.rs` is the authoritative "what is still
//! open"; a prose tally in this comment or in `.claude/rules/rust.md` goes
//! stale the moment a slice lands (it had, by two, before this one). Anchor the
//! pattern at the line start: an unanchored `grep -c should_panic` also matches
//! the PROSE mentions in these doc comments, so it over-counts by every one of
//! them — it answered 13 against 6 open attributes when issue #626 caught it.
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
//! largest remaining bucket — was first listed above as unpinned, then pinned
//! (PR #589) *without* being closed, because a gate nothing observes is a
//! missing-test bug on its own. It is CLOSED now, by the crate-aware
//! `encode_crate`, and its test at the bottom of this file is flipped
//! accordingly.

use ball_lang_shared::proto::ball::v1::expression::Expr;
use ball_lang_shared::proto::ball::v1::literal::Value as LiteralValue;
use ball_lang_shared::proto::ball::v1::{
    Expression, FieldValuePair, FunctionCall, FunctionDefinition, ListLiteral, Literal,
    MessageCreation, Module, ModuleImport, Program, Reference,
};

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
/// `collect_impl_method_params` pre-pass. That bucket is CLOSED too now, by
/// the crate-aware `encode_crate` — see `cross_file_method_call_encodes` at
/// the bottom of this file.)
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

/// **HALF CLOSED** by issue #629. A top-level macro invocation is still not
/// folded into the skip above — a macro at item level can be the very thing
/// that DEFINES a type the rest of the file references, so skipping it would
/// orphan those references into a confusing downstream panic naming a type
/// that looks like it should exist. What changed is that a **`macro_rules!`**
/// invocation is now *expanded* rather than refused: this assertion is
/// positive, and the deeper proofs (fixed point, depth limit, inline-`mod`
/// scope, `impl`-body expansion, a dependency-defined macro) live in
/// `rust/encoder/tests/macro_expansion.rs`.
#[test]
fn top_level_macro_rules_invocation_encodes() {
    encode(
        "macro_rules! declare { ($n:ident) => { struct $n { v: i64 } }; }\n\
         declare!(Made);\n\
         fn main() { let m = Made { v: 1 }; println!(\"{}\", m.v); }",
    );
}

/// The half that stays open, and is meant to: a macro **no `macro_rules!` in
/// scope defines**. That is every proc-macro, `#[derive]` helper and attribute
/// macro, which `ball-lang-macro-expand` does not expand by design — its real
/// body is Rust code compiled into a compiler plugin, not a matcher and a
/// transcriber.
#[test]
#[should_panic(expected = "unsupported top-level item")]
fn top_level_proc_macro_invocation_is_a_documented_gap() {
    encode("some_derive_helper!();\nfn main() { println!(\"{}\", 1); }");
}

/// 6 of 196 study files. `methods.rs::encode_macro` maps
/// `println!`/`format!`/`vec!`/`panic!`/`unreachable!` and refuses everything
/// else — `assert!` here, and `write!` (the measured largest remaining bucket).
///
/// The last two arms were added for the compiler↔encoder round trip (#632): the
/// compiler emits `panic!` and `unreachable!` into user programs, so refusing
/// them broke Tier A's stage 3. That is the ONLY reason this list grows —
/// widening it for its own sake is how a syntactic encoder starts guessing. The
/// third macro that sweep found, `matches!`, is NOT mapped and has its own pin
/// at the bottom of this file (#712).
#[test]
#[should_panic(expected = "unsupported macro invocation")]
fn unmapped_macro_invocation_is_a_documented_gap() {
    encode("fn main() { assert!(1 + 1 == 2); }");
}

// ── methods.rs: instance-method resolution ───────────────────────────────────

/// **CLOSED** by issue #491's crate-aware slice — the single largest bucket in
/// the study, **24 of 196 files**, bigger than the 26-file associated-fn bucket
/// was before #526 closed it. `methods.rs::encode_method_call`'s catch-all
/// fires for a `receiver.method(args)` whose method is neither a recognized
/// built-in arm nor a same-file `impl` method name recorded by the
/// `collect_impl_method_params` pre-pass; the overwhelmingly common real-world
/// cause is that the method IS user-defined, just in another file.
///
/// It could not be closed one file at a time. Unlike the cross-file
/// *free-function* call (`other_file::helper(1)`, closed by #526),
/// `receiver.method(args)` carries no module-qualifying path segment for a
/// syntax-only encoder to attribute the callee to. The owner's 2026-09-13
/// decision on #491 was a crate-aware entry point — `encode_crate`, which walks
/// the `mod` graph and encodes every file against ONE crate-wide symbol table,
/// the Rust sibling of `dart/encoder/lib/package_encoder.dart`. The
/// encode → compile → **run** proof lives in
/// `rust/encoder/tests/crate_encoding.rs`.
///
/// The boundary this NARROWS rather than removes has its own pin there
/// (`a_method_no_file_in_the_crate_declares_still_fails_loud`): a method no
/// file in the crate declares is still a loud panic, because a syntax-only
/// encoder cannot tell that from a typo. See `methods.rs`'s module doc comment
/// for the neighbouring PERMANENT carve-outs, which this bucket is explicitly
/// not one of.
#[test]
fn cross_file_method_call_encodes() {
    let crate_root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join("counter_crate");
    let program = ball_lang_encoder::encode_crate(&crate_root);
    assert!(
        program.modules.iter().any(|m| m.name == "counter"),
        "the crate walk must reach the file declaring the called method"
    );
}

// ── lib.rs: re-encoding the COMPILER's own output ────────────────────────────

/// The compiler↔encoder round-trip invariant (#632) in its second shape, still
/// OPEN as issue #687.
///
/// `Compiler::compile()` (script mode) wraps the entry function's body in an
/// immediately-invoked closure — `let _ballvalue_result: BallValue = (|| ->
/// BallValue { … })();` — and `lib.rs`'s call-target match refuses it, so
/// `encode(compile(p))` fails for EVERY program, hello-world included.
///
/// It is not fixed here because the IIFE is load-bearing: it is what makes a
/// `return` inside the entry body return from the entry body rather than from
/// `main`, which returns `()`. Encoding it as a plain Ball `block` would
/// silently change that (a `return` inside a Ball block returns from the
/// enclosing FUNCTION); the faithful shape is a `lambda` invoked through
/// `std.invoke`, which is what `dart/encoder` emits for a
/// `FunctionExpressionInvocation` — a decision #687 owes, together with a
/// run-proof that the `return` still behaves.
///
/// The LIBRARY-mode round trip — the pipeline Tier A stage 3 actually measures
/// — is green and gated by
/// `rust/encoder/tests/compile_reencode_roundtrip.rs`. Flip this pin to a
/// positive assertion in the PR that closes #687.
#[test]
#[should_panic(expected = "unsupported call target")]
fn compiled_entry_point_iife_is_a_documented_gap() {
    let program = ball_lang_encoder::encode(r#"fn main() { println!("{}", 1); }"#);
    let compiled = ball_lang_compiler::Compiler::new(&program).compile();
    encode(&compiled);
}

/// The same invariant's remaining OPEN shape, tracked as issue #712 — and the
/// one the #632 sweep found by enumerating what the compiler EMITS rather than
/// assuming the dispatcher's `panic!` was the only instance.
///
/// `base_call.rs::compile_list_literal` switches to an **imperative** lowering
/// the moment any element splices (a spread, `collection_if` or
/// `collection_for`), and that lowering emits TWO constructs this encoder
/// refuses:
///
/// 1. `let mut __lit: Vec<BallValue> = Vec::new();` — an associated function on
///    a foreign TYPE, a documented `lib.rs` gap, and the FIRST refusal;
/// 2. `if !matches!(__sp, BallValue::Null)` — the null-spread guard, refused by
///    `methods.rs::encode_macro` (pinned separately below, since a
///    `#[should_panic]` can only observe the first panic).
///
/// So #712 is the whole lowering, not one macro: every library whose compiled
/// output contains a spliced collection literal fails stage 3. The `assert!`s
/// below hold BOTH constructs, so the pin cannot quietly narrow to one.
///
/// The input is a Ball program, not Rust source, and deliberately so: Rust has
/// no `...?` syntax, so this construct can only enter the pipeline from the
/// Ball side (the Dart encoder emits it for `[...?l]`). It is driven through
/// the REAL compiler — a pin quoting a remembered emission site stops tracking
/// the compiler the moment that lowering changes.
///
/// The fix belongs on the COMPILER side, in the plain-call vocabulary the
/// neighbouring `ball_truthy`/`ball_iterate`/`ball_spread_iter` calls already
/// use — but note that that vocabulary no longer re-encodes *soft*: since #646
/// an unmapped `ball_*` is a hard refusal, so a compiler-side fix owes
/// `runtime_helpers.rs` the matching inverse (or, where none exists, its own
/// pin, as `compiled_method_dispatcher_scrutinee_is_a_documented_gap` below
/// is). Teaching the encoder a `Vec::new()` or `matches!` arm instead would
/// encode compiler-internal spellings while still refusing every real-world
/// one, which is what Tier A actually measures.
#[test]
#[should_panic(expected = "unsupported call target")]
fn compiled_spliced_list_literal_is_a_documented_gap() {
    let program = null_spread_program();
    let compiled = ball_lang_compiler::Compiler::new(&program).compile_library();
    assert!(
        compiled.contains("Vec::new()"),
        "this pin is only meaningful while the spliced-literal lowering still opens with \
         `Vec::new()` — if that changed, re-measure #712 and update this test:\n{compiled}"
    );
    assert!(
        compiled.contains("matches!"),
        "…and while it still spells the null-spread guard as `matches!`, which is the SECOND \
         refusal behind it:\n{compiled}"
    );
    let _ = ball_lang_encoder::encode_library(&compiled);
}

/// The second half of #712, pinned on its own because `#[should_panic]` sees
/// only the first panic and `Vec::new()` fires ahead of it in the compiled
/// output above. Without this, "the encoder refuses `matches!`" would be an
/// assumption the suite never observed — and a later change that mapped
/// `matches!` would leave the gap looking open when it was closed, or the
/// reverse.
#[test]
#[should_panic(expected = "unsupported macro invocation")]
fn the_matches_macro_is_a_documented_gap() {
    encode("fn main() { let ok = matches!(1, 1); println!(\"{}\", ok); }");
}

/// A library with one struct and one instance method — the smallest source
/// that makes `type_emit.rs::compile_method_dispatchers` emit a dispatcher.
/// Kept byte-identical to `compile_reencode_roundtrip.rs`'s own constant so the
/// pin and the round-trip gate are measuring the same construct.
const CLASS_WITH_METHOD_SOURCE: &str = r#"
struct Point {
    x: i64,
    y: i64,
}

impl Point {
    fn sum(&self) -> i64 {
        self.x + self.y
    }
}
"#;

/// The round-trip invariant's THIRD open instance, tracked as **#718** — and
/// the one that turned `main` red: a semantic merge conflict between #646,
/// which built `runtime_helpers.rs` and made an UNMAPPED `ball_*` a hard
/// refusal, and #685, which added the first test that re-encodes a compiled
/// method dispatcher. Each was green on its own branch; together they are not.
///
/// `type_emit.rs::compile_method_dispatchers` opens every instance-method
/// dispatcher with `match ball_message_type_name(&__self).as_str()`, and that
/// helper has **no universal-`std` inverse**. It returns the receiver's
/// MODULE-QUALIFIED tag (`main:Point` — `rust/shared/src/runtime.rs`), which is
/// not what `std.type_of` returns: #489 defines `type_of` as the *short* base
/// type name, module prefix stripped and generic arguments dropped. Mapping the
/// helper to `type_of` would re-encode a dispatcher whose arms (`"main:Point"`)
/// can never match its own scrutinee (`"Point"`) — structurally valid, silently
/// dead, the #55 class the table exists to prevent. And `dart/shared/std.json`,
/// the canonical base-function inventory, declares no qualified-name function
/// at all, so this is not a table line either.
///
/// It is therefore deliberately NOT fixed here: the three real options (give
/// the helper a genuine `std` inverse — possibly a `std` change; pin it as a
/// gap; or change what the dispatcher emits) each decide what the
/// qualified-vs-short name difference means at the Ball level, and that
/// decision belongs with #632/#642. Whatever lands must keep #646's fail-loud
/// direction. Flip this pin to a positive assertion in the PR that closes #718.
///
/// **The gap is one construct wide here, and much wider in general.** The table
/// maps the universal-`std` subset only; `rust/compiler/src` emits many more
/// `ball_*` helpers than it maps (the collection family, `ball_iterate`,
/// `ball_with_self`, `ball_call_function`, …), so a compiled library naming any
/// of them stops at the first one. Sweep it, never quote it from memory:
/// `grep -ohrE '\bball_[a-z0-9_]+' rust/compiler/src/*.rs | sort -u` against the
/// quoted names in `rust/encoder/src/runtime_helpers.rs`.
///
/// The dispatcher's BEHAVIOURAL half is untouched and still gated:
/// `compile_reencode_roundtrip.rs::dispatcher_fallback_throws_the_target_neutral_message`
/// compiles the compiler's own output, links it against a hand-written `main`
/// and RUNS it, asserting the thrown message as bytes.
#[test]
#[should_panic(expected = "unsupported runtime helper `ball_message_type_name")]
fn compiled_method_dispatcher_scrutinee_is_a_documented_gap() {
    let program = ball_lang_encoder::encode_library(CLASS_WITH_METHOD_SOURCE);
    let compiled = ball_lang_compiler::Compiler::new(&program).compile_library();
    assert!(
        compiled.contains("ball_message_type_name(&__self)"),
        "this pin is only meaningful while the dispatcher still reads the receiver's type \
         through `ball_message_type_name` — if that changed, re-measure #718 and update this \
         test:\n{compiled}"
    );
    let _ = ball_lang_encoder::encode_library(&compiled);
}

/// A one-function library whose body is `[...?input]` — the smallest program
/// that makes `compile_collection_element` emit the null-spread guard.
fn null_spread_program() -> Program {
    let null_spread = Expression {
        expr: Some(Expr::Call(Box::new(FunctionCall {
            module: "std".to_string(),
            function: "null_spread".to_string(),
            input: Some(Box::new(Expression {
                expr: Some(Expr::MessageCreation(MessageCreation {
                    type_name: String::new(),
                    fields: vec![FieldValuePair {
                        name: "value".to_string(),
                        value: Some(Expression {
                            expr: Some(Expr::Reference(Reference {
                                name: "input".to_string(),
                            })),
                        }),
                    }],
                    metadata: None,
                })),
            })),
            type_args: vec![],
        }))),
    };
    let body = Expression {
        expr: Some(Expr::Literal(Literal {
            value: Some(LiteralValue::ListValue(ListLiteral {
                elements: vec![null_spread],
            })),
        })),
    };
    Program {
        name: "null_spread".to_string(),
        version: "1.0.0".to_string(),
        modules: vec![
            ball_lang_shared::build_std_module(),
            Module {
                name: "main".to_string(),
                functions: vec![FunctionDefinition {
                    name: "splice".to_string(),
                    input_type: String::new(),
                    output_type: String::new(),
                    body: Some(Box::new(body)),
                    description: String::new(),
                    is_base: false,
                    metadata: None,
                }],
                module_imports: vec![ModuleImport {
                    name: "std".to_string(),
                    ..Default::default()
                }],
                ..Default::default()
            },
        ],
        entry_module: "main".to_string(),
        entry_function: String::new(),
        metadata: None,
    }
}
