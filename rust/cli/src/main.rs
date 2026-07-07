//! `ball-cli` — Ball CLI entry point (`ball run` / `ball compile` / `ball encode` / `ball check`).
//!
//! This is currently a placeholder (Ball Phase 1a, issue #33). Subcommand
//! wiring against `ball-engine` / `ball-compiler` / `ball-encoder` lands in
//! Phase 5 (issue #41). See `ts/cli/` for the reference CLI this will match.

fn main() {
    println!(
        "ball-cli {} — Ball Rust toolchain scaffold (workspace builds, no subcommands yet; see issue #41)",
        env!("CARGO_PKG_VERSION")
    );
}
