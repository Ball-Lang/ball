//! Front-end for the Rust Tier A coverage study (issue #493) — the sibling of
//! `dart run tools/coverage-study/rq1_study.dart`.
//!
//! ```text
//! cargo run -p ball-rq1-study --bin rq1-study -- \
//!     --pins tools/coverage-study/packages/rust.json --checkouts <dir> [--json <out>]
//! cargo run -p ball-rq1-study --bin rq1-study -- \
//!     --package <name> --source-dir <dir> [--json <out>]
//! ```
//!
//! `--single-file` turns the crate walk OFF (issue #491): each file is encoded
//! on its own, exactly as this harness measured before `encode_crate` existed.
//! It is how the before/after of a crate-aware change is taken with ONE binary
//! over ONE checkout, instead of by comparing two builds of the harness.
//!
//! `--no-crate-root` (and a pin's `"crateRoot": "none"`) declares a studied
//! subtree that genuinely has no crate root — a bare directory of `.rs` files.
//! Without that declaration an unresolvable crate root is FATAL (issue #648):
//! it is what the `#[cfg(test)]` half of the test-only rule is anchored on, and
//! running without it publishes a denominator with that half silently off.
//!
//! Report-only; the methodology and the load-bearing harness settings are in
//! `tests/conformance/COVERAGE_STUDY.md`. The one thing that fails here is a
//! run that scored zero files — a harness/checkout failure, never a 0% result.

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use ball_rq1_study::{CrateRoot, Exclusion, FileResult, report, silence_panic_output, study_package};

/// The pin field (and CLI flag) that declares a studied subtree to have no
/// crate root — issue #648.
///
/// Spelled camelCase like every other JSON key this harness reads or writes
/// (`missingPins`, `excludedTestOnly`, `crateModule`); no sibling pin file in
/// `tools/coverage-study/packages/` has a multi-word key, so there was no
/// cross-language convention to keep instead.
const CRATE_ROOT_KEY: &str = "crateRoot";

/// Reads one pin's [`CrateRoot`] policy.
///
/// Absent means [`CrateRoot::Required`] — the anchorless branch is opt-in, never
/// the fallback. Any value other than `"none"` is an ERROR rather than an
/// ignored key: a typo that silently re-armed the default would be the same
/// invisible failure this field exists to end.
fn crate_root_policy(pin: &serde_json::Value) -> Result<CrateRoot, String> {
    match pin.get(CRATE_ROOT_KEY) {
        None => Ok(CrateRoot::Required),
        Some(serde_json::Value::String(value)) if value == "none" => Ok(CrateRoot::Absent),
        Some(other) => Err(format!(
            "pin field \"{CRATE_ROOT_KEY}\" must be the string \"none\" (the only declaration \
             this harness understands: a studied subtree that genuinely has no crate root); \
             got {other}"
        )),
    }
}

fn flag(args: &[String], name: &str) -> bool {
    let flag = format!("--{name}");
    args.iter().any(|a| a == &flag)
}

fn arg(args: &[String], name: &str) -> Option<String> {
    let flag = format!("--{name}");
    let index = args.iter().position(|a| a == &flag)?;
    args.get(index + 1).cloned()
}

