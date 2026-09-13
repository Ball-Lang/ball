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
//! Every test here runs against `tests/fixtures/macro_crate` — a real,
//! hermetic two-crate fixture whose crate root invokes a LOCAL `macro_rules!`
//! at item position and whose `flags` module invokes a DEPENDENCY-defined,
//! `#[macro_export]`ed one reached through `cargo metadata`. Nothing in the
//! encoder knows the name `bitflags` (or `mini_bitflags`); the fixture is a
//! stand-in for the general mechanism, never a special case.
//!
//! ## Slice 0 — the goalposts, before any engine exists
//!
//! These start as `#[should_panic]` pins on **today's** loud refusal, so the
//! fixture and the boundary are both in CI before a line of expansion is
//! written. Each flips to a positive assertion in the slice that closes it,
//! in the same PR — the rule `documented_gaps.rs`' own module doc states.

use std::path::{Path, PathBuf};

use ball_lang_encoder::{encode, encode_crate};

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

// ── Slice 0 pins: the loud refusal, as it stands today ───────────────────────

/// A LOCAL `macro_rules!` at item position, in the smallest possible source.
///
/// Note *both* halves are refused today: `macro_rules! make_point { … }` is
/// itself a `syn::Item::Macro`, so the DEFINITION lands on the same panic as
/// the invocation. Expansion has to remove definitions from the item list as
/// well as replace invocations.
#[test]
#[should_panic(expected = "macro invocations at item level remain deferred")]
fn a_local_item_level_macro_is_a_documented_gap() {
    encode(
        "macro_rules! make_one { () => { struct One { v: i64 } }; }\n\
         make_one!();\n\
         fn main() { let _o = One { v: 1 }; }",
    );
}

/// The whole fixture crate, through the crate-aware entry point.
#[test]
#[should_panic(expected = "macro invocations at item level remain deferred")]
fn the_macro_crate_fixture_is_blocked_at_item_level() {
    encode_crate(&macro_crate_dir());
}

/// The DEPENDENCY-defined half, on its own: `flags.rs` invokes
/// `mini_bitflags::flags!` by a two-segment path.
#[test]
#[should_panic(expected = "macro invocations at item level remain deferred")]
fn a_dependency_defined_item_level_macro_is_a_documented_gap() {
    ball_lang_encoder::encode_library(&read_fixture("src/flags.rs"));
}

/// Statement position, for a name no `macro_rules!` in scope defines. This one
/// does not become an expansion — it becomes a *resolution* failure — so the
/// pin flips to the loud unresolved-macro message rather than to a positive
/// encode.
#[test]
#[should_panic(expected = "unsupported macro invocation")]
fn an_unresolvable_statement_position_macro_is_loud() {
    encode("fn main() { shout!(1); }");
}

/// The golden the slice-6 round-trip diffs against, and the value an ordinary
/// `cargo run` of the fixture produces (verified: `42\n7\n`). Pinned here from
/// slice 0 so the golden cannot drift silently ahead of the fixture.
#[test]
fn the_fixture_golden_matches_the_hand_computed_values() {
    // Point { x: 20, y: 22 }.total() == 0 + 20 + 22, and
    // Perms { bits: 4 }.sum_bits() == 4 + 1 + 2.
    let golden = std::fs::read(macro_crate_dir().join("expected_stdout.txt"))
        .expect("the fixture golden must exist");
    let golden = String::from_utf8(golden).expect("the golden must be UTF-8");
    assert_eq!(golden.replace("\r\n", "\n"), "42\n7\n");
}
