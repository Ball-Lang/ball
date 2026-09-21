//! A `final` field a BODYLESS constructor's own initializer list assigns, next
//! to a user-written setter of the same name (issue #706, fixture
//! `472_initializer_list_field_with_setter`) — **emitted-source** assertions,
//! so this suite is part of the default `cargo test --workspace` and runs on
//! EVERY PR (unlike `compiler_conformance.rs`, which is `#[ignore]`d and shells
//! out to cargo, and unlike the whole-corpus `rust-compiler` leg, which lives
//! only in conformance-matrix.yml — a workflow with no `pull_request:` trigger
//! that RATCHETS an aggregate count rather than gating parity, so it was green
//! with this fixture failing and stays green now that it passes).
//!
//! ## The mechanism, measured
//!
//! `Compiler::unnamed_constructor_fn` (was `body_constructor_fn`) resolved a
//! class's UNNAMED constructor only when it carried a BODY, and
//! `compile_message_creation` invokes the constructor's associated fn only for
//! a class that resolves. A bodyless
//! `FixedSlice(this.source, int end) : windowSize = end;` therefore took the
//! inline-field-map path, which knows `metadata.params` (the `this.`-formals)
//! but NOT `metadata.initializers` — so the emitted instance carried the
//! constructor's plain parameter `end` as a bogus field and never carried
//! `windowSize` at all. `print(slice.windowSize)` then read a missing key and
//! printed `null`: a SILENT WRONG ANSWER, not a build failure.
//!
//! Note what the mechanism is NOT: issue #706 hypothesised that "the emitted
//! setter shadows the field read". It does not. Rust emits the setter as
//! `main_FixedSlice::windowSize(input)` and the read as
//! `ball_field_get(slice, "windowSize")` — two different namespaces that never
//! meet. Dropping the initializer list is the whole of it, and it bites every
//! bodyless constructor with an initializer list, setter or no setter.

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
    Compiler::new(&load_program(
        &repo_root().join("tests/conformance").join(name),
    ))
    .compile()
}

/// The field-READ pin: the fixture's `print(slice.windowSize)` must resolve to
/// the value the initializer list assigned, never a missing key.
#[test]
fn final_field_with_setter_is_seeded_by_its_initializer_list() {
    let source = compile_fixture("472_initializer_list_field_with_setter.ball.json");

    // The construction site must INVOKE the constructor's associated fn — the
    // only place the initializer list is applied — never build the instance
    // with an inline field map.
    assert!(
        source.contains("main_FixedSlice::new("),
        "construction does not invoke the constructor's associated fn\n---\n{source}"
    );
    // The initializer list's field must be seeded from the constructor's own
    // parameter.
    assert!(
        source.contains(r#"__ball_map.insert("windowSize".to_string(), end.clone())"#),
        "initializer list `windowSize = end` not applied\n---\n{source}"
    );
    // ...and the plain (non-`this.`) parameter must NOT be grafted on as an
    // instance field of its own.
    assert!(
        !source.contains(r#"__ball_map.insert("end".to_string(), BallValue::Int(3i64))"#),
        "constructor parameter `end` emitted as an instance field\n---\n{source}"
    );
}

/// The control: a constructor that DOES carry a body already applied its
/// initializer list (issue #527) and must keep doing so.
#[test]
fn body_carrying_constructor_initializer_list_is_still_applied() {
    let source = compile_fixture("438_ctor_initializer_list_with_body.ball.json");
    assert!(
        source.contains("\"pt\".to_string()"),
        "emitted Rust missing initializer value \"pt\"\n---\n{source}"
    );
}
