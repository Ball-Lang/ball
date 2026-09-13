//! The declared text sink (issue #630) — **emitted-source** assertions on the
//! conformance fixture, so this suite runs on every PR as part of the default
//! `cargo test --workspace` (unlike `compiler_conformance.rs`, which is
//! `#[ignore]`d and shells out to cargo).
//!
//! Before #630 this compiler had NO sink at all: `grep -r __buffer__ rust/`
//! found nothing, so a Ball program using a `StringBuffer` — which every
//! self-hosted engine runs fine, because an engine's own sink is compiled
//! `engine_std.dart` rather than this compiler's base-call table — was refused
//! outright. The behavioural half of this contract is the conformance fixture
//! `465_string_sink`, whose `appendWord(out, 'c')` line is the one that fails
//! SILENTLY if the sink is backed by a by-value `String` instead of a shared
//! `BallMap` (precedent: issue #300's lost `BallList` appends). The
//! reference-semantics and `type_of` halves are pinned in
//! `ball-lang-shared`'s `sink_is_a_tagged_reference_value`.

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
fn the_sink_trio_compiles_to_the_runtime_helpers() {
    let source = compile_fixture("465_string_sink.ball.json");
    for want in [
        "ball_sink_create(",
        "ball_sink_write(",
        "ball_sink_to_string(",
    ] {
        assert!(
            source.contains(want),
            "emitted Rust missing {want}\n---\n{source}"
        );
    }
}