fn main() -> ExitCode {
    // The pipeline fails loud by panicking; the harness scores each panic
    // rather than dying on it, so the default panic printer is silenced.
    silence_panic_output();

    let args: Vec<String> = std::env::args().skip(1).collect();
    // `--single-file` reproduces the pre-#491 measurement — no crate walk, each
    // file encoded on its own — so a before/after is one binary over one
    // checkout rather than two builds of the harness.
    let crate_aware = !flag(&args, "single-file");
    let mut results: Vec<FileResult> = Vec::new();
    let mut missing_pins: Vec<String> = Vec::new();
    let mut excluded: Vec<Exclusion> = Vec::new();

    if let Some(pins_path) = arg(&args, "pins") {
        let Some(checkouts) = arg(&args, "checkouts") else {
            eprintln!("--pins requires --checkouts <dir>");
            return ExitCode::from(2);
        };
        let raw = match std::fs::read_to_string(&pins_path) {
            Ok(raw) => raw,
            Err(err) => {
                eprintln!("could not read {pins_path}: {err}");
                return ExitCode::from(2);
            }
        };
        let pins: serde_json::Value = match serde_json::from_str(&raw) {
            Ok(value) => value,
            Err(err) => {
                eprintln!("{pins_path} is not valid JSON: {err}");
                return ExitCode::from(2);
            }
        };
        let Some(packages) = pins.get("packages").and_then(|p| p.as_array()) else {
            eprintln!("{pins_path} has no `packages` array");
            return ExitCode::from(2);
        };
        for pin in packages {
            let name = pin.get("name").and_then(|n| n.as_str()).unwrap_or_default();
            let lib = pin.get("lib").and_then(|l| l.as_str()).unwrap_or("src");
            let policy = match crate_root_policy(pin) {
                Ok(policy) => policy,
                Err(err) => {
                    eprintln!("ERROR: {pins_path}: {name}: {err}");
                    return ExitCode::from(2);
                }
            };
            let dir = PathBuf::from(&checkouts).join(name).join(lib);
            if !dir.is_dir() {
                // An unreachable pin is NOT an encoder regression — report it as
                // a distinct outcome instead of scoring it as a failure.
                missing_pins.push(name.to_string());
                continue;
            }
            match study_package(name, &dir, crate_aware, policy) {
                Ok(study) => {
                    excluded.extend(study.excluded);
                    results.extend(study.results);
                }
                // A pin the test-only rule cannot anchor on stops the whole run
                // (#648): measuring on would publish a denominator with one half
                // of that rule silently switched off.
                Err(err) => {
                    eprintln!("ERROR: {err}");
                    return ExitCode::from(2);
                }
            }
        }
    } else if let (Some(package), Some(source_dir)) =
        (arg(&args, "package"), arg(&args, "source-dir"))
    {
        let dir = Path::new(&source_dir);
        if !dir.is_dir() {
            eprintln!("--source-dir does not exist: {source_dir}");
            return ExitCode::from(2);
        }
        // The ad-hoc invocation gets the SAME opt-in the pin file does; an
        // escape hatch that existed only in the pin file would leave the
        // command a human actually types with the old silent fallback (#648).
        let policy = if flag(&args, "no-crate-root") {
            CrateRoot::Absent
        } else {
            CrateRoot::Required
        };
        match study_package(&package, dir, crate_aware, policy) {
            Ok(study) => {
                excluded.extend(study.excluded);
                results.extend(study.results);
            }
            Err(err) => {
                eprintln!("ERROR: {err}");
                return ExitCode::from(2);
            }
        }
    } else {
        eprintln!(
            "Usage: rq1-study --pins <file> --checkouts <dir> [--json <out>] [--single-file]\n\
             \x20      rq1-study --package <name> --source-dir <dir> [--json <out>] \
             [--single-file] [--no-crate-root]"
        );
        return ExitCode::from(2);
    }

    if let Some(json_out) = arg(&args, "json") {
        let blob = serde_json::json!({
            "missingPins": missing_pins,
            "files": results.iter().map(FileResult::to_json).collect::<Vec<_>>(),
            "excludedTestOnly": excluded.len(),
            "excluded": excluded
                .iter()
                .map(|e| serde_json::json!({
                    "package": e.package,
                    "file": e.file,
                    "rule": e.rule,
                }))
                .collect::<Vec<_>>(),
        });
        let rendered = serde_json::to_string_pretty(&blob).unwrap_or_else(|err| {
            eprintln!("could not render the JSON report: {err}");
            String::from("{}")
        });
        if let Err(err) = std::fs::write(&json_out, format!("{rendered}\n")) {
            eprintln!("could not write {json_out}: {err}");
            return ExitCode::from(2);
        }
    }

    let mut out = String::new();
    match report(&mut out, &results, &excluded, &missing_pins) {
        Ok(code) => {
            print!("{out}");
            if code != 0 {
                eprintln!("ERROR: Tier A scored 0 files — no package checkout was readable.");
            }
            ExitCode::from(code as u8)
        }
        Err(err) => {
            print!("{out}");
            eprintln!("ERROR: {err}");
            ExitCode::from(1)
        }
    }
}
