//! `ball info`/`validate`/`tree` golden-parity gate (issue #365) — the Rust
//! analog of `dart/cli/test/cli_core_parity_test.dart`.
//!
//! The Dart parity test can compare Dart-native `cli_core` output against the
//! *same process*'s Ball-engine-run `cli.ball.json` output in-process. Rust
//! has no such live comparison available at `cargo test` time: `cli_core` is
//! AOT-compiled into `src/compiled_cli.rs` (via `cargo run -p
//! ball-cli-regen`), not interpreted, and pulling in a `dart` toolchain just
//! to run the reference CLI during `cargo test` would make this suite
//! network/toolchain-dependent for no benefit. Instead this gate compares the
//! **built `ball` binary's** stdout against **golden files generated once
//! from the Dart CLI** and checked into `tests/golden/cli_core/` — proving
//! the compiled Rust functions produce byte-identical report text to the
//! reference implementation, without re-running Dart on every `cargo test`.
//!
//! ## Regenerating the goldens
//!
//! Only needed when `dart/shared/lib/cli_core.dart`'s report format changes
//! (a behavior change, not a routine regen — unlike `cli.ball.json`/
//! `compiled_cli.rs`, these golden `.txt` files are **checked into git**).
//! From the repo root, with a Dart SDK on `PATH`:
//!
//! ```bash
//! for f in 100_complex_control_flow 101_simple_class 111_cascade_operator \
//!          116_map_iteration 118_set_operations; do
//!   for verb in info validate tree; do
//!     dart run dart/cli/bin/ball.dart "$verb" "tests/conformance/$f.ball.json" \
//!       > "rust/cli/tests/golden/cli_core/$f.$verb.txt"
//!   done
//! done
//! ```
//!
//! `version` has no golden file — its entire logic is the one-line format
//! `"ball " + version` (see `dart/shared/lib/cli_core.dart`'s `versionLine`),
//! checked directly against the compiled function in
//! `src/commands/version.rs`'s unit tests (mirroring how
//! `cli_core_parity_test.dart` checks `versionReport` in-process rather than
//! via a golden fixture too).
mod common;

use common::{ball, exit_code, repo_path, stderr, stdout};

/// The same golden fixture set `dart/cli/test/cli_core_parity_test.dart`
/// exercises (`_goldenFixtures`) — a deliberately varied slice of the
/// conformance corpus (control flow, classes, collections, strings). Only
/// used by the `cli_core`-gated test below; the default-build test exercises
/// a single fixture (any valid program proves the honest-degradation path).
#[cfg(feature = "cli_core")]
const GOLDEN_FIXTURES: &[&str] = &[
    "100_complex_control_flow",
    "101_simple_class",
    "111_cascade_operator",
    "116_map_iteration",
    "118_set_operations",
];

const VERBS: &[&str] = &["info", "validate", "tree"];

#[cfg(feature = "cli_core")]
#[test]
fn every_golden_fixture_matches_every_verb() {
    for fixture in GOLDEN_FIXTURES {
        let program = repo_path(&format!("tests/conformance/{fixture}.ball.json"));
        for verb in VERBS {
            let golden_path = repo_path(&format!(
                "rust/cli/tests/golden/cli_core/{fixture}.{verb}.txt"
            ));
            let golden = std::fs::read_to_string(&golden_path)
                .unwrap_or_else(|e| panic!("failed to read golden {}: {e}", golden_path.display()));

            let output = ball(&[verb, program.to_str().unwrap()]);
            assert_eq!(
                exit_code(&output),
                0,
                "verb {verb:?} on fixture {fixture:?} should succeed; stderr: {}",
                stderr(&output)
            );
            assert_eq!(
                stdout(&output),
                golden,
                "verb {verb:?} diverged from the Dart CLI on fixture {fixture:?}"
            );
        }
    }
}

/// Without `cli_core`, `info`/`validate`/`tree` must degrade honestly (an
/// `EngineError::SelfHostPending`-style message, exit `1`, no stdout) rather
/// than silently succeeding with wrong/empty output — mirrors
/// `cli_run.rs::default_build_reports_self_host_pending_honestly_for_a_valid_program`.
#[cfg(not(feature = "cli_core"))]
#[test]
fn default_build_reports_cli_core_pending_honestly_for_every_verb() {
    let program = repo_path("tests/conformance/101_simple_class.ball.json");
    for verb in VERBS {
        let output = ball(&[verb, program.to_str().unwrap()]);
        assert_eq!(
            exit_code(&output),
            1,
            "verb {verb:?} stderr: {}",
            stderr(&output)
        );
        assert!(
            stdout(&output).is_empty(),
            "verb {verb:?} must never print output when cli_core isn't built in"
        );
        assert!(stderr(&output).contains("cli_core"));
    }
}

/// `ball validate` on a structurally invalid program prints the same
/// `Invalid: N error(s) found` report Dart's `_validate` prints to stderr —
/// but exits `2` (`CliError::Parse`), not Dart's generic `1`. See
/// `src/commands/validate.rs`'s doc comment for why the exit code is
/// deliberately adapted while the text is not.
#[cfg(feature = "cli_core")]
#[test]
fn validate_reports_invalid_program_to_stderr_and_exits_2() {
    let dir = std::env::temp_dir().join(format!(
        "ball_cli_test_validate_invalid_{}",
        std::process::id()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("invalid.ball.json");
    std::fs::write(
        &path,
        r#"{"@type":"type.googleapis.com/ball.v1.Program","name":"bad","version":"1.0.0","entryModule":"","entryFunction":"","modules":[]}"#,
    )
    .unwrap();

    let output = ball(&["validate", path.to_str().unwrap()]);
    let _ = std::fs::remove_dir_all(&dir);

    assert_eq!(exit_code(&output), 2);
    assert!(stdout(&output).is_empty());
    let err = stderr(&output);
    assert!(err.contains("Invalid: 2 error(s) found"), "{err}");
    assert!(err.contains("Missing entry_module"), "{err}");
    assert!(err.contains("Missing entry_function"), "{err}");
}
