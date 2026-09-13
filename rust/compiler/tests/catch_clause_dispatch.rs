//! Typed `on <Type> catch` clause SELECTION (issue #615) — **emitted-source**
//! assertions, so this suite is part of the default `cargo test --workspace` and
//! runs on EVERY PR (unlike `compiler_conformance.rs`, which is `#[ignore]`d and
//! shells out to cargo). The whole-corpus `rust-compiler` leg in
//! conformance-matrix.yml has been a PR gate since #619, but it RATCHETS an
//! aggregate count (`RUST_COMPILER_FLOOR`) rather than gating parity: it was
//! green over `146_nested_try_catch_types` failing inside its floor from the day
//! that leg came online. A ratchet cannot name the failing fixture; this suite
//! fails for THIS shape.
//!
//! **The bug this file was written against.** `compile_try` compiled
//! `catches.first()` as an unconditional catch-all and dropped every later
//! clause, ignoring each clause's `type` field entirely (its own doc comment
//! recorded the gap). So `throw StateError('boom')` ran an
//! `on ArgumentError catch` body — silently wrong output, never an error — and a
//! `try` whose clauses ALL miss swallowed the exception instead of propagating
//! it to an enclosing `try`. The behavioural half of this contract is the
//! conformance fixture `464_typed_catch_clause_dispatch` (plus the pre-existing
//! `146_nested_try_catch_types`), which this target runs through
//! `compiler_conformance.rs`.

use std::fs;
use std::path::{Path, PathBuf};

use ball_lang_compiler::Compiler;
use ball_lang_shared::DESCRIPTOR_POOL;
use ball_lang_shared::proto::ball::v1::Program;
use prost::Message;
use prost_reflect::DynamicMessage;

fn repo_root() -> PathBuf {
    let mut dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    loop {
        if dir.join("proto/ball/v1/ball.proto").is_file() {
            return dir;
        }
        assert!(dir.pop(), "repo root not found");
    }
}

fn load_program(path: &Path) -> Program {
    let json = fs::read_to_string(path)
        .unwrap_or_else(|err| panic!("failed to read {}: {err}", path.display()));
    let mut json_value: serde_json::Value =
        serde_json::from_str(&json).expect(".ball.json must be valid JSON");
    if let serde_json::Value::Object(map) = &mut json_value {
        map.remove("@type");
    }
    let descriptor = DESCRIPTOR_POOL
        .get_message_by_name("ball.v1.Program")
        .expect("ball.v1.Program must resolve");
    let dynamic = DynamicMessage::deserialize(descriptor, json_value)
        .unwrap_or_else(|err| panic!("{} is not a ball.v1.Program: {err}", path.display()));
    Program::decode(dynamic.encode_to_vec().as_slice()).expect("typed decode")
}

fn compile_fixture(name: &str) -> String {
    let path = repo_root().join("tests/conformance").join(name);
    Compiler::new(&load_program(&path)).compile()
}

#[test]
fn every_typed_clause_is_emitted_with_its_own_type_guard() {
    let source = compile_fixture("464_typed_catch_clause_dispatch.ball.json");
    for want in [
        r#"ball_catch_matches(&__err, "ArgumentError")"#,
        r#"ball_catch_matches(&__err, "StateError")"#,
        r#"ball_catch_matches(&__err, "FormatException")"#,
    ] {
        assert!(
            source.contains(want),
            "emitted Rust missing clause guard {want}\n---\n{source}"
        );
    }
    // A `try` whose clauses are ALL typed must re-raise when none matches,
    // never swallow the exception (the fixture's case 3 depends on it).
    assert!(
        source.contains("ball_throw(__err)"),
        "no unmatched-clause re-raise in emitted Rust\n---\n{source}"
    );
}

/// The pre-existing nested-try fixture exercises the same dispatch plus a
/// `rethrow` out to an OUTER clause list. It was silently wrong on this target
/// from the day the Rust compiler came online (every level printed
/// `FormatException - null`) and nothing PR-gated noticed.
#[test]
fn nested_try_dispatches_each_clause_list_by_type() {
    let source = compile_fixture("146_nested_try_catch_types.ball.json");
    for want in [
        r#"ball_catch_matches(&__err, "FormatException")"#,
        r#"ball_catch_matches(&__err, "RangeError")"#,
        r#"ball_catch_matches(&__err, "StateError")"#,
    ] {
        assert!(
            source.contains(want),
            "emitted Rust missing clause guard {want}\n---\n{source}"
        );
    }
    // `rethrow` still re-raises the ORIGINALLY caught value, not the clause's
    // (possibly reassigned) variable.
    assert!(
        source.contains("_ball_rethrow_err"),
        "rethrow target missing from emitted Rust\n---\n{source}"
    );
}
