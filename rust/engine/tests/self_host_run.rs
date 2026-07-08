//! End-to-end self-host run tests (issue #300): the compiled self-hosted
//! engine actually **executes** acceptance programs and produces output
//! identical to the Dart reference engine. Only built under `--features
//! self_host` (the default build ships the wrapper foundation without the
//! generated `compiled_engine.rs`).
#![cfg(feature = "self_host")]

use ball_engine::BallEngine;

/// Run a `.ball.json` program (relative to the repo root) and return its
/// captured stdout lines.
fn run(rel: &str) -> Vec<String> {
    let path = format!("{}/../../{}", env!("CARGO_MANIFEST_DIR"), rel);
    let json = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {rel}: {e}"));
    BallEngine::from_json(&json)
        .unwrap_or_else(|e| panic!("load {rel}: {e}"))
        .run()
        .unwrap_or_else(|e| panic!("run {rel}: {e}"))
}

#[test]
fn hello_world_prints_greeting() {
    // The simplest program: `main` calls `std.print("Hello, World!")`. Exercises
    // the full self-host loop — construction, lookup tables, program evaluation,
    // and `std.print` dispatch through the compiled `StdModuleHandler`.
    assert_eq!(
        run("examples/hello_world/hello_world.ball.json"),
        vec!["Hello, World!"]
    );
}

#[test]
fn fibonacci_recursion_matches_dart() {
    // Recursive `fibonacci(10)` — exercises user-function dispatch, recursion,
    // and arithmetic. The Dart reference engine prints `55`.
    assert_eq!(run("examples/fibonacci/fibonacci.ball.json"), vec!["55"]);
}
