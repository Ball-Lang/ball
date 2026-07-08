//! Shared test harness for the CLI integration tests (issue #41): spawn the
//! actual **built** `ball` binary (`std::process::Command`, per the issue's
//! "invoke the built binary" instruction — no `assert_cmd` dependency
//! needed for this) and assert on its stdout/stderr/exit code.
//!
//! Not a standalone test binary itself: Cargo only treats a `.rs` file
//! **directly** under `tests/` as its own integration-test crate, so this
//! `tests/common/mod.rs` is only compiled when a real test file does `mod
//! common;` — each test *file* pulls in the whole module but only exercises
//! the subset of helpers it needs, so `dead_code` is expected per-binary
//! (never per-crate) and silenced here rather than by artificially using
//! every helper from every test file.
#![allow(dead_code)]

use std::path::PathBuf;
use std::process::{Command, Output};

/// The repo root — two levels up from `rust/cli` (this crate's manifest
/// dir): `rust/cli` -> `rust` -> the repo root.
pub fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(2)
        .expect("rust/cli must have a repo-root ancestor")
        .to_path_buf()
}

/// A path under the repo root, e.g. `repo_path("examples/hello_world/hello_world.ball.json")`.
pub fn repo_path(rel: &str) -> PathBuf {
    repo_root().join(rel)
}

/// Run the built `ball` binary (`CARGO_BIN_EXE_ball`, Cargo's own env var
/// pointing at the freshly-built binary for this crate's `[[bin]]`) with
/// `args`, returning its full output.
pub fn ball(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_ball"))
        .args(args)
        .output()
        .expect("failed to spawn the built `ball` binary")
}

pub fn stdout(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).into_owned()
}

pub fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

/// The process exit code. Panics if the process was killed by a signal
/// instead of exiting normally (never expected here).
pub fn exit_code(output: &Output) -> i32 {
    output
        .status
        .code()
        .expect("`ball` should exit with a code, not be killed by a signal")
}

/// Create a fresh scratch directory (under the OS temp dir, unique per test
/// name + PID) and write `content` to `filename` inside it. Returns the
/// directory (the caller is responsible for `fs::remove_dir_all`-ing it when
/// done — mirrors the cleanup style `rust/compiler/tests/end_to_end.rs` and
/// `rust/encoder/tests/end_to_end.rs` already use for their own fixture
/// dirs).
pub fn write_scratch_file(test_name: &str, filename: &str, content: &str) -> PathBuf {
    let dir =
        std::env::temp_dir().join(format!("ball_cli_test_{test_name}_{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("failed to create scratch dir");
    let path = dir.join(filename);
    std::fs::write(&path, content).expect("failed to write scratch file");
    path
}
