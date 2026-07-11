//! End-to-end self-host run tests (issue #300): the compiled self-hosted
//! engine actually **executes** acceptance programs and produces output
//! identical to the Dart reference engine. Only built under `--features
//! self_host` (the default build ships the wrapper foundation without the
//! generated `compiled_engine.rs`).
#![cfg(feature = "self_host")]

use ball_lang_engine::BallEngine;

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

/// Run a `tests/conformance/<name>.ball.json` fixture and assert its output is
/// **identical** to the golden `<name>.expected_output.txt` — i.e. the Rust
/// self-hosted engine produces Dart-reference-identical output (the corpus is
/// generated from the Dart engine). Goldens may carry Windows CRLF endings, so
/// the golden is normalized before comparison.
fn assert_fixture(name: &str) {
    let dir = format!("{}/../../tests/conformance", env!("CARGO_MANIFEST_DIR"));
    let actual = run(&format!("tests/conformance/{name}.ball.json"));
    let expected_text = std::fs::read_to_string(format!("{dir}/{name}.expected_output.txt"))
        .unwrap_or_else(|e| panic!("read golden for {name}: {e}"));
    let mut expected: Vec<String> = expected_text
        .split('\n')
        .map(|s| s.strip_suffix('\r').unwrap_or(s).to_string())
        .collect();
    if expected.last().map(|s| s.is_empty()).unwrap_or(false) {
        expected.pop();
    }
    assert_eq!(
        actual, expected,
        "self-host output for {name} != Dart golden"
    );
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

// ── Acceptance programs (issues #39/#300) ─────────────────────────────────
// Each asserts Dart-reference-identical output. `for`/`while`/factorial are the
// loop-counter programs unblocked by the switch fall-through fix (a body-less
// `case` in the engine's increment/decrement dispatch previously no-op'd
// `i++`/`i--`, wedging every loop); `string_ops`/`string_builder` exercise the
// wrapper-class/`field_2` proto-getter-alias surface; `closures` exercises
// per-iteration scope capture; `map_operations` exercises map insertion order.

#[test]
fn for_loop_matches_dart() {
    assert_fixture("44_for_loop_basic");
}

#[test]
fn while_loop_matches_dart() {
    assert_fixture("46_while_loop");
}

#[test]
fn for_sum_matches_dart() {
    assert_fixture("41_for_sum");
}

#[test]
fn recursion_factorial_matches_dart() {
    assert_fixture("57_recursion_factorial");
}

#[test]
fn increment_decrement_matches_dart() {
    assert_fixture("40_increment_decrement");
}

#[test]
fn string_ops_matches_dart() {
    assert_fixture("26_string_ops");
}

#[test]
fn string_builder_matches_dart() {
    assert_fixture("77_string_builder");
}

#[test]
fn closures_matches_dart() {
    assert_fixture("25_closures");
}

#[test]
fn map_operations_insertion_order_matches_dart() {
    assert_fixture("78_map_operations");
}
