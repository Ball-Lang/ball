//! Whole-corpus ROUND-TRIP leg for the Rust target (issue #452 item 3).
//!
//! `self_host_conformance.rs` sweeps the corpus through the self-hosted Rust
//! engine. This is a different question: **can the Rust encoder read back what
//! the Rust compiler emits?**
//!
//! Per fixture:
//!
//! 1. Load the fixture and compile it Ball -> Rust (`ball-lang-compiler`).
//! 2. Re-encode that Rust source back into a Ball `Program`
//!    (`ball-lang-encoder`).
//! 3. Run the **RE-ENCODED** program on the **Dart reference engine**
//!    (`dart run dart/cli/bin/ball.dart run <reencoded.ball.json>`). Ground
//!    truth on purpose: running it on Rust's own engine would only prove the
//!    Rust pipeline agrees with itself.
//! 4. Byte-compare stdout to the fixture's `.expected_output.txt` golden.
//!
//! ## No 320 cargo builds
//!
//! Both the compile and the re-encode steps are **in-process** — this leg reads
//! the compiler's emitted Rust as *text* and hands it straight to the encoder,
//! exactly as `csharp/engine/conformance/RoundTripLeg.cs` does with its emitted
//! C#. Nothing is ever handed to `rustc`, so the per-fixture cost is a string
//! round trip plus (only for a fixture that survives re-encoding) one `dart run`.
//!
//! ## A near-zero baseline is the honest answer, not a bug
//!
//! The compiler emits a flat program dispatching through
//! `ball_lang_shared::runtime::*` helpers over `BallValue`; the encoder is a
//! syntactic `syn` reader built for idiomatic hand-written Rust with a
//! `fn main()`. Neither was designed to meet in the middle — the C# analogue
//! this leg mirrors measures exactly 0. This leg keeps that number live and
//! honest; raising it is encoder/compiler work tracked elsewhere.
//!
//! ## Not a PR gate
//!
//! `#[ignore]` by default (a long, whole-corpus sweep that shells out to Dart),
//! so `cargo test --workspace` in the PR-gated `Rust` CI job never runs it. Its
//! CI home is the `rust-roundtrip` row in
//! `.github/workflows/conformance-matrix.yml`, which has **no** `pull_request`
//! trigger — it runs on push-to-main, the weekly schedule, or manual dispatch.
//! An absent check on a PR is not a green one. Run it explicitly:
//!
//! ```bash
//! cargo test -p ball-lang-engine --test roundtrip_conformance -- --ignored --nocapture
//! ```
//!
//! `BALL_FIXTURE=<name>` runs a single fixture; `BALL_DART=<path>` overrides the
//! Dart launcher.
use std::panic::{self, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use ball_lang_compiler::Compiler;
use ball_lang_shared::DESCRIPTOR_POOL;
use ball_lang_shared::proto::ball::v1::Program;
use prost::Message;
use prost_reflect::{DynamicMessage, SerializeOptions};

/// Per-fixture wall-clock budget for the Dart run.
const DART_TIMEOUT: Duration = Duration::from_secs(60);

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("the repo root must resolve from rust/engine")
}

fn conformance_dir() -> PathBuf {
    repo_root().join("tests/conformance")
}

fn dart_executable() -> String {
    std::env::var("BALL_DART").unwrap_or_else(|_| "dart".to_string())
}

/// One fixture's outcome. `compile-error`/`encode-error` are FAILURES of this
/// leg, never skips — a scope gap that stops the round trip is exactly what this
/// leg measures.
struct Outcome {
    status: &'static str,
    detail: String,
}

impl Outcome {
    fn pass() -> Self {
        Outcome {
            status: "pass",
            detail: String::new(),
        }
    }

    fn of(status: &'static str, detail: impl Into<String>) -> Self {
        Outcome {
            status,
            detail: detail.into(),
        }
    }
}

/// Run `f`, converting a fail-loud `panic!`/`assert!` from the compiler or the
/// encoder into an `Err(message)` — mirrors `rust/cli/src/panic_guard.rs`. The
/// default hook is silenced (and restored) so a caught, intentionally-converted
/// panic doesn't bury the sweep's own report under Rust's panic banners.
fn catch_panic_message<T>(f: impl FnOnce() -> T) -> Result<T, String> {
    let previous_hook = panic::take_hook();
    panic::set_hook(Box::new(|_| {}));
    let result = panic::catch_unwind(AssertUnwindSafe(f));
    panic::set_hook(previous_hook);
    result.map_err(|payload| {
        if let Some(s) = (*payload).downcast_ref::<&str>() {
            (*s).to_string()
        } else if let Some(s) = (*payload).downcast_ref::<String>() {
            s.clone()
        } else {
            "unknown panic (no string payload)".to_string()
        }
    })
}

