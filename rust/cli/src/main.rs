//! `ball` — the Ball language CLI (Rust toolchain).
//!
//! Subcommands: `run`, `compile`, `encode`, `check` (issue #41), plus the
//! self-hosted cli-core verbs `info`, `validate`, `tree`, `audit`, `version`
//! (issue #365 — compiled from `dart/shared/lib/cli_core.dart`, see
//! `rust/cli/AGENTS.md`), mirroring the Dart/TS CLIs' shape (`dart/cli/`,
//! `ts/cli/`) where it applies to the Rust toolchain's current surface (no
//! package-registry commands like `dart/cli`'s `init`/`add`/`resolve`/
//! `publish` yet; `audit` here is the bare capability/termination report — the
//! Dart CLI's `--deny`/`--exit-code`/`--reachable-only`/`--output` policy
//! flags stay native-only, out of the cli-core parity surface).
//!
//! ## Exit codes
//!
//! | Code | Meaning |
//! |------|---------|
//! | `0`  | success |
//! | `1`  | runtime error — a Ball program ran but failed (a `throw` that escaped `main`, or the engine itself reporting an error) |
//! | `2`  | invalid/unparseable program — bad `.ball.json`/`.ball.bin` shape, Rust source `encode` couldn't turn into a program, a loaded program was too malformed to compile, or `ball validate` found the program invalid |
//! | `3`  | file-not-found / other I/O error reading input or writing `--output` |
//!
//! See `src/error.rs` for the exact `CliError` -> exit-code mapping.
mod commands;
#[cfg(feature = "cli_core")]
mod compiled_cli;
mod error;
mod loader;
mod output;
mod panic_guard;
mod serialize;

use std::path::PathBuf;

use clap::{Parser, Subcommand};

use commands::encode::Format;
use error::CliError;

#[derive(Parser)]
#[command(
    name = "ball",
    version,
    about = "Ball language CLI (Rust toolchain) — run/compile/encode/check/info/validate/tree/audit/version.",
    long_about = "Ball language CLI (Rust toolchain): run/compile/encode/check/info/validate/tree/audit/version.\n\n\
        NOTE on `run`: it drives the self-hosted engine, built in via \
        `ball-lang-cli`'s `self_host` Cargo feature (off by default — see \
        rust/cli/Cargo.toml). Without that feature every program honestly \
        reports a runtime error instead of silently doing nothing. Built \
        with `--features self_host` (after regenerating \
        rust/engine/src/compiled_engine.rs — see rust/engine/AGENTS.md), the \
        engine currently executes simple acceptance programs (hello_world, \
        recursive fibonacci); anything beyond that surfaces the engine's own \
        error rather than pretending to succeed.\n\n\
        NOTE on `info`/`validate`/`tree`/`audit`: they drive the self-hosted \
        cli-core, built in via `ball-lang-cli`'s `cli_core` Cargo feature (off by \
        default — see rust/cli/Cargo.toml). Without that feature they honestly \
        report a runtime error instead of silently doing nothing. `version` \
        always works regardless of this feature."
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Execute a Ball program and print its stdout.
    Run {
        /// Path to the program: `.ball.json` (proto3 JSON) or `.ball.bin` (binary protobuf).
        program: PathBuf,
    },
    /// Compile a Ball program to Rust source.
    Compile {
        /// Path to the program: `.ball.json`/`.ball.bin`.
        program: PathBuf,
        /// Write the generated Rust source here instead of stdout.
        #[arg(long, short)]
        output: Option<PathBuf>,
    },
    /// Encode a Rust source file into a Ball program.
    Encode {
        /// Path to the Rust source file (`.rs`) to encode.
        source: PathBuf,
        /// Write the encoded program here instead of stdout.
        #[arg(long, short)]
        output: Option<PathBuf>,
        /// Output format.
        #[arg(long, value_enum, default_value = "json")]
        format: Format,
    },
    /// Parse and validate a Ball program without running it.
    Check {
        /// Path to the program: `.ball.json`/`.ball.bin`.
        program: PathBuf,
        /// Additionally attempt a dry-run compile to Rust (output discarded)
        /// — a stronger, Rust-target-specific check. See
        /// `src/commands/check.rs` for why this is opt-in.
        #[arg(long)]
        compile: bool,
    },
    /// Inspect a Ball program's structure (modules, functions, type defs).
    Info {
        /// Path to the program: `.ball.json`/`.ball.bin`.
        program: PathBuf,
    },
    /// Check a Ball program's validity (entry point, module/function shape).
    Validate {
        /// Path to the program: `.ball.json`/`.ball.bin`.
        program: PathBuf,
    },
    /// Print a Ball program's module/import dependency tree.
    Tree {
        /// Path to the program: `.ball.json`/`.ball.bin`.
        program: PathBuf,
    },
    /// Report a Ball program's capabilities and non-termination risks.
    Audit {
        /// Path to the program: `.ball.json`/`.ball.bin`.
        program: PathBuf,
    },
    /// Print the CLI's version.
    Version,
}

fn main() {
    let cli = Cli::parse();

    let result: Result<(), CliError> = match cli.command {
        Command::Run { program } => commands::run::run(&program),
        Command::Compile { program, output } => {
            commands::compile::compile(&program, output.as_deref())
        }
        Command::Encode {
            source,
            output,
            format,
        } => commands::encode::encode(&source, output.as_deref(), format),
        Command::Check { program, compile } => commands::check::check(&program, compile),
        Command::Info { program } => commands::info::info(&program),
        Command::Validate { program } => commands::validate::validate(&program),
        Command::Tree { program } => commands::tree::tree(&program),
        Command::Audit { program } => commands::audit::audit(&program),
        Command::Version => {
            commands::version::version();
            Ok(())
        }
    };

    if let Err(err) = result {
        eprintln!("ball: {err}");
        std::process::exit(err.exit_code());
    }
}
