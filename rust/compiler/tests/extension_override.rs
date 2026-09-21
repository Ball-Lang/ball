//! Extension-override dispatch (issue #670, fixture
//! `478_extension_override_selection`) — **emitted-source** assertions, so
//! this suite is part of the default `cargo test --workspace` and runs on
//! EVERY PR (unlike the whole-corpus `rust-compiler` leg, which lives only in
//! conformance-matrix.yml — a workflow with no `pull_request:` trigger that
//! RATCHETS an aggregate count rather than gating parity, so it was green with
//! this fixture failing).
//!
//! `Ext(receiver).member` is encoded as a call NAMING the extension's own
//! member (`<module>:<Ext>.<member>`) with the receiver in `self`, because the
//! selection is the whole meaning of the node: two extensions can declare the
//! SAME member on the SAME type, and the plain `receiver.member` emission
//! resolves by ordinary lookup — a DIFFERENT member.
//!
//! Rust emits each extension member as an associated fn (`main_AlphaTag::tag`)
//! plus a short-named DISPATCHER (`tag`) that matches on the RECEIVER's
//! message type. An extension receiver is an ordinary list, so that dispatcher
//! can never pick between the two — and the qualified name sanitized to
//! `main_AlphaTag_tag`, an item no emitted program declares, so the generic
//! path produced Rust that does not compile.

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

#[test]
fn extension_override_calls_the_named_associated_fn() {
    let source = Compiler::new(&load_program(
        &repo_root()
            .join("tests/conformance")
            .join("478_extension_override_selection.ball.json"),
    ))
    .compile();

    // Each of the six overrides must reach the extension's own associated fn.
    for call in [
        "main_AlphaTag::tag(",
        "main_BetaTag::tag(",
        "main_AlphaTag::label(",
        "main_BetaTag::label(",
        "main_AlphaTag::scale(",
        "main_BetaTag::scale(",
    ] {
        assert!(
            source.contains(call),
            "emitted Rust never calls {call}\n---\n{source}"
        );
    }

    // ...and none may fall to the sanitized flat name, which no item declares.
    for dangling in ["main_AlphaTag_tag(", "main_BetaTag_tag("] {
        assert!(
            !source.contains(dangling),
            "emitted Rust names the undeclared item {dangling}\n---\n{source}"
        );
    }
}
