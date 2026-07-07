//! `ball-engine` — runs Ball programs.
//!
//! This crate is currently an empty scaffold (Ball Phase 1a, issue #33). The
//! plan (Phase 4, issue #39) is to self-host: compile
//! `dart/self_host/engine.ball.json` through `ball-compiler` into
//! `src/compiled_engine.rs`, then wrap it with a thin runtime that supplies
//! std function implementations and I/O. See `ts/engine/src/index.ts` for
//! the reference wrapper pattern.
