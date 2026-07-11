//! `ball validate <program>` — check a Ball program's validity (issue #365).
//!
//! Delegates to the self-hosted `cli_core` verbs `validateOk`/`validateReport`
//! (compiled from `dart/shared/lib/cli_core.dart` via `cargo run -p
//! ball-cli-regen` — see `rust/cli/AGENTS.md`), byte-identical report text to
//! `dart/cli/lib/src/runner.dart`'s `_validate`. Behind the `cli_core` Cargo
//! feature — see `Cargo.toml`.
//!
//! **Exit code note:** the Dart CLI exits `1` on an invalid program (its
//! generic "command failed" code — Dart has no exit-code contract of its
//! own). `ball-lang-cli`'s own documented contract (`src/error.rs`) reserves `1`
//! for a *runtime* failure and `2` for an *invalid/unparseable program* — a
//! failed `ball validate` is squarely the latter, so this maps to
//! [`CliError::Parse`] (exit `2`) rather than mirroring Dart's `1`. Text
//! output still matches Dart exactly; only the numeric exit code is adapted
//! to the Rust target's own, pre-existing (issue #41) contract — the same
//! adaptation `src/commands/check.rs` already makes for structurally similar
//! findings.
use std::path::Path;

use crate::error::CliError;
use crate::loader::load_engine;

#[cfg(feature = "cli_core")]
pub fn validate(path: &Path) -> Result<(), CliError> {
    use ball_lang_shared::BallValue;

    let engine = load_engine(path)?;
    let program_value = engine.program_value().clone();
    let ok = crate::compiled_cli::validateOk(program_value.clone());
    let report = crate::compiled_cli::validateReport(program_value);
    if matches!(ok, BallValue::Bool(true)) {
        println!("{report}");
        Ok(())
    } else {
        Err(CliError::Parse(report.to_string()))
    }
}

#[cfg(not(feature = "cli_core"))]
pub fn validate(path: &Path) -> Result<(), CliError> {
    let _engine = load_engine(path)?;
    Err(CliError::Runtime(
        "`ball validate` needs the self-hosted cli-core, built in via `ball-lang-cli`'s `cli_core` \
         Cargo feature (off by default — see rust/cli/Cargo.toml). Build with `--features \
         cli_core` after regenerating rust/cli/src/compiled_cli.rs (`cargo run -p \
         ball-cli-regen`, which itself needs `dart/self_host/cli.ball.json` — see \
         rust/cli/AGENTS.md)."
            .to_string(),
    ))
}
