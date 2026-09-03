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
//! Report-only; the methodology and the load-bearing harness settings are in
//! `tests/conformance/COVERAGE_STUDY.md`. The one thing that fails here is a
//! run that scored zero files — a harness/checkout failure, never a 0% result.

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use ball_rq1_study::{FileResult, report, silence_panic_output, study_directory};

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
    let mut results: Vec<FileResult> = Vec::new();
    let mut missing_pins: Vec<String> = Vec::new();

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
            let dir = PathBuf::from(&checkouts).join(name).join(lib);
            if !dir.is_dir() {
                // An unreachable pin is NOT an encoder regression — report it as
                // a distinct outcome instead of scoring it as a failure.
                missing_pins.push(name.to_string());
                continue;
            }
            results.extend(study_directory(name, &dir));
        }
    } else if let (Some(package), Some(source_dir)) =
        (arg(&args, "package"), arg(&args, "source-dir"))
    {
        let dir = Path::new(&source_dir);
        if !dir.is_dir() {
            eprintln!("--source-dir does not exist: {source_dir}");
            return ExitCode::from(2);
        }
        results.extend(study_directory(&package, dir));
    } else {
        eprintln!(
            "Usage: rq1-study --pins <file> --checkouts <dir> [--json <out>]\n       \
             rq1-study --package <name> --source-dir <dir> [--json <out>]"
        );
        return ExitCode::from(2);
    }

    if let Some(json_out) = arg(&args, "json") {
        let blob = serde_json::json!({
            "missingPins": missing_pins,
            "files": results.iter().map(FileResult::to_json).collect::<Vec<_>>(),
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
    match report(&mut out, &results, &missing_pins) {
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
