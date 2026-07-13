//! `ball audit <program>` — capability + termination report (issue #365).
//!
//! Delegates to the self-hosted `cli_core` verb `auditReport` (compiled from
//! `dart/shared/lib/cli_core.dart` via `cargo run -p ball-cli-regen` — see
//! `rust/cli/AGENTS.md`), byte-identical to the fast path of
//! `dart/cli/lib/src/runner.dart`'s `_audit` (a bare `ball audit <program>`
//! with default options, which calls the same `cli_core.auditReport`). Behind
//! the `cli_core` Cargo feature — see `Cargo.toml`.
//!
//! Scope: only the bare report is ported — the Dart CLI's `--deny`/
//! `--exit-code`/`--reachable-only`/`--output` policy flags are native-only
//! extras (see `_audit`), out of scope for the cli-core parity surface, which
//! matches what the Dart/TS parity gates check. Printing the report always
//! exits `0`.
//!
//! Newline note: `auditReport` already ends in a trailing `\n` (unlike
//! `infoReport`/`validateReport`/`treeReport`), so this uses `print!` — not
//! `println!` — to stay byte-identical to the Dart CLI, whose `_audit` fast
//! path likewise uses `out.write` (not `writeln`).
use std::path::Path;

use crate::error::CliError;
use crate::loader::load_engine;

#[cfg(feature = "cli_core")]
pub fn audit(path: &Path) -> Result<(), CliError> {
    let engine = load_engine(path)?;
    let report = crate::compiled_cli::auditReport(engine.program_value().clone());
    print!("{report}");
    Ok(())
}

#[cfg(not(feature = "cli_core"))]
pub fn audit(path: &Path) -> Result<(), CliError> {
    // Loading still validates the input honestly (a missing/malformed file
    // reports its own `Io`/`Parse` error) before surfacing the feature gap —
    // mirrors `info`'s pattern in `src/commands/info.rs`.
    let _engine = load_engine(path)?;
    Err(CliError::Runtime(
        "`ball audit` needs the self-hosted cli-core, built in via `ball-lang-cli`'s `cli_core` \
         Cargo feature (off by default — see rust/cli/Cargo.toml). Build with `--features \
         cli_core` after regenerating rust/cli/src/compiled_cli.rs (`cargo run -p \
         ball-cli-regen`, which itself needs `dart/self_host/cli.ball.json` — see \
         rust/cli/AGENTS.md)."
            .to_string(),
    ))
}
