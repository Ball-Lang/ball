//! `ball compile <program>` — Ball -> Rust source (issue #41).
use std::path::Path;

use ball_lang_compiler::Compiler;

use crate::error::CliError;
use crate::loader::load_engine;
use crate::output::write_text;
use crate::panic_guard::catch_panic_message;

/// Load `path`, compile it via `ball-lang-compiler`, and write the emitted Rust
/// source to `output` (or stdout when `output` is `None`).
///
/// `Compiler::compile()` `panic!`s on a program shape it doesn't support
/// (a missing entry module/function, an unregistered base call, ...) rather
/// than silently degrading (see `rust/compiler/src/lib.rs`'s scope-boundary
/// doc comment) — [`catch_panic_message`] converts that into a
/// [`CliError::Parse`] (exit `2`) instead of aborting the process.
pub fn compile(path: &Path, output: Option<&Path>) -> Result<(), CliError> {
    let engine = load_engine(path)?;
    let program = engine.program();
    let rust_source = catch_panic_message(|| Compiler::new(program).compile())?;
    write_text(output, &rust_source)
}
