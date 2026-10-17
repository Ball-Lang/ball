//! `value as T` (the cast EXPRESSION) is an unchecked identity on every
//! target but Rust used to be — Rust's compiled `ball_as` PANICKED on a
//! mismatch, an uncatchable process abort (issue #707). **Emitted-and-RUN**
//! assertion, part of the default `cargo test --workspace` (unlike the
//! whole-corpus `rust-compiler` leg in `conformance-matrix.yml`, which
//! RATCHETS rather than gating every fixture individually).
//!
//! Fixture `481_as_expression_identity` is the cross-target conformance
//! guard; this is the Rust-only HARD gate, since Rust cannot be built/tested
//! in this repo's local dev loop — only CI runs it. See
//! `tools/check_std_as_contract.py` for the structural half (every target's
//! `std.as` implementation, read as source) and
//! `docs/TESTING_STRATEGY.md` §5b for the contract this pins.

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
/// output on any failure. Duplicated from the sibling suites in this
/// directory (no shared `tests/common` module exists here).
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

/// RED before the fix: `5 as String`/`3.5 as String` made the compiled
/// `ball_as` PANIC — an uncatchable process abort, not even a thrown value a
/// Ball `try` could see — so the binary exited non-zero instead of printing
/// `ok:5`/`ok:3.5` like every other engine/compiler already does.
#[test]
fn as_expression_on_a_mismatched_runtime_type_never_panics() {
    let compiled = compile_fixture("481_as_expression_identity.ball.json");
    let stdout = compile_and_run("as_expression_identity", &compiled);
    assert_eq!(
        stdout, "ok:hello\nok:5\nok:3.5\n",
        "`value as T` must be an unchecked identity: a mismatched runtime type must print \
         through exactly like Dart's own checked cast does once caught, never abort the process"
    );
}
