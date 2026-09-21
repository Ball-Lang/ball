//! Extension-override dispatch (issue #670, fixture
//! `479_extension_override_selection`) — **emitted-source** assertions, so
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
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

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
            .join("479_extension_override_selection.ball.json"),
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

// ════════════════════════════════════════════════════════════
// Build + run — the half a shape assertion cannot see
// ════════════════════════════════════════════════════════════
//
// The first cut of this suite asserted the emitted CALL and stopped there, and
// it passed while the program did not compile at all: `compile_module_types`
// skipped every descriptor-less `TypeDefinition`, which is the shape an
// extension typeDef has, so neither the short-name dispatcher's arm nor the
// direct call had an `impl` to reach (`error[E0433]: cannot find module or
// crate `main_AlphaTag``). CI's `Rust Compiler Leg` found it; this test is what
// makes that finding local and permanent.

static FIXTURE_COUNTER: AtomicU64 = AtomicU64::new(0);

fn workspace_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("rust/compiler must have a parent directory")
        .to_path_buf()
}

/// Writes `rust_src` as the `main.rs` of a throwaway Cargo package depending on
/// `ball-lang-shared`, builds it, runs it and returns its stdout. Mirrors
/// `end_to_end.rs`'s harness, including the unique bin name that keeps
/// concurrently-running fixtures from clobbering each other's executable in the
/// shared `target/`.
fn build_and_run(fixture_name: &str, rust_src: &str) -> String {
    let workspace_root = workspace_root();
    let target_dir = workspace_root.join("target");
    let unique = FIXTURE_COUNTER.fetch_add(1, Ordering::Relaxed);
    let slug = format!("{fixture_name}_{}_{unique}", std::process::id());
    let fixture_dir = std::env::temp_dir().join(format!("ball_rustc_fixture_{slug}"));
    fs::create_dir_all(&fixture_dir).expect("failed to create fixture dir");

    let bin_name = format!("ball_fixture_{slug}");
    let manifest = format!(
        "[package]\nname = \"{bin_name}\"\nversion = \"0.0.0\"\nedition = \"2024\"\npublish = false\n\n\
         [[bin]]\nname = \"{bin_name}\"\npath = \"main.rs\"\n\n\
         [dependencies]\nball-lang-shared = {{ path = {:?} }}\n",
        workspace_root.join("shared")
    );
    fs::write(fixture_dir.join("Cargo.toml"), manifest).expect("write Cargo.toml");
    fs::write(fixture_dir.join("main.rs"), rust_src).expect("write main.rs");

    let build = Command::new("cargo")
        .args(["build", "--quiet"])
        .arg("--manifest-path")
        .arg(fixture_dir.join("Cargo.toml"))
        .arg("--target-dir")
        .arg(&target_dir)
        .output()
        .expect("failed to spawn `cargo build` — is cargo on PATH?");
    assert!(
        build.status.success(),
        "fixture '{fixture_name}' failed to COMPILE\n--- stderr ---\n{}",
        String::from_utf8_lossy(&build.stderr),
    );

    let exe = target_dir.join("debug").join(if cfg!(windows) {
        format!("{bin_name}.exe")
    } else {
        bin_name.clone()
    });
    let run = Command::new(&exe)
        .output()
        .expect("failed to run the built binary");
    let _ = fs::remove_dir_all(&fixture_dir);
    let _ = fs::remove_file(&exe);
    for sidecar in ["d", "pdb"] {
        let _ = fs::remove_file(
            target_dir
                .join("debug")
                .join(format!("{bin_name}.{sidecar}")),
        );
    }
    assert!(
        run.status.success(),
        "fixture '{fixture_name}' exited non-zero\n--- stderr ---\n{}",
        String::from_utf8_lossy(&run.stderr),
    );
    String::from_utf8_lossy(&run.stdout).replace("\r\n", "\n")
}

/// Reads a golden as BYTES, normalising only CRLF pairs (a lone `\r` can be
/// semantic).
fn golden(name: &str) -> String {
    let bytes = fs::read(repo_root().join("tests/conformance").join(name)).expect("read golden");
    String::from_utf8(bytes)
        .expect("golden is UTF-8")
        .replace("\r\n", "\n")
}

#[test]
fn the_compiled_program_selects_the_extension_the_source_named() {
    let source = Compiler::new(&load_program(
        &repo_root()
            .join("tests/conformance")
            .join("479_extension_override_selection.ball.json"),
    ))
    .compile();
    assert_eq!(
        build_and_run("479_extension_override_selection", &source),
        golden("479_extension_override_selection.expected_output.txt"),
    );
}
