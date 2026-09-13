//! `ball-lang-macro-expand` — `macro_rules!` expansion for the Ball Rust
//! encoder (issue #629).
//!
//! Slice 1 of #629, RED half: the workspace wiring and the pinned engine
//! dependencies are here, and `tests/token_bridge.rs` states the identity the
//! whole feature rests on — a `proc_macro2::TokenStream` converted into the
//! engine's `ra_ap_tt` representation and back must be token-identical. The
//! bridge that satisfies it lands next.
