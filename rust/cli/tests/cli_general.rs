//! Top-level CLI behavior (issue #41): `--help`, `--version`, and clap's own
//! usage-error handling for a missing/unknown subcommand.
mod common;

use common::{ball, exit_code, stdout};

#[test]
fn help_lists_every_subcommand_and_exits_0() {
    let output = ball(&["--help"]);
    assert_eq!(exit_code(&output), 0);
    let text = stdout(&output);
    for subcommand in ["run", "compile", "encode", "check"] {
        assert!(
            text.contains(subcommand),
            "--help missing '{subcommand}':\n{text}"
        );
    }
}

#[test]
fn version_prints_the_crate_version_and_exits_0() {
    let output = ball(&["--version"]);
    assert_eq!(exit_code(&output), 0);
    assert!(stdout(&output).contains(env!("CARGO_PKG_VERSION")));
}

#[test]
fn no_arguments_is_a_clap_usage_error() {
    let output = ball(&[]);
    assert_ne!(exit_code(&output), 0);
}

#[test]
fn unknown_subcommand_is_a_clap_usage_error() {
    let output = ball(&["frobnicate"]);
    assert_ne!(exit_code(&output), 0);
}