/// `.ball.json` -> `Program`. The corpus files are `@type`-enveloped
/// `google.protobuf.Any` JSON; the envelope key is cosmetic and stripped here,
/// mirroring `rust/engine/src/loader.rs`.
fn load_program(path: &Path) -> Result<Program, String> {
    let text = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
    let mut value: serde_json::Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    if let Some(object) = value.as_object_mut() {
        object.remove("@type");
    }
    let descriptor = DESCRIPTOR_POOL
        .get_message_by_name("ball.v1.Program")
        .ok_or("ball.v1.Program missing from the embedded descriptor pool")?;
    let dynamic = DynamicMessage::deserialize(descriptor, value).map_err(|e| e.to_string())?;
    Program::decode(dynamic.encode_to_vec().as_slice()).map_err(|e| e.to_string())
}

/// `Program` -> `@type`-enveloped proto3 JSON — the `.ball.json` shape every
/// Ball CLI reads (mirrors `rust/cli/src/serialize.rs::program_to_json`).
fn program_to_json(program: &Program) -> Result<String, String> {
    let descriptor = DESCRIPTOR_POOL
        .get_message_by_name("ball.v1.Program")
        .ok_or("ball.v1.Program missing from the embedded descriptor pool")?;
    let dynamic = DynamicMessage::decode(descriptor, program.encode_to_vec().as_slice())
        .map_err(|e| e.to_string())?;
    let options = SerializeOptions::new()
        .use_proto_field_name(false)
        .skip_default_fields(true);
    let mut serializer = serde_json::Serializer::new(Vec::new());
    dynamic
        .serialize_with_options(&mut serializer, &options)
        .map_err(|e| e.to_string())?;
    let serialized: serde_json::Value =
        serde_json::from_slice(&serializer.into_inner()).map_err(|e| e.to_string())?;

    let mut enveloped = serde_json::Map::new();
    enveloped.insert(
        "@type".to_string(),
        serde_json::Value::String("type.googleapis.com/ball.v1.Program".to_string()),
    );
    if let serde_json::Value::Object(fields) = serialized {
        enveloped.extend(fields);
    }
    serde_json::to_string(&serde_json::Value::Object(enveloped)).map_err(|e| e.to_string())
}

/// Split captured stdout / a golden into comparable lines: strip a trailing
/// `\r` per line (goldens may carry CRLF) and drop the single trailing empty
/// element the terminating newline produces. Never a text-mode translation —
/// a lone `\r` is legitimate program output.
fn split_lines(text: &str) -> Vec<String> {
    let mut lines: Vec<String> = text
        .split('\n')
        .map(|line| line.strip_suffix('\r').unwrap_or(line).to_string())
        .collect();
    if lines.last().is_some_and(|last| last.is_empty()) {
        lines.pop();
    }
    lines
}

fn run_dart(dart: &str, ball_json: &Path, root: &Path) -> Result<(i32, String, String), String> {
    // `Command` has no built-in timeout; the Dart CLI's own engine is not
    // driven here with a budget, so a runaway fixture would hang. Spawn and
    // poll so a hung child is killed rather than wedging the sweep.
    let mut child = Command::new(dart)
        .arg("run")
        .arg(root.join("dart/cli/bin/ball.dart"))
        .arg("run")
        .arg(ball_json)
        .current_dir(root)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| format!("could not spawn `{dart}`: {e}"))?;

    let deadline = std::time::Instant::now() + DART_TIMEOUT;
    loop {
        match child.try_wait().map_err(|e| e.to_string())? {
            Some(_) => break,
            None => {
                if std::time::Instant::now() >= deadline {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err("__timeout__".to_string());
                }
                std::thread::sleep(Duration::from_millis(25));
            }
        }
    }

    let output = child.wait_with_output().map_err(|e| e.to_string())?;
    Ok((
        output.status.code().unwrap_or(-1),
        String::from_utf8_lossy(&output.stdout).into_owned(),
        String::from_utf8_lossy(&output.stderr).into_owned(),
    ))
}

