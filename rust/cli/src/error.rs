//! The CLI's error type and exit-code contract (issue #41).
//!
//! Every subcommand returns `Result<(), CliError>`; `main` prints the error
//! to stderr (prefixed `ball: `) and exits with [`CliError::exit_code`].
//! Three buckets, matching the issue's documented contract exactly:
//! - [`CliError::Io`] (exit `3`) — the input file could not be found or
//!   read, or an output path could not be written. Covers both
//!   "file-not-found" and general I/O failure, per the issue (they share one
//!   bucket).
//! - [`CliError::Parse`] (exit `2`) — the input was not a valid
//!   `ball.v1.Program` (bad JSON/binary shape) or, for `encode`, not
//!   encodable Rust source; or a loaded `Program` was too malformed to
//!   compile (an `assert!`/`panic!` in `ball-lang-compiler`/`ball-lang-encoder`,
//!   caught via [`crate::panic_guard::catch_panic_message`] rather than
//!   letting it abort the process with an unrelated exit code).
//! - [`CliError::Runtime`] (exit `1`) — a Ball program executed but failed
//!   (a `throw` that escaped `main`, or the self-hosted engine reporting
//!   `EngineError::SelfHostPending`/`EngineError::Runtime`).
//!
//! `0` (success) is never represented here — it is simply the absence of an
//! `Err`.
use std::fmt;

use ball_lang_engine::EngineError;

/// A CLI-level failure, carrying its own exit code (see the module doc
/// comment for the three buckets and their exact codes).
#[derive(Debug)]
pub enum CliError {
    /// File-not-found or another I/O failure reading input / writing
    /// output. Exit code `3`.
    Io(String),
    /// The input could not be parsed/encoded into a valid `ball.v1.Program`
    /// (or was too malformed to compile). Exit code `2`.
    Parse(String),
    /// A loaded program ran but failed at run time. Exit code `1`.
    Runtime(String),
}

impl CliError {
    /// The process exit code for this failure — the issue #41 contract:
    /// `1` runtime error, `2` invalid/unparseable program, `3`
    /// file-not-found/IO error.
    pub fn exit_code(&self) -> i32 {
        match self {
            CliError::Runtime(_) => 1,
            CliError::Parse(_) => 2,
            CliError::Io(_) => 3,
        }
    }
}

impl fmt::Display for CliError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CliError::Io(msg) => write!(f, "{msg}"),
            CliError::Parse(msg) => write!(f, "{msg}"),
            CliError::Runtime(msg) => write!(f, "{msg}"),
        }
    }
}

impl std::error::Error for CliError {}

/// `ball-lang-engine`'s own [`EngineError`] maps directly onto two of our three
/// buckets: a load-time shape failure is a [`CliError::Parse`]; a run-time
/// failure (including the self-hosted engine not being built in, see
/// `ball-lang-cli`'s `self_host` Cargo feature) is a [`CliError::Runtime`] — never
/// silently swallowed, always surfaced with `EngineError`'s own message.
impl From<EngineError> for CliError {
    fn from(err: EngineError) -> Self {
        match err {
            EngineError::Parse(msg) => CliError::Parse(format!("parse error: {msg}")),
            EngineError::Runtime(msg) => CliError::Runtime(format!("runtime error: {msg}")),
            EngineError::SelfHostPending(msg) => CliError::Runtime(format!("runtime error: {msg}")),
        }
    }
}
