//! Writing a subcommand's result to `--output <file>` or stdout (issue #41).
//! Shared by `compile` (Rust source, text) and `encode` (JSON text or binary
//! bytes).
use std::io::Write;
use std::path::Path;

use crate::error::CliError;

/// Write `content` to `output` if given, else to stdout (no trailing newline
/// added beyond what `content` already carries — `compile`'s Rust source and
/// `encode`'s JSON both already end in one).
pub fn write_text(output: Option<&Path>, content: &str) -> Result<(), CliError> {
    match output {
        Some(path) => std::fs::write(path, content)
            .map_err(|e| CliError::Io(format!("could not write {}: {e}", path.display()))),
        None => {
            print!("{content}");
            Ok(())
        }
    }
}

/// Write raw `content` bytes to `output` if given, else to stdout.
pub fn write_bytes(output: Option<&Path>, content: &[u8]) -> Result<(), CliError> {
    match output {
        Some(path) => std::fs::write(path, content)
            .map_err(|e| CliError::Io(format!("could not write {}: {e}", path.display()))),
        None => std::io::stdout()
            .write_all(content)
            .map_err(|e| CliError::Io(format!("could not write to stdout: {e}"))),
    }
}
