//! Loading a `.ball.json`/`.ball.bin` program for every subcommand (issue
//! #41).
//!
//! Reuses `ball-lang-engine`'s own loader (`BallEngine::from_json`/`from_binary`,
//! backed by `rust/engine/src/loader.rs`'s prost-reflect proto3-JSON<->binary
//! round trip) rather than re-implementing program parsing here — the same
//! codec every subcommand (`run`, `compile`, `check`) needs, and the one the
//! issue explicitly calls out ("the loader in ball-lang-engine handles both —
//! reuse it").
//!
//! Format is sniffed by extension: a path ending in `.bin` is read as raw
//! bytes and decoded as binary protobuf; anything else (`.ball.json`, `.json`,
//! or no extension at all) is read as UTF-8 text and decoded as proto3 JSON
//! (the `@type` Any envelope, if present, is stripped by the engine loader).
//! This mirrors `dart/cli/lib/src/runner.dart`'s `_loadBallFile`
//! (`path.endsWith('.bin')`) and the Dart/TS engines' own format convention.
use std::path::Path;

use ball_lang_engine::BallEngine;

use crate::error::CliError;

/// Load a target `Program` (wrapped in its [`BallEngine`], which the `run`
/// subcommand needs directly and `compile`/`check` read `.program()` off of)
/// from `path`. I/O failures (missing file, permission error, ...) become
/// [`CliError::Io`] (exit `3`); a malformed/undecodable program becomes
/// [`CliError::Parse`] (exit `2`) — see the module doc comment for the
/// format-sniffing rule.
pub fn load_engine(path: &Path) -> Result<BallEngine, CliError> {
    let is_binary = path.extension().and_then(|ext| ext.to_str()) == Some("bin");
    if is_binary {
        let bytes = std::fs::read(path)
            .map_err(|e| CliError::Io(format!("could not read {}: {e}", path.display())))?;
        BallEngine::from_binary(&bytes).map_err(CliError::from)
    } else {
        let text = std::fs::read_to_string(path)
            .map_err(|e| CliError::Io(format!("could not read {}: {e}", path.display())))?;
        BallEngine::from_json(&text).map_err(CliError::from)
    }
}
