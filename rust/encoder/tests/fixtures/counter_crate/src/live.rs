//! `crate::live` — declared `#[cfg(not(test))] mod live;` in the crate root.
//!
//! `cargo build` compiles this module: `not(test)` is TRUE for every ordinary
//! build. It exists because the walker used to scan a `cfg` predicate for a
//! bare `test` IDENT anywhere in its token tree, so `not(test)` matched and
//! this module was **silently dropped** (issue #626) — taking `stamp` with it
//! and leaving `main`'s `live::stamp(...)` call pointing at nothing.
pub fn stamp(text: String) -> String {
    format!("{} live", text)
}
