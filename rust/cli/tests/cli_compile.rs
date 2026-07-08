//! `ball compile` integration tests (issue #41).
mod common;

use std::path::PathBuf;
use std::process::Command;

use common::{ball, exit_code, repo_path, stderr, stdout, write_scratch_file};

#[test]
fn missing_file_exits_3() {
    let output = ball(&["compile", "does/not/exist.ball.json"]);
    assert_eq!(exit_code(&output), 3, "stderr: {}", stderr(&output));
}

#[test]
fn hello_world_compiles_to_rust_source_on_stdout() {
    let program = repo_path("examples/hello_world/hello_world.ball.json");
    let output = ball(&["compile", program.to_str().unwrap()]);

    assert_eq!(exit_code(&output), 0, "stderr: {}", stderr(&output));
    let src = stdout(&output);
    assert!(src.contains("fn main()"), "missing fn main() in:\n{src}");
    assert!(src.contains("Hello, World!"), "missing greeting in:\n{src}");
}

#[test]
fn compile_writes_to_an_output_file_instead_of_stdout() {
    let program = repo_path("examples/hello_world/hello_world.ball.json");
    let out_dir = std::env::temp_dir().join(format!(
        "ball_cli_test_compile_output_{}",
        std::process::id()
    ));
    std::fs::create_dir_all(&out_dir).unwrap();
    let out_path = out_dir.join("hello_world.rs");

    let output = ball(&[
        "compile",
        program.to_str().unwrap(),
        "--output",
        out_path.to_str().unwrap(),
    ]);

    assert_eq!(exit_code(&output), 0, "stderr: {}", stderr(&output));
    assert!(stdout(&output).is_empty(), "--output must suppress stdout");
    let written = std::fs::read_to_string(&out_path).expect("output file must exist");
    let _ = std::fs::remove_dir_all(&out_dir);
    assert!(written.contains("fn main()"));
}

/// A structurally-valid `Program` (decodes fine) whose `entryModule` names a
/// module that doesn't exist — `ball-compiler` `panic!`s on this rather than
/// silently emitting garbage; the CLI must convert that into exit `2`, not a
/// raw process abort.
#[test]
fn a_program_with_a_missing_entry_module_exits_2() {
    let json = r#"{
        "name": "broken", "version": "1.0.0",
        "entryModule": "does_not_exist", "entryFunction": "main",
        "modules": []
    }"#;
    let path = write_scratch_file("compile_missing_entry_module", "broken.ball.json", json);

    let output = ball(&["compile", path.to_str().unwrap()]);
    let _ = std::fs::remove_dir_all(path.parent().unwrap());

    assert_eq!(exit_code(&output), 2, "stderr: {}", stderr(&output));
    assert!(stderr(&output).contains("does_not_exist"));
}

// ════════════════════════════════════════════════════════════
// Strongest proof: the CLI's own `compile` output actually compiles and
// runs with the real Rust toolchain — the issue's "compilable for the core
// fixtures" acceptance criterion, exercised through the CLI binary (not
// just ball-compiler's own unit tests). Mirrors the harness in
// rust/compiler/tests/end_to_end.rs and rust/encoder/tests/end_to_end.rs.
// ════════════════════════════════════════════════════════════

fn workspace_root() -> PathBuf {
    // CARGO_MANIFEST_DIR = .../rust/cli; the workspace root is its parent.
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("rust/cli must have a parent directory")
        .to_path_buf()
}

/// Writes `rust_src` as the `main.rs` of a throwaway Cargo package
/// (depending on `ball-shared` via a path dependency), builds and runs it
/// with `cargo run`, and returns its captured stdout.
fn compile_and_run(fixture_name: &str, rust_src: &str) -> String {
    let workspace_root = workspace_root();
    let target_dir = workspace_root.join("target");
    let fixture_dir = std::env::temp_dir().join(format!(
        "ball_cli_rustc_fixture_{fixture_name}_{}",
        std::process::id()
    ));
    std::fs::create_dir_all(&fixture_dir).unwrap_or_else(|err| {
        panic!(
            "failed to create fixture dir {}: {err}",
            fixture_dir.display()
        )
    });

    let shared_path = workspace_root.join("shared");
    let manifest = format!(
        "[package]\nname = \"ball_cli_fixture_{fixture_name}\"\nversion = \"0.0.0\"\nedition = \"2024\"\npublish = false\n\n\
         [[bin]]\nname = \"fixture\"\npath = \"main.rs\"\n\n\
         [dependencies]\nball-shared = {{ path = {:?} }}\n",
        shared_path
    );
    std::fs::write(fixture_dir.join("Cargo.toml"), manifest)
        .expect("failed to write fixture Cargo.toml");
    std::fs::write(fixture_dir.join("main.rs"), rust_src).expect("failed to write fixture main.rs");

    let manifest_path = fixture_dir.join("Cargo.toml");
    let output = Command::new("cargo")
        .args(["run", "--quiet"])
        .arg("--manifest-path")
        .arg(&manifest_path)
        .arg("--target-dir")
        .arg(&target_dir)
        .output()
        .expect("failed to spawn `cargo run` — is cargo on PATH?");

    if !output.status.success() {
        panic!(
            "fixture '{fixture_name}' failed to compile/run.\n--- generated main.rs ---\n{rust_src}\n\
             --- stdout ---\n{}\n--- stderr ---\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }

    let _ = std::fs::remove_dir_all(&fixture_dir);
    String::from_utf8(output.stdout).expect("fixture stdout must be valid UTF-8")
}

#[test]
fn hello_world_compile_output_actually_compiles_and_runs() {
    let program = repo_path("examples/hello_world/hello_world.ball.json");
    let output = ball(&["compile", program.to_str().unwrap()]);
    assert_eq!(exit_code(&output), 0, "stderr: {}", stderr(&output));

    let run_stdout = compile_and_run("hello_world", &stdout(&output));
    assert_eq!(run_stdout.trim_end(), "Hello, World!");
}

#[test]
fn fibonacci_compile_output_actually_compiles_and_runs() {
    let program = repo_path("examples/fibonacci/fibonacci.ball.json");
    let output = ball(&["compile", program.to_str().unwrap()]);
    assert_eq!(exit_code(&output), 0, "stderr: {}", stderr(&output));

    let run_stdout = compile_and_run("fibonacci", &stdout(&output));
    assert_eq!(run_stdout.trim_end(), "55");
}
