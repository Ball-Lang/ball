//! `macro_rules!` expansion in the Rust encoder (issue #629).
//!
//! ## What this file is for
//!
//! `rust/encoder/src/lib.rs` refuses an item-level macro **loudly** — a macro
//! at item position can be the very thing that DEFINES a type the rest of the
//! file calls into, so skipping it would orphan those references into a
//! downstream panic naming a type that looks like it should exist. Closing
//! that needs real expansion, not a per-macro desugaring, and #629's owner
//! decision (2026-09-14) is to do it the way rust-analyzer does: its own
//! macro-by-example engine, quarantined behind the `ball-lang-macro-expand`
//! crate.
//!
//! Every fixture-based test here runs against `tests/fixtures/macro_crate` — a
//! real, hermetic two-crate fixture whose crate root invokes a LOCAL
//! `macro_rules!` at item position and whose `flags` module invokes a
//! DEPENDENCY-defined, `#[macro_export]`ed one reached through `cargo
//! metadata`. Nothing in the encoder knows the name `bitflags` (or
//! `mini_bitflags`); the fixture is a stand-in for the general mechanism, never
//! a special case.

use std::path::{Path, PathBuf};

use ball_lang_shared::proto::ball::v1::{Module, Program};

use ball_lang_encoder::{encode, encode_crate, encode_library};

/// `rust/encoder/tests/fixtures/macro_crate` — the crate root directory, the
/// spelling `encode_crate` documents as its entry point.
fn macro_crate_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/macro_crate")
}

fn read_fixture(relative: &str) -> String {
    let path = macro_crate_dir().join(relative);
    std::fs::read_to_string(&path)
        .unwrap_or_else(|err| panic!("failed to read fixture {}: {err}", path.display()))
}

fn module<'a>(program: &'a Program, name: &str) -> &'a Module {
    program
        .modules
        .iter()
        .find(|m| m.name == name)
        .unwrap_or_else(|| {
            panic!(
                "no module `{name}` in the encoded program (modules: {:?})",
                program.modules.iter().map(|m| &m.name).collect::<Vec<_>>()
            )
        })
}

/// Declared type names, with the `main:` module qualifier `types.rs`'s
/// `qualified_type_name` adds stripped back off.
fn type_names(module: &Module) -> Vec<String> {
    module
        .type_defs
        .iter()
        .map(|def| def.name.rsplit(':').next().unwrap_or(&def.name).to_owned())
        .collect()
}

/// A struct's declared FIELDS, read off its protobuf descriptor.
fn field_names(module: &Module, type_name: &str) -> Vec<String> {
    module
        .type_defs
        .iter()
        .find(|def| def.name.ends_with(type_name))
        .unwrap_or_else(|| {
            panic!(
                "no type `{type_name}` in module `{}` (types: {:?})",
                module.name,
                type_names(module)
            )
        })
        .descriptor
        .as_ref()
        .unwrap_or_else(|| panic!("type `{type_name}` has no descriptor"))
        .field
        .iter()
        .map(|field| field.name.clone().unwrap_or_default())
        .collect()
}

/// Every function the module declares, by name (a method is
/// `<qualified type>.<method>`).
fn function_names(module: &Module) -> Vec<String> {
    module.functions.iter().map(|f| f.name.clone()).collect()
}

// ── The closed gap: a local item-level `macro_rules!` ────────────────────────

/// **CLOSED** by #629. Both halves used to be refused: `macro_rules! make_one
/// { … }` is itself a `syn::Item::Macro`, so the DEFINITION landed on the same
/// panic as the invocation. Expansion removes definitions from the item list
/// and replaces invocations with what they produce.
#[test]
fn a_local_item_level_macro_expands_into_real_declarations() {
    let program = encode(
        "macro_rules! make_one { ($f:ident) => { struct One { $f: i64 } }; }\n\
         make_one!(v);\n\
         fn main() { let o = One { v: 1 }; println!(\"{}\", o.v); }",
    );
    let main = module(&program, "main");
    assert_eq!(type_names(main), vec!["One".to_string()]);
    assert_eq!(field_names(main, "One"), vec!["v".to_string()]);
}

/// A definition is removed from the item list rather than left to reach the
/// unsupported-item panic — and a file that is NOTHING BUT a definition still
/// encodes.
#[test]
fn a_macro_rules_definition_alone_leaves_no_declaration_behind() {
    let program = encode_library("macro_rules! unused { () => { struct Never; }; }");
    let main = module(&program, "main");
    assert!(
        main.type_defs.is_empty() && main.functions.is_empty(),
        "a definition declares nothing Ball models: {main:?}"
    );
}

// ── The driver: fixed point, depth limit, nesting ────────────────────────────

/// Expansion must run to a FIXED POINT. One pass leaves an invocation a
/// transcriber produced still in place — `ball-lang-macro-expand`'s
/// `a_self_recursive_macro_is_not_fully_expanded_in_one_pass` pins that at the
/// engine level; this is the driver's half.
#[test]
fn expansion_runs_to_a_fixed_point() {
    let program = encode_library(
        "macro_rules! inner { ($n:ident) => { struct $n { a: i64 } }; }\n\
         macro_rules! outer { () => { inner!(Made); }; }\n\
         outer!();",
    );
    assert_eq!(
        type_names(module(&program, "main")),
        vec!["Made".to_string()]
    );
}

