//! `ball run <program>` — load and execute a Ball program (issue #41).
use std::path::Path;

use crate::error::CliError;
use crate::loader::load_engine;

/// Load `path` and execute it via `ball-engine`, writing each captured
/// stdout line to the real process stdout.
///
/// **Self-host status:** without `ball-cli`'s `self_host` Cargo feature
/// (off by default — see `Cargo.toml`), `ball-engine`'s `run()` always
/// returns `EngineError::SelfHostPending`, which surfaces here as a
/// [`CliError::Runtime`] (exit `1`) — a program never silently "succeeds"
/// without actually running. Built with `--features self_host` (after
/// regenerating `rust/engine/src/compiled_engine.rs` — see
/// `rust/engine/AGENTS.md`), `run` executes the self-hosted engine for real;
/// as of this writing that engine handles simple acceptance programs
/// (`hello_world`, recursive `fibonacci`) — see `rust/engine/AGENTS.md`'s
/// "Self-host status" for exactly how far it currently reaches. Either way,
/// whatever the engine returns or errors is surfaced here faithfully, never
/// swallowed.
pub fn run(path: &Path) -> Result<(), CliError> {
    let engine = load_engine(path)?;
    let lines = engine.run()?;
    for line in lines {
        println!("{line}");
    }
    Ok(())
}
