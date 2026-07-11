//! Self-host conformance runner (issues #39/#40/#300): drives the compiled
//! self-hosted engine over the whole `tests/conformance/` corpus and compares
//! each fixture's captured stdout to its `.expected_output.txt` golden — the
//! same corpus the Dart/TS/C++ engines run, so a pass here is Dart-identical
//! output.
//!
//! Only built under `--features self_host`. It is `#[ignore]` by default (a
//! long, whole-corpus sweep); run it explicitly:
//!
//! ```bash
//! cargo test -p ball-lang-engine --features self_host --test self_host_conformance \
//!   -- --ignored --nocapture
//! ```
//!
//! Set `BALL_FIXTURE=<name>` to run (and dump actual-vs-expected for) a single
//! fixture, e.g. `BALL_FIXTURE=44_for_loop_basic`.
#![cfg(feature = "self_host")]

use std::path::PathBuf;
use std::sync::mpsc;
use std::time::Duration;

use ball_lang_engine::BallEngine;

/// Per-fixture wall-clock budget. A latent infinite loop (the loop-scope bug)
/// must not wedge the whole sweep — a fixture that blows the budget is recorded
/// as a timeout and the sweep moves on (the leaked worker thread is harmless
/// for a measurement run).
const TIMEOUT: Duration = Duration::from_secs(120);

fn conformance_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/conformance")
}

/// Outcome of running one fixture.
enum Outcome {
    Pass,
    Fail {
        actual: Vec<String>,
        expected: Vec<String>,
    },
    Error(String),
    Timeout,
}

fn run_fixture(json: String) -> Result<Vec<String>, String> {
    let (tx, rx) = mpsc::channel();
    // The engine already runs on its own large-stack thread internally; this
    // outer thread is only the watchdog boundary so a hang can't wedge the run.
    std::thread::spawn(move || {
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            BallEngine::from_json(&json)
                .map_err(|e| e.to_string())
                .and_then(|engine| engine.run().map_err(|e| e.to_string()))
        }));
        let _ = tx.send(result.unwrap_or_else(|_| Err("panic escaped run".to_string())));
    });
    match rx.recv_timeout(TIMEOUT) {
        Ok(result) => result,
        Err(_) => Err("__timeout__".to_string()),
    }
}

fn expected_lines(text: &str) -> Vec<String> {
    // Goldens are trailing-newline terminated and may carry Windows CRLF line
    // endings (the repo is developed on Windows); split into lines, stripping a
    // trailing `\r` per line and dropping the single trailing empty the
    // terminator produces.
    let mut lines: Vec<String> = text
        .split('\n')
        .map(|s| s.strip_suffix('\r').unwrap_or(s).to_string())
        .collect();
    if lines.last().map(|s| s.is_empty()).unwrap_or(false) {
        lines.pop();
    }
    lines
}

