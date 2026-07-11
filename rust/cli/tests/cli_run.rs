//! `ball run` integration tests (issue #41) — exercised against the real
//! built `ball` binary, asserting the documented exit-code contract:
//! `0` success, `1` runtime error, `2` invalid/unparseable program, `3`
//! file-not-found/IO error.
mod common;

use common::{ball, exit_code, repo_path, stderr, stdout, write_scratch_file};

#[test]
fn missing_file_exits_3() {
    let output = ball(&["run", "does/not/exist.ball.json"]);
    assert_eq!(exit_code(&output), 3, "stderr: {}", stderr(&output));
    assert!(stderr(&output).starts_with("ball:"));
    assert!(stdout(&output).is_empty());
}

#[test]
fn malformed_json_exits_2() {
    let path = write_scratch_file(
        "run_malformed_json",
        "bad.ball.json",
        "{ this is not valid json",
    );
    let output = ball(&["run", path.to_str().unwrap()]);
    let _ = std::fs::remove_dir_all(path.parent().unwrap());

    assert_eq!(exit_code(&output), 2, "stderr: {}", stderr(&output));
    assert!(stdout(&output).is_empty());
}

#[test]
fn malformed_binary_exits_2() {
    let dir = std::env::temp_dir().join(format!(
        "ball_cli_test_run_malformed_binary_{}",
        std::process::id()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("bad.ball.bin");
    std::fs::write(&path, [0xFFu8, 0x00, 0xDE, 0xAD]).unwrap();

    let output = ball(&["run", path.to_str().unwrap()]);
    let _ = std::fs::remove_dir_all(&dir);

    assert_eq!(exit_code(&output), 2, "stderr: {}", stderr(&output));
}

/// `hello_world.ball.json` is a **structurally valid** program. Without
/// `ball-lang-cli`'s `self_host` Cargo feature (the default build — see
/// `Cargo.toml`), `ball-lang-engine::run()` always reports
/// `EngineError::SelfHostPending`: this must surface as an honest runtime
/// error (exit `1`), never a false "success" with empty/wrong output. See
/// `self_host_hello_world_prints_greeting` below for the real, feature-gated
/// execution path.
#[cfg(not(feature = "self_host"))]
#[test]
fn default_build_reports_self_host_pending_honestly_for_a_valid_program() {
    let program = repo_path("examples/hello_world/hello_world.ball.json");
    let output = ball(&["run", program.to_str().unwrap()]);

    assert_eq!(exit_code(&output), 1, "stderr: {}", stderr(&output));
    assert!(
        stdout(&output).is_empty(),
        "must never print output for a program that didn't actually run"
    );
    assert!(stderr(&output).contains("ball:"));
}

/// Real execution proof (issue #41's acceptance criterion), gated behind
/// `--features self_host` (requires `rust/engine/src/compiled_engine.rs` to
/// have been regenerated first — see `rust/engine/AGENTS.md`). Mirrors
/// `rust/engine/tests/self_host_run.rs::hello_world_prints_greeting`, but
/// through the actual CLI binary rather than the `ball-lang-engine` API directly.
#[cfg(feature = "self_host")]
#[test]
fn self_host_hello_world_prints_greeting() {
    let program = repo_path("examples/hello_world/hello_world.ball.json");
    let output = ball(&["run", program.to_str().unwrap()]);

    assert_eq!(exit_code(&output), 0, "stderr: {}", stderr(&output));
    assert_eq!(stdout(&output), "Hello, World!\n");
}

/// Mirrors `rust/engine/tests/self_host_run.rs::fibonacci_recursion_matches_dart`.
#[cfg(feature = "self_host")]
#[test]
fn self_host_fibonacci_recursion_matches_dart() {
    let program = repo_path("examples/fibonacci/fibonacci.ball.json");
    let output = ball(&["run", program.to_str().unwrap()]);

    assert_eq!(exit_code(&output), 0, "stderr: {}", stderr(&output));
    assert_eq!(stdout(&output), "55\n");
}
