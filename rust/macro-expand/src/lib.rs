//! `ball-lang-macro-expand` — `macro_rules!` expansion for the Ball Rust
//! encoder (issue #629).
//!
//! ## Why this is its own crate
//!
//! The expansion engine is rust-analyzer's own macro-by-example implementation,
//! published for stable toolchains as `ra_ap_mbe`. That is the tool-grade
//! mechanism — it is literally what rust-analyzer runs for every `macro_rules!`
//! in every Rust file it opens — but it arrives with a large transitive
//! dependency stack (salsa, rayon, dashmap, rowan, …) and its siblings are
//! internal APIs that `unwrap()`.
//!
//! Confining all of that behind the four-item API below means:
//!
//! - `ball-lang-encoder` names no `ra_ap_*` type anywhere, so a future engine
//!   swap (a newer `ra_ap_mbe`, or a hand-written matcher/transcriber) is a
//!   one-crate change with no encoder edit;
//! - every call into the engine sits behind [`std::panic::catch_unwind`] and
//!   re-raises as a named [`MacroError`], so an `unwrap()` deep inside an
//!   internal API can never surface as an inscrutable Ball "encode error".
//!
//! It is **published** alongside the other workspace members (issue #629's
//! owner decision, 2026-09-14): `cargo publish --workspace` refuses a
//! `publish = false` dependency of a published crate, so the quarantine crate
//! needs a version and a slot in `.github/workflows/publish-crates.yml`'s
//! dependency-ordered publish exactly like `ball-lang-shared` does.
//!
//! ## What it does, and what it does not
//!
//! It expands **declarative** macros — `macro_rules!` — and nothing else.
//! Proc-macros, `#[derive]`, attribute macros and the compiler's own builtins
//! (`format_args!`, `concat!`, `stringify!`, `env!`, `include!`, `cfg!`, …)
//! are out of scope **by design and loudly**: expanding `println!`'s real
//! `macro_rules` body just lands on `format_args_nl!`, a builtin with no
//! `macro_rules` definition anywhere, so the builtin/std family must keep going
//! through the encoder's own semantic lowering. That is an architectural line,
//! not a preference — see [`is_builtin_macro`].
//!
//! Hygiene is **approximated**, not implemented; the `hygiene` module states
//! exactly what is done and what is not.
//!
//! ## Failure is always loud and always named
//!
//! Every fallible step returns [`MacroError`], whose `Display` always names the
//! macro, where its definition came from, and the reason. Nothing is ever
//! silently dropped or partially expanded.

mod bridge;

use std::fmt;

/// Every way expansion can fail. Each variant's `Display` names the macro (or
/// the token text) and the reason; the encoder turns one into the same kind of
/// loud panic every other unsupported shape already produces.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MacroError {
    /// No `macro_rules!` in scope defines this name.
    Unresolved {
        /// The macro's path as written at the invocation.
        name: String,
        /// Every macro name that WAS in scope, sorted — the diagnostic that
        /// makes a real-code sweep actionable.
        in_scope: Vec<String>,
    },
    /// A definition's rules could not be parsed by the engine.
    DefinitionNotParseable {
        name: String,
        origin: String,
        reason: String,
    },
    /// The invocation matched no rule, or left tokens over.
    NoExpansion {
        name: String,
        origin: String,
        reason: String,
        arguments: String,
    },
    /// The expansion is not parseable Rust in the position it was invoked.
    NotParseable {
        name: String,
        position: &'static str,
        tokens: String,
        reason: String,
    },
    /// The same name is defined more than once in this crate with different
    /// rules, and nothing in a syntax-only encoder can pick between them.
    Ambiguous { name: String, modules: Vec<String> },
    /// Expansion did not reach a fixed point within the recursion limit.
    DepthLimit { chain: Vec<String>, limit: usize },
    /// A dependency-defined macro was needed but the dependency graph could not
    /// be read.
    DependenciesUnavailable {
        name: String,
        krate: String,
        reason: String,
    },
    /// A definition-origin identifier turned up in a position the hygiene
    /// approximation does not model, so renaming it — or leaving it alone —
    /// would both be a guess.
    UnclassifiedHygiene {
        name: String,
        binding: String,
        position: String,
    },
    /// The engine panicked. Its siblings are internal APIs that `unwrap()`, so
    /// this is a real possibility and gets its own named variant rather than
    /// escaping as a raw backtrace.
    EnginePanic { name: String, payload: String },
    /// A literal token could not be rebuilt on the way out of the engine.
    LiteralNotRebuildable { spelled: String },
}

