//! `crate::gamma` — a non-mod-rs file, so its own out-of-line child resolves
//! under a directory named after it (`src/gamma/deep.rs`).
pub mod deep;

/// An INLINE module block: its items live in this same file, but they are a
/// separate Rust module and become a separate Ball module.
pub mod inner {
    pub fn three() -> i64 {
        3
    }
}
