//! `ball tree <program>` — print a Ball program's module/import tree (issue
//! #365).
//!
//! Delegates to the self-hosted `cli_core` verb `treeReport` (compiled from
//! `dart/shared/lib/cli_core.dart` via `cargo run -p ball-cli-regen` — see
//! `rust/cli/AGENTS.md`), byte-identical to `dart/cli/lib/src/runner.dart`'s
//! `_tree`. Behind the `cli_core` Cargo feature — see `Cargo.toml`.
use std::path::Path;

use crate::error::CliError;
use crate::loader::load_engine;

#[cfg(feature = "cli_core")]
pub fn tree(path: &Path) -> Result<(), CliError> {
    let engine = load_engine(path)?;
    let report = crate::compiled_cli::treeReport(engine.program_value().clone());
    println!("{report}");
    Ok(())
}

#[cfg(not(feature = "cli_core"))]
pub fn tree(path: &Path) -> Result<(), CliError> {
    let _engine = load_engine(path)?;
    Err(CliError::Runtime(
        "`ball tree` needs the self-hosted cli-core, built in via `ball-cli`'s `cli_core` \
         Cargo feature (off by default — see rust/cli/Cargo.toml). Build with `--features \
         cli_core` after regenerating rust/cli/src/compiled_cli.rs (`cargo run -p \
         ball-cli-regen`, which itself needs `dart/self_host/cli.ball.json` — see \
         rust/cli/AGENTS.md)."
            .to_string(),
    ))
}
