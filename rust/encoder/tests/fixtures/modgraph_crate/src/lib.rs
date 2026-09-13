//! Crate root of the mod-graph fixture. A LIBRARY crate: there is no
//! `fn main`, so `encode_crate` uses library-mode semantics (issue #569) — an
//! empty `entry_function`, deliberately not runnable.

/// `src/alpha/mod.rs` — the directory-with-`mod.rs` spelling.
pub mod alpha;

/// `src/renamed.rs` — `#[path]` on an out-of-line module is relative to the
/// directory of the file that declares it (Rust reference, "The `path`
/// attribute").
#[path = "renamed.rs"]
pub mod beta;

/// `src/gamma.rs` — which itself declares BOTH an out-of-line child (resolved
/// under `src/gamma/`, because `gamma.rs` is a non-mod-rs file) and an inline
/// `mod` block.
pub mod gamma;

/// Never walked: `cargo build` does not compile a `#[cfg(test)]` module, and
/// neither does the crate walker. `src/tests.rs` exists and contains an
/// `assert!` the encoder has no mapping for, so encoding it would fail loud —
/// which is exactly what makes the skip observable.
#[cfg(test)]
mod tests;

pub fn total() -> i64 {
    alpha::one() + beta::two() + gamma::inner::three() + gamma::deep::four()
}
