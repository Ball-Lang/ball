//! A mutation of a local CAPTURED by an immediately-invoked `std.invoke`
//! lambda must be visible to the caller once the call returns (issue #734) —
//! **emitted-and-RUN** assertions, so this suite is part of the default
//! `cargo test --workspace` and runs on EVERY PR (unlike the whole-corpus
//! `rust-compiler`/`rust-roundtrip` legs, which live only in
//! `conformance-matrix.yml` — a workflow with no `pull_request:` trigger that
//! RATCHETS an aggregate count rather than gating every individual fixture,
//! so adding fixture 480 there alone would not have made this defect loud).
//!
//! ## The mechanism, measured
//!
//! `Compiler::compile_lambda` pre-clones every local a `lambda` captures into
//! the `move` closure's own copy, to dodge a Rust `error[E0382]` when the
//! same local is captured by more than one closure in the compiled output —
//! correct for a function VALUE that might be stored and invoked more than
//! once, but it means a captured local the body MUTATES only ever mutates
//! that PRIVATE copy: the caller's own binding never observes the write.
//! `std.invoke(lambda{callee: <literal, zero-argument lambda>})` — the shape
//! `dart/encoder`'s `FunctionExpressionInvocation` arm emits for EVERY
//! immediately-invoked anonymous Dart function, early-exiting or not — never
//! stores or re-invokes that lambda, so nothing could ever observe a
//! pre-clone's staleness; `Compiler::compile_inline_lambda_invoke` now
//! inlines this one narrow, safe shape into a plain (non-`move`) closure
//! called exactly once, right there, which captures by reference instead of
//! by value and therefore mutates the SAME binding the caller reads
//! afterward — matching the Dart reference engine's own shared-scope
//! `_evalLambda` semantics.
//!
//! Fixture `480_iife_mutates_captured_local` is the cross-target conformance
//! guard; this is the Rust-only HARD gate TDD asked for, since Rust cannot be
//! built/tested in this repo's local dev loop — only CI runs it.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};

use ball_lang_compiler::Compiler;
use ball_lang_shared::DESCRIPTOR_POOL;
use ball_lang_shared::proto::ball::v1::Program;
use prost::Message;
use prost_reflect::DynamicMessage;

static FIXTURE_COUNTER: AtomicUsize = AtomicUsize::new(0);

fn repo_root() -> PathBuf {
    let mut dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    loop {
        if dir.join("proto/ball/v1/ball.proto").is_file() {
            return dir;
        }
        assert!(dir.pop(), "repo root not found");
    }
}

fn workspace_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("rust/compiler must have a parent directory")
        .to_path_buf()
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

/// Build `rust_src` as a scratch Cargo binary (depending on `ball-lang-shared`
/// via a path dependency) and run it, panicking with the full build/run
/// output on any failure. Mirrors `end_to_end.rs`'s `compile_and_run` —
/// duplicated rather than shared, matching this suite's existing per-file
/// convention (no `tests/common` module exists here).
fn compile_and_run(fixture_name: &str, rust_src: &str) -> String {
    let workspace_root = workspace_root();
    let target_dir = workspace_root.join("target");
    let unique = FIXTURE_COUNTER.fetch_add(1, Ordering::Relaxed);
    let slug = format!("{fixture_name}_{}_{unique}", std::process::id());
    let fixture_dir = std::env::temp_dir().join(format!("ball_rustc_fixture_{slug}"));
    fs::create_dir_all(&fixture_dir).unwrap_or_else(|err| {
        panic!(
            "failed to create fixture dir {}: {err}",
            fixture_dir.display()
        )
    });

    let shared_path = workspace_root.join("shared");
    let bin_name = format!("ball_fixture_{slug}");
    let manifest = format!(
        "[package]\nname = \"{bin_name}\"\nversion = \"0.0.0\"\nedition = \"2024\"\npublish = false\n\n\
         [[bin]]\nname = \"{bin_name}\"\npath = \"main.rs\"\n\n\
         [dependencies]\nball-lang-shared = {{ path = {shared_path:?} }}\n",
    );
    fs::write(fixture_dir.join("Cargo.toml"), manifest)
        .expect("failed to write fixture Cargo.toml");
    fs::write(fixture_dir.join("main.rs"), rust_src).expect("failed to write fixture main.rs");

    let manifest_path = fixture_dir.join("Cargo.toml");
    let build = Command::new("cargo")
        .args(["build", "--quiet"])
        .arg("--manifest-path")
        .arg(&manifest_path)
        .arg("--target-dir")
        .arg(&target_dir)
        .output()
        .expect("failed to spawn `cargo build` — is cargo on PATH?");
    if !build.status.success() {
        let _ = fs::remove_dir_all(&fixture_dir);
        panic!(
            "fixture '{fixture_name}' failed to COMPILE.\n--- generated main.rs ---\n{rust_src}\n\
             --- stdout ---\n{}\n--- stderr ---\n{}",
            String::from_utf8_lossy(&build.stdout),
            String::from_utf8_lossy(&build.stderr),
        );
    }

    let exe = target_dir.join("debug").join(if cfg!(windows) {
        format!("{bin_name}.exe")
    } else {
        bin_name.clone()
    });
    let output = Command::new(&exe).output().unwrap_or_else(|err| {
        panic!(
            "fixture '{fixture_name}' built but its binary {} could not be run: {err}",
            exe.display()
        )
    });

    let _ = fs::remove_dir_all(&fixture_dir);
    let _ = fs::remove_file(&exe);
    for sidecar in ["d", "pdb"] {
        let _ = fs::remove_file(
            target_dir
                .join("debug")
                .join(format!("{bin_name}.{sidecar}")),
        );
    }

    if !output.status.success() {
        panic!(
            "fixture '{fixture_name}' failed to run.\n--- generated main.rs ---\n{rust_src}\n\
             --- stdout ---\n{}\n--- stderr ---\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }

    String::from_utf8(output.stdout).expect("fixture stdout must be valid UTF-8")
}

/// RED before the fix: the compiled `counter`/`total` locals were pre-cloned
/// into each `move` closure's own copy, so `earlyExitMutation` printed `10`
/// (the result alone, `counter` still reading its PRE-INVOKE `0`) and
/// `completionMutation` printed `0` (the mutation lost entirely) — never
/// `11`/`7`, the Dart-golden values every other engine/compiler already
/// computes.
#[test]
fn captured_local_mutation_through_immediate_invoke_is_visible_to_the_caller() {
    let compiled = compile_fixture("480_iife_mutates_captured_local.ball.json");
    assert!(
        compiled.contains("(|input: BallValue| -> BallValue {"),
        "this test is only meaningful while the immediately-invoked zero-argument lambda \
         compiles through the inlining path (a bare closure call, no `move`) rather than \
         `compile_lambda`'s `move |input: BallValue| -> BallValue {{` — if that changed, \
         re-measure #734 and update this test:\n{compiled}"
    );
    let stdout = compile_and_run("captured_local_mutation", &compiled);
    assert_eq!(
        stdout, "11\n7\n",
        "a mutation performed inside an immediately-invoked lambda must be visible to the \
         caller once the call returns, whether the lambda exits early or runs to completion"
    );
}