/// rustc's own default `recursion_limit` is 128 (the Rust Reference, *Limits*).
/// A macro that never stops expanding must hit that limit loudly, naming the
/// chain — never a partial expansion, and never a hang.
#[test]
#[should_panic(expected = "exceeded the recursion limit of 128")]
fn runaway_recursion_hits_the_depth_limit() {
    encode_library("macro_rules! forever { () => { forever!(); }; }\nforever!();");
}

/// 21 of `bitflags`' definitions live inside inline `mod` blocks, so the
/// collector has to descend into them.
#[test]
fn a_macro_defined_inside_an_inline_mod_is_in_scope_for_the_file() {
    let program = encode_library(
        "mod internal { macro_rules! shared { ($n:ident) => { struct $n { a: i64 } }; } }\n\
         shared!(FromInside);",
    );
    assert_eq!(
        type_names(module(&program, "main")),
        vec!["FromInside".to_string()]
    );
}

/// A macro invoked inside an `impl` block expands into impl items — the shape
/// `bitflags`' internal `__impl_public_bitflags*!` family has.
#[test]
fn a_macro_invoked_inside_an_impl_block_expands_into_methods() {
    let program = encode_library(
        "struct Holder { a: i64 }\n\
         macro_rules! accessors { () => { fn get(&self) -> i64 { self.a } }; }\n\
         impl Holder { accessors!(); }",
    );
    let main = module(&program, "main");
    assert_eq!(field_names(main, "Holder"), vec!["a".to_string()]);
    assert!(
        function_names(main)
            .iter()
            .any(|n| n.ends_with("Holder.get")),
        "the macro-produced method must be declared: {:?}",
        function_names(main)
    );
}

/// Statement position, for a locally defined macro.
#[test]
fn a_statement_position_local_macro_expands() {
    let program = encode(
        "macro_rules! shout { ($v:expr) => { println!(\"{}\", $v); }; }\n\
         fn main() { shout!(7); }",
    );
    let main = module(&program, "main");
    let body = main
        .functions
        .iter()
        .find(|f| f.name == "main")
        .and_then(|f| f.body.as_ref())
        .expect("`main` must have a body");
    let rendered = format!("{body:?}");
    assert!(
        rendered.contains("print"),
        "the expanded `println!` must have been lowered by the encoder: {rendered}"
    );
}

// ── What stays loud ──────────────────────────────────────────────────────────

/// A name no `macro_rules!` in scope defines — every proc-macro, `#[derive]`
/// helper and attribute macro — keeps the encoder's own loud refusal. That
/// boundary is deliberate: this crate expands DECLARATIVE macros and nothing
/// else.
#[test]
#[should_panic(expected = "unsupported top-level item")]
fn a_proc_macro_style_item_invocation_is_still_loud() {
    encode("some_derive_helper!();\nfn main() { println!(\"{}\", 1); }");
}

/// Statement position, for a name nothing defines: routed to the encoder's own
/// `encode_macro`, which is what keeps the builtin-macro gap (issue #630)
/// separately trackable.
#[test]
#[should_panic(expected = "unsupported macro invocation")]
fn an_unresolvable_statement_position_macro_is_loud() {
    encode("fn main() { shout!(1); }");
}

/// A DEPENDENCY-defined macro reached from a SINGLE-FILE encode is a named
/// failure, not a generic "unsupported item": there is no manifest to resolve
/// the dependency against, and saying so is the actionable diagnostic.
#[test]
#[should_panic(expected = "no crate manifest to resolve dependencies against")]
fn a_dependency_macro_in_single_file_mode_names_the_missing_manifest() {
    encode_library(&read_fixture("src/flags.rs"));
}

/// The same, from crate mode — the goalpost the dependency slice moves.
#[test]
#[should_panic(expected = "dependency crates were not consulted")]
fn the_macro_crate_fixture_still_needs_dependency_macros() {
    encode_crate(&macro_crate_dir());
}

// ── The fixture's golden ─────────────────────────────────────────────────────

/// The golden the round-trip diffs against, and the value an ordinary `cargo
/// run` of the fixture produces (verified: `42\n7\n`). Pinned so the golden
/// cannot drift silently ahead of the fixture.
#[test]
fn the_fixture_golden_matches_the_hand_computed_values() {
    // Point { x: 20, y: 22 }.total() == 0 + 20 + 22, and
    // Perms { bits: 4 }.sum_bits() == 4 + 1 + 2.
    let golden = std::fs::read(macro_crate_dir().join("expected_stdout.txt"))
        .expect("the fixture golden must exist");
    let golden = String::from_utf8(golden).expect("the golden must be UTF-8");
    assert_eq!(golden.replace("\r\n", "\n"), "42\n7\n");
}
