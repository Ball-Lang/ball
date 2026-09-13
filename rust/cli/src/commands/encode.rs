//! `ball encode <source.rs>` — Rust -> Ball (issue #41).
use std::path::Path;

use clap::ValueEnum;

use crate::error::CliError;
use crate::output::{write_bytes, write_text};
use crate::panic_guard::catch_panic_message;
use crate::serialize::{program_to_binary, program_to_json};

/// Output format for `ball encode` (mirrors `dart/cli`'s `--format
/// json|binary`).
#[derive(Clone, Copy, Debug, ValueEnum)]
pub enum Format {
    /// Proto3 JSON, `@type`-enveloped (`.ball.json`) — human-readable, the
    /// default.
    Json,
    /// Raw protobuf binary (`.ball.bin`) — compact.
    Binary,
}

/// Read `path` as Rust source, encode it via `ball-lang-encoder`, and write the
/// resulting `ball.v1.Program` to `output` (or stdout) in `format`.
///
/// `ball_lang_encoder::encode` `panic!`s/`assert!`s on source it doesn't support
/// (no `fn main()`, an unsupported construct outside its documented Phase
/// 3a/3b scope — see `rust/encoder/src/lib.rs`'s module doc comment) —
/// [`catch_panic_message`] converts that into a [`CliError::Parse`] (exit
/// `2`) instead of aborting the process.
///
/// With `library` set (`ball encode --lib`, issue #491) the source is encoded
/// through `ball_lang_encoder::encode_library` instead: no `fn main()` is
/// required, and the emitted `Program` has an empty `entry_function`, so it is
/// deliberately not runnable (`ball check` reports "missing entry_function").
/// Every *other* documented-gap panic still surfaces as the same clean exit
/// `2` — the flag relaxes the entry-point requirement, nothing else.
///
/// With `crate_mode` set (`ball encode --crate`, issue #491) `path` is a crate
/// ROOT rather than one source file — the directory holding `Cargo.toml`, the
/// `src` directory, or the root `.rs` file. The crate's `mod` graph is walked
/// and every file encoded against one crate-wide symbol table, which is what
/// lets a `receiver.method(args)` whose method is declared in another file
/// resolve. The entry mode is then detected from the crate itself (a root
/// declaring `fn main` is runnable, a `lib.rs` without one is library mode);
/// `--lib` on top forces library mode. Reading the files is the walk's own job,
/// so a missing crate root surfaces through the same `catch_panic_message`
/// exit-`2` path as any other unsupported input.
pub fn encode(
    path: &Path,
    output: Option<&Path>,
    format: Format,
    library: bool,
    crate_mode: bool,
) -> Result<(), CliError> {
    let program = if crate_mode {
        let path = path.to_path_buf();
        catch_panic_message(move || {
            if library {
                ball_lang_encoder::encode_crate_library(&path)
            } else {
                ball_lang_encoder::encode_crate(&path)
            }
        })?
    } else {
        let source = std::fs::read_to_string(path)
            .map_err(|e| CliError::Io(format!("could not read {}: {e}", path.display())))?;
        catch_panic_message(move || {
            if library {
                ball_lang_encoder::encode_library(&source)
            } else {
                ball_lang_encoder::encode(&source)
            }
        })?
    };
    match format {
        Format::Json => write_text(output, &program_to_json(&program)?),
        Format::Binary => write_bytes(output, &program_to_binary(&program)),
    }
}