impl fmt::Display for MacroError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            MacroError::Unresolved { name, in_scope } => write!(
                f,
                "cannot resolve the macro `{name}!` — no `macro_rules!` with that name is in \
                 scope. In scope here: [{}]",
                in_scope.join(", ")
            ),
            MacroError::DefinitionNotParseable {
                name,
                origin,
                reason,
            } => write!(
                f,
                "the `macro_rules! {name}` defined in {origin} could not be parsed: {reason}"
            ),
            MacroError::NoExpansion {
                name,
                origin,
                reason,
                arguments,
            } => write!(
                f,
                "`{name}!` (defined in {origin}) does not expand for these arguments: {reason}. \
                 Arguments were: {arguments}"
            ),
            MacroError::NotParseable {
                name,
                position,
                tokens,
                reason,
            } => write!(
                f,
                "the expansion of `{name}!` is not parseable as {position}: {reason}. Expansion \
                 was: {tokens}"
            ),
            MacroError::Ambiguous { name, modules } => write!(
                f,
                "the macro `{name}!` is defined in {} modules of this crate with differing rules \
                 ({}) — a syntax-only encoder cannot pick between them",
                modules.len(),
                modules.join(", ")
            ),
            MacroError::DepthLimit { chain, limit } => write!(
                f,
                "macro expansion exceeded the recursion limit of {limit} — the chain still \
                 expanding is [{}]",
                chain.join(" -> ")
            ),
            MacroError::DependenciesUnavailable {
                name,
                krate,
                reason,
            } => write!(
                f,
                "`{name}!` is defined by the dependency crate `{krate}`, whose sources could not \
                 be located: {reason}"
            ),
            MacroError::UnclassifiedHygiene {
                name,
                binding,
                position,
            } => write!(
                f,
                "the expansion of `{name}!` binds `{binding}` at the macro's definition site, but \
                 that name also appears {position}, where this encoder's hygiene approximation \
                 cannot tell a use of the binding from an unrelated name"
            ),
            MacroError::EnginePanic { name, payload } => write!(
                f,
                "the macro-by-example engine panicked while handling `{name}!`: {payload}"
            ),
            MacroError::LiteralNotRebuildable { spelled } => write!(
                f,
                "a literal token could not be rebuilt on the way out of the macro engine: \
                 `{spelled}`"
            ),
        }
    }
}

impl std::error::Error for MacroError {}

/// Is `name` one of the compiler's own / the standard prelude's macros?
///
/// These must **never** be expanded: their real bodies bottom out in compiler
/// builtins (`format_args_nl!`) that have no `macro_rules!` definition
/// anywhere, and the encoder lowers them semantically instead
/// (`rust/encoder/src/methods.rs::encode_macro`). The list is closed and
/// explicit so that "the encoder does not model `write!` yet" stays a
/// separately trackable gap (issue #630) rather than becoming an expansion
/// failure.
///
/// <https://doc.rust-lang.org/std/#macros>
pub fn is_builtin_macro(name: &str) -> bool {
    const BUILTINS: &[&str] = &[
        "assert",
        "assert_eq",
        "assert_ne",
        "cfg",
        "column",
        "compile_error",
        "concat",
        "dbg",
        "debug_assert",
        "debug_assert_eq",
        "debug_assert_ne",
        "env",
        "eprint",
        "eprintln",
        "file",
        "format",
        "format_args",
        "include",
        "include_bytes",
        "include_str",
        "line",
        "matches",
        "module_path",
        "option_env",
        "panic",
        "print",
        "println",
        "stringify",
        "todo",
        "unimplemented",
        "unreachable",
        "vec",
        "write",
        "writeln",
    ];
    // The same names are legal under an explicit `std::`/`core::`/`alloc::`
    // qualifier (`alloc::vec!` occurs in the real corpus).
    let short = name
        .rsplit("::")
        .next()
        .expect("rsplit always yields at least one segment");
    let qualifier = name.strip_suffix(short).unwrap_or("");
    let qualifier_ok = matches!(qualifier, "" | "std::" | "core::" | "alloc::");
    qualifier_ok && BUILTINS.contains(&short)
}

/// Run the token bridge end to end: `proc_macro2` → `ra_ap_tt` → `proc_macro2`.
///
/// The identity this returns is what every expansion depends on — an expansion
/// that survives the engine but is mangled on the way back out is indis-
/// tinguishable from a miscompile — so it is exposed as a supported
/// self-check and exercised as a property test
/// (`tests/token_bridge.rs`).
pub fn round_trip_tokens(
    stream: proc_macro2::TokenStream,
) -> Result<proc_macro2::TokenStream, MacroError> {
    let subtree = bridge::to_subtree(stream, bridge::span(bridge::CALL_FILE));
    bridge::from_subtree(&subtree, &mut |text, is_raw, _origin| {
        (text.to_owned(), is_raw)
    })
}
