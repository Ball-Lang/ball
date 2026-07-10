//! `ball info <program>` — inspect a Ball program's structure (issue #365).
//!
//! Delegates to the self-hosted `cli_core` verb `infoReport` (compiled from
//! `dart/shared/lib/cli_core.dart` via `cargo run -p ball-cli-regen` — see
//! `rust/cli/AGENTS.md`), byte-identical to `dart/cli/lib/src/runner.dart`'s
//! `_info` (which calls the same `cli_core.infoReport`). Behind the `cli_core`
//! Cargo feature — see `Cargo.toml`.
use std::path::Path;

use crate::error::CliError;
use crate::loader::load_engine;

#[cfg(feature = "cli_core")]
pub fn info(path: &Path) -> Result<(), CliError> {
    let engine = load_engine(path)?;
    let report = crate::compiled_cli::infoReport(engine.program_value().clone());
    println!("{report}");
    Ok(())
}

#[cfg(not(feature = "cli_core"))]
pub fn info(path: &Path) -> Result<(), CliError> {
    // Loading still validates the input honestly (a missing/malformed file
    // reports its own `Io`/`Parse` error) before surfacing the feature gap —
    // mirrors `run`'s `EngineError::SelfHostPending` pattern in
    // `src/commands/run.rs`.
    let _engine = load_engine(path)?;
    Err(CliError::Runtime(
        "`ball info` needs the self-hosted cli-core, built in via `ball-cli`'s `cli_core` \
         Cargo feature (off by default — see rust/cli/Cargo.toml). Build with `--features \
         cli_core` after regenerating rust/cli/src/compiled_cli.rs (`cargo run -p \
         ball-cli-regen`, which itself needs `dart/self_host/cli.ball.json` — see \
         rust/cli/AGENTS.md)."
            .to_string(),
    ))
}