#[test]
#[ignore = "whole-corpus sweep; run explicitly with --ignored --nocapture"]
fn conformance_corpus() {
    // Silence the default panic printer. Every Ball `throw` is a `panic_any`
    // (normally caught right back by the engine's compiled `try`), and the
    // exception-heavy fixtures generate thousands per run — the default hook's
    // stderr printing dominated the sweep's runtime and produced multi-MB logs
    // (large enough to take down a memory-constrained WSL session, #39/#300).
    // Outcomes are reported by this harness itself, so nothing is lost.
    std::panic::set_hook(Box::new(|_| {}));
    let dir = conformance_dir();
    let single = std::env::var("BALL_FIXTURE").ok();

    let mut fixtures: Vec<PathBuf> = std::fs::read_dir(&dir)
        .unwrap_or_else(|e| panic!("read {}: {e}", dir.display()))
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .map(|n| n.ends_with(".ball.json"))
                .unwrap_or(false)
        })
        .collect();
    fixtures.sort();

    let mut passed = 0usize;
    let mut failures: Vec<(String, Outcome)> = Vec::new();
    let mut total = 0usize;
    let mut skipped = 0usize;

    for fixture in &fixtures {
        let name = fixture
            .file_name()
            .unwrap()
            .to_str()
            .unwrap()
            .trim_end_matches(".ball.json")
            .to_string();
        if let Some(only) = &single {
            if &name != only {
                continue;
            }
        }
        // A fixture with no `.expected_output.txt` is a documented **behavioral
        // carve-out** (196_timeout / 197_memory_limit / 201_input_validation /
        // 202_sandbox_mode — resource-limit/sandbox fixtures asserted elsewhere;
        // see tests/conformance/CARVEOUTS.md). The Dart reference runner
        // (`tests/conformance/run_conformance.dart`) SKIPS these — so skip them
        // here too for true parity (running one as "expected empty" would falsely
        // pass 197/202 and falsely fail 196/201). They are excluded from the
        // pass/fail total, matching the TS/C++ matrix runners' carve-out handling.
        let expected_path = dir.join(format!("{name}.expected_output.txt"));
        let Ok(expected_text) = std::fs::read_to_string(&expected_path) else {
            skipped += 1;
            if single.is_some() {
                eprintln!("[{name}] SKIP (no golden — behavioral carve-out)");
            }
            continue;
        };
        let expected = expected_lines(&expected_text);
        total += 1;

        let json = std::fs::read_to_string(fixture).unwrap();
        let outcome = match run_fixture(json) {
            Ok(prints) => {
                // `run()` returns one element per `print(...)` call. A single
                // print may itself contain embedded newlines (`print('a\nb')`),
                // which on real stdout are distinct lines — and the golden,
                // captured from the Dart reference's stdout, splits them. So
                // reconstruct stdout exactly as Dart emits it (each `print`
                // writes its argument + '\n') and split it the same way the
                // golden is read (fixtures 247/249/250 — #39/#300).
                let stdout: String = prints.iter().map(|s| format!("{s}\n")).collect();
                let actual = expected_lines(&stdout);
                if actual == expected {
                    passed += 1;
                    Outcome::Pass
                } else {
                    Outcome::Fail {
                        actual,
                        expected: expected.clone(),
                    }
                }
            }
            Err(e) if e == "__timeout__" => Outcome::Timeout,
            Err(e) => Outcome::Error(e),
        };

        if single.is_some() {
            match &outcome {
                Outcome::Pass => eprintln!("[{name}] PASS"),
                Outcome::Timeout => eprintln!("[{name}] TIMEOUT"),
                Outcome::Error(e) => eprintln!("[{name}] ERROR: {e}"),
                Outcome::Fail { actual, expected } => {
                    eprintln!("[{name}] FAIL");
                    eprintln!("--- expected ({}) ---", expected.len());
                    for l in expected {
                        eprintln!("  {l}");
                    }
                    eprintln!("--- actual ({}) ---", actual.len());
                    for l in actual {
                        eprintln!("  {l}");
                    }
                }
            }
        }

        if !matches!(outcome, Outcome::Pass) {
            failures.push((name, outcome));
        }
    }

    // Summary line (the exact `Results: N passed, M failed, T total` format the
    // conformance-matrix workflow greps — #40). `total` is the golden-having
    // (executed) fixture count; behavioral carve-outs are reported separately.
    eprintln!(
        "\nResults: {passed} passed, {} failed, {total} total ({skipped} skipped carve-outs)",
        total - passed
    );
    if !failures.is_empty() && single.is_none() {
        eprintln!("\n--- failures ---");
        for (name, outcome) in &failures {
            match outcome {
                Outcome::Timeout => eprintln!("  {name}: TIMEOUT"),
                Outcome::Error(e) => {
                    let short: String = e.chars().take(160).collect();
                    eprintln!("  {name}: ERROR {short}");
                }
                Outcome::Fail { actual, expected } => {
                    let a = actual.first().map(|s| s.as_str()).unwrap_or("<none>");
                    let e = expected.first().map(|s| s.as_str()).unwrap_or("<none>");
                    eprintln!(
                        "  {name}: FAIL (got {} lines, want {}) first: {a:?} vs {e:?}",
                        actual.len(),
                        expected.len()
                    );
                }
                Outcome::Pass => {}
            }
        }
    }
}