fn round_trip_one(
    name: &str,
    path: &Path,
    golden: &str,
    dart: &str,
    root: &Path,
    workdir: &Path,
) -> Outcome {
    let program = match load_program(path) {
        Ok(program) => program,
        Err(e) => return Outcome::of("error", format!("load: {e}")),
    };

    // 1. Ball -> Rust (fail-loud by design; a scope gap is a FAILURE here).
    let source = match catch_panic_message(|| Compiler::new(&program).compile()) {
        Ok(source) => source,
        Err(e) => return Outcome::of("compile-error", first_line(&e)),
    };

    // 2. Rust -> Ball (the step expected to reject compiler-emitted shapes
    //    today — that rejection is the measurement).
    let reencoded = match catch_panic_message(|| ball_lang_encoder::encode(&source)) {
        Ok(program) => program,
        Err(e) => return Outcome::of("encode-error", first_line(&e)),
    };

    let ball_json = workdir.join(format!("{name}.ball.json"));
    match program_to_json(&reencoded) {
        Ok(json) => {
            if let Err(e) = std::fs::write(&ball_json, json) {
                return Outcome::of("error", format!("serialize: {e}"));
            }
        }
        Err(e) => return Outcome::of("error", format!("serialize: {e}")),
    }

    // 3. Run the RE-ENCODED program on the Dart reference engine (ground truth).
    let (code, stdout, stderr) = match run_dart(dart, &ball_json, root) {
        Ok(result) => result,
        Err(e) if e == "__timeout__" => {
            return Outcome::of(
                "timeout",
                format!("killed after {}s", DART_TIMEOUT.as_secs()),
            );
        }
        Err(e) => return Outcome::of("error", format!("dart exec: {e}")),
    };

    let actual = split_lines(&stdout);
    let expected = split_lines(golden);
    if actual == expected {
        return Outcome::pass();
    }
    if code != 0 {
        let detail = stderr
            .lines()
            .last()
            .unwrap_or("dart run failed")
            .to_string();
        return Outcome::of("error", format!("dart run exited {code}: {detail}"));
    }
    Outcome::of(
        "fail",
        format!(
            "expected({}): {} | actual({}): {}",
            expected.len(),
            expected.first().map(String::as_str).unwrap_or("<none>"),
            actual.len(),
            actual.first().map(String::as_str).unwrap_or("<none>"),
        ),
    )
}

fn first_line(text: &str) -> String {
    let line = text.lines().next().unwrap_or(text);
    if line.chars().count() <= 200 {
        line.to_string()
    } else {
        line.chars().take(200).collect::<String>() + "…"
    }
}

#[test]
#[ignore = "whole-corpus round-trip sweep — run explicitly with --ignored (needs the Dart CLI)"]
fn roundtrip_conformance() {
    let root = repo_root();
    let dir = conformance_dir();
    let only = std::env::var("BALL_FIXTURE").unwrap_or_default();
    let dart = dart_executable();

    let workdir = std::env::temp_dir().join(format!("ball_rust_roundtrip_{}", std::process::id()));
    std::fs::create_dir_all(&workdir).expect("failed to create the scratch directory");

    let mut paths: Vec<PathBuf> = std::fs::read_dir(&dir)
        .unwrap_or_else(|e| panic!("failed to read {}: {e}", dir.display()))
        .filter_map(|entry| entry.ok().map(|e| e.path()))
        .filter(|p| p.to_string_lossy().ends_with(".ball.json"))
        .collect();
    paths.sort();

    let (mut passed, mut failed, mut skipped) = (0usize, 0usize, 0usize);
    for path in &paths {
        let file_name = path.file_name().unwrap().to_string_lossy().into_owned();
        let name = file_name.trim_end_matches(".ball.json").to_string();
        let golden_path = path.with_file_name(format!("{name}.expected_output.txt"));
        let Ok(golden) = std::fs::read_to_string(&golden_path) else {
            skipped += 1; // documented carve-out (no golden) — never counted
            continue;
        };
        if !only.is_empty() && name != only {
            continue;
        }

        let outcome = round_trip_one(&name, path, &golden, &dart, &root, &workdir);
        if outcome.status == "pass" {
            passed += 1;
        } else {
            failed += 1;
            println!("FAILING [{name}] {} {}", outcome.status, outcome.detail);
        }
    }

    let _ = std::fs::remove_dir_all(&workdir);
    let total = passed + failed;
    println!(
        "Results: {passed} passed, {failed} failed, {total} total ({skipped} skipped carve-outs)"
    );

    // Positive floor only — an exit code plus a failure count cannot tell "all
    // passed" from "nothing ran". The failure count itself is reported, never
    // gated on: this leg is a measurement (see the module doc comment).
    assert!(
        total >= 1,
        "the round-trip leg measured nothing (total={total})"
    );
}
