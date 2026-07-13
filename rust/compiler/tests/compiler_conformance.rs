//! The **compiler**-conformance leg: the Ball -> Rust compiler swept over the
//! whole `tests/conformance/` corpus.
//!
//! `rust/engine/tests/self_host_conformance.rs` measures the *engine* leg (each
//! fixture interpreted by the self-hosted engine). This is its missing sibling:
//! each fixture is compiled Ball -> Rust with [`ball_lang_compiler::Compiler`],
//! built with the real `cargo`/`rustc` toolchain, executed, and its stdout
//! byte-compared to the fixture's `.expected_output.txt` golden. It is the same
//! shape as C#'s `csharp/engine/conformance/CompilerLeg.cs` (compile -> build ->
//! run -> diff), and it never touches the self-hosted engine, so it needs no
//! `self_host` feature.
//!
//! A fixture the compiler cannot emit for (a `panic!` out of `Compiler::compile`
//! — its documented fail-loud behavior for an unsupported shape) or whose emitted
//! Rust does not compile counts as a **failure, not a crash**: the leg's job is
//! an honest count. Nothing is skipped beyond the 4 documented behavioral
//! carve-outs (196_timeout / 197_memory_limit / 201_input_validation /
//! 202_sandbox_mode — the golden-less fixtures every runner skips, see
//! `tests/conformance/CARVEOUTS.md`).
//!
//! `#[ignore]` by default (a whole-corpus sweep that shells out to `cargo`):
//!
//! ```bash
//! cargo test -p ball-lang-compiler --test compiler_conformance \
//!   -- --ignored --nocapture
//! ```
//!
//! Set `BALL_FIXTURE=<name>` to sweep a single fixture (dumping its emitted
//! Rust / build error / actual-vs-expected), e.g. `BALL_FIXTURE=44_for_loop_basic`.
//!
//! ## Batching
//!
//! Rust builds are slow, and the naive shape — one throwaway Cargo package per
//! fixture, `cargo run` on each (what `tests/end_to_end.rs` does for its handful
//! of hand-picked fixtures) — pays cargo's per-invocation resolution, fingerprint
//! and link cost 320 times over, serially. Instead the whole corpus is emitted
//! into **one** Cargo package with one `src/bin/<fixture>.rs` per fixture, built
//! by a **single** `cargo build --keep-going` invocation:
//!
//! - one resolve/fingerprint pass, and `ball-lang-shared` + its dependency tree is
//!   built exactly once;
//! - cargo's jobserver compiles the ~320 bins in parallel across all cores
//!   (the naive per-fixture loop is inherently serial);
//! - `--keep-going` means one fixture whose emitted Rust fails to compile does
//!   not abort the other 319 — required for an honest count;
//! - `debug = 0` + `incremental = false` cut the per-bin link cost, which is what
//!   dominates when the bins themselves are small.
//!
//! Which bins actually built is read from cargo's `--message-format=json` stream
//! (`compiler-artifact` messages carry the executable path), not from a directory
//! listing — a stale binary from a previous run can therefore never be mistaken
//! for a fresh pass. Then each built binary is executed once (cheap) under a
//! wall-clock timeout.
use std::collections::BTreeMap;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use ball_lang_compiler::Compiler;
use ball_lang_shared::DESCRIPTOR_POOL;
use ball_lang_shared::proto::ball::v1::Program;
use prost::Message;
use prost_reflect::DynamicMessage;

/// Per-fixture wall-clock budget for *running* a built binary. A latent infinite
/// loop must not wedge the sweep.
const RUN_TIMEOUT: Duration = Duration::from_secs(60);

fn repo_root() -> PathBuf {
    let mut dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    loop {
        if dir.join("proto/ball/v1/ball.proto").is_file() {
            return dir;
        }
        assert!(
            dir.pop(),
            "repo root (containing proto/ball/v1/ball.proto) not found"
        );
    }
}

fn conformance_dir() -> PathBuf {
    repo_root().join("tests/conformance")
}

/// `rust/` — the cargo workspace root (this crate's parent).
fn rust_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("rust/compiler must have a parent")
        .to_path_buf()
}

/// Split captured bytes into golden-comparable lines. Applied identically to the
/// golden and to the binary's real stdout, so the comparison is symmetric: only
/// a CRLF (a Windows-checkout artifact — no engine ever *emits* one) is
/// normalized, a semantic lone `\r` inside a line survives on both sides, and the
/// single trailing empty produced by the trailing newline is dropped.
fn lines_of(bytes: &[u8]) -> Vec<String> {
    let text = String::from_utf8_lossy(bytes).replace("\r\n", "\n");
    let mut lines: Vec<String> = text.split('\n').map(|s| s.to_string()).collect();
    if lines.last().map(|s| s.is_empty()).unwrap_or(false) {
        lines.pop();
    }
    lines
}

fn load_program(path: &Path) -> Program {
    let json = fs::read_to_string(path)
        .unwrap_or_else(|err| panic!("failed to read {}: {err}", path.display()));
    let mut json_value: serde_json::Value =
        serde_json::from_str(&json).expect(".ball.json must be valid JSON");
    if let serde_json::Value::Object(map) = &mut json_value {
        map.remove("@type");
    }
    let descriptor = DESCRIPTOR_POOL
        .get_message_by_name("ball.v1.Program")
        .expect("ball.v1.Program must resolve from the embedded descriptor pool");
    let dynamic = DynamicMessage::deserialize(descriptor, json_value)
        .unwrap_or_else(|err| panic!("{} is not a ball.v1.Program: {err}", path.display()));
    Program::decode(dynamic.encode_to_vec().as_slice())
        .expect("re-encoded DynamicMessage must decode as a typed ball.v1.Program")
}

/// The panic message [`Compiler::compile`] raised, if it raised one. The compiler
/// is fail-loud by design (issue #55): an unsupported shape `panic!`s rather than
/// emitting something that would print a wrong answer. Here that is a *failure*,
/// not a crash — catch it and count it.
fn panic_message(payload: Box<dyn std::any::Any + Send>) -> String {
    if let Some(s) = payload.downcast_ref::<&str>() {
        (*s).to_string()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "panic (non-string payload)".to_string()
    }
}

#[derive(Debug)]
enum Status {
    Pass,
    /// `Compiler::compile` panicked — the compiler cannot emit this shape.
    CompileError(String),
    /// The emitted Rust did not compile (rustc rejected it).
    BuildError(String),
    /// The binary ran but its stdout did not match the golden.
    Fail {
        actual: Vec<String>,
        expected: Vec<String>,
        note: String,
    },
    /// The binary exceeded [`RUN_TIMEOUT`].
    Timeout,
}

/// Run `exe`, returning `(stdout_bytes, stderr_text, exit_ok)`, killing it after
/// [`RUN_TIMEOUT`]. Both pipes are drained on dedicated threads so a chatty
/// fixture cannot deadlock on a full pipe buffer.
fn run_binary(exe: &Path) -> Result<(Vec<u8>, String, bool), ()> {
    let mut child = Command::new(exe)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap_or_else(|e| panic!("failed to spawn {}: {e}", exe.display()));

    let mut out_pipe = child.stdout.take().expect("stdout piped");
    let mut err_pipe = child.stderr.take().expect("stderr piped");
    let out_reader = std::thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = out_pipe.read_to_end(&mut buf);
        buf
    });
    let err_reader = std::thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = err_pipe.read_to_end(&mut buf);
        buf
    });

    let start = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) => {
                if start.elapsed() > RUN_TIMEOUT {
                    let _ = child.kill();
                    let _ = child.wait();
                    break None;
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            Err(e) => panic!("try_wait on {}: {e}", exe.display()),
        }
    };

    let stdout = out_reader.join().unwrap_or_default();
    let stderr = String::from_utf8_lossy(&err_reader.join().unwrap_or_default()).to_string();
    match status {
        Some(status) => Ok((stdout, stderr, status.success())),
        None => Err(()),
    }
}

#[test]
#[ignore = "whole-corpus compile sweep (shells out to cargo); run explicitly with --ignored --nocapture"]
fn compiler_corpus() {
    let dir = conformance_dir();
    let single = std::env::var("BALL_FIXTURE").ok();

    let mut fixtures: Vec<PathBuf> = fs::read_dir(&dir)
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

    // ── Phase 1: compile every fixture Ball -> Rust ──────────────────────
    //
    // A fixture with no `.expected_output.txt` is a documented behavioral
    // carve-out (196_timeout / 197_memory_limit / 201_input_validation /
    // 202_sandbox_mode — see tests/conformance/CARVEOUTS.md). The Dart reference
    // runner skips those, and so does the engine leg, so skip them here too —
    // and nothing else.
    let mut skipped = 0usize;
    let mut expected_by_name: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut sources: BTreeMap<String, String> = BTreeMap::new();
    let mut statuses: BTreeMap<String, Status> = BTreeMap::new();

    // The compiler's fail-loud `panic!`s are *expected* signal here; silence the
    // default panic printer so a corpus sweep doesn't bury the report in
    // backtraces. Outcomes are reported by this harness itself.
    let default_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(|_| {}));

    for fixture in &fixtures {
        let name = fixture
            .file_name()
            .unwrap()
            .to_str()
            .unwrap()
            .trim_end_matches(".ball.json")
            .to_string();
        if let Some(only) = &single
            && &name != only
        {
            continue;
        }
        let golden_path = dir.join(format!("{name}.expected_output.txt"));
        let Ok(golden) = fs::read(&golden_path) else {
            skipped += 1;
            continue;
        };
        expected_by_name.insert(name.clone(), lines_of(&golden));

        let path = fixture.clone();
        let compiled = std::panic::catch_unwind(move || {
            let program = load_program(&path);
            Compiler::new(&program).compile()
        });
        match compiled {
            Ok(source) => {
                sources.insert(name, source);
            }
            Err(payload) => {
                statuses.insert(name, Status::CompileError(panic_message(payload)));
            }
        }
    }
    std::panic::set_hook(default_hook);

    let total = expected_by_name.len();
    assert!(
        total > 0,
        "no fixtures selected — corpus discovery is broken"
    );

    // ── Phase 2: one Cargo package, one build, N bins ────────────────────
    let pkg_dir = rust_root().join("target/compile_leg/pkg");
    let bin_dir = pkg_dir.join("src/bin");
    let target_dir = rust_root().join("target/compile_leg/target");
    let _ = fs::remove_dir_all(&bin_dir);
    fs::create_dir_all(&bin_dir).expect("create src/bin");

    let shared_path = rust_root().join("shared");
    // `[workspace]` makes this generated package its own workspace root, so
    // cargo does not reject it for living under `rust/`'s workspace without
    // being a member. `debug = 0` / `incremental = false`: the bins are small,
    // so linking (and debuginfo generation) is the dominant per-bin cost.
    let manifest = format!(
        "[workspace]\n\n\
         [package]\nname = \"ball_compile_leg\"\nversion = \"0.0.0\"\nedition = \"2024\"\npublish = false\n\n\
         [dependencies]\nball-lang-shared = {{ path = {shared_path:?} }}\n\n\
         [profile.dev]\ndebug = 0\nincremental = false\n"
    );
    fs::write(pkg_dir.join("Cargo.toml"), manifest).expect("write Cargo.toml");

    // Fixture names all match `[0-9a-z_]+`, but many *start with a digit*
    // (`44_for_loop_basic`), which is not a legal Rust/cargo target name — hence
    // the `f` prefix. Keep the map so results can be attributed back.
    let mut bin_to_fixture: BTreeMap<String, String> = BTreeMap::new();
    for (name, source) in &sources {
        let bin = format!("f{name}");
        fs::write(bin_dir.join(format!("{bin}.rs")), source)
            .unwrap_or_else(|e| panic!("write bin {bin}: {e}"));
        bin_to_fixture.insert(bin, name.clone());
    }

    eprintln!(
        "[compile-leg] {} fixtures emitted Rust, {} failed to compile; building one package with {} bins...",
        sources.len(),
        statuses.len(),
        sources.len()
    );
    let build_start = Instant::now();
    let output = Command::new("cargo")
        // Plain `json` (NOT `json-render-diagnostics`, which renders diagnostics
        // to stderr and drops them from the JSON stream): the `compiler-message`
        // records are how a build error is attributed back to its fixture.
        .args(["build", "--bins", "--keep-going", "--message-format=json"])
        .arg("--manifest-path")
        .arg(pkg_dir.join("Cargo.toml"))
        .arg("--target-dir")
        .arg(&target_dir)
        .stderr(Stdio::inherit())
        .output()
        .expect("failed to spawn `cargo build` — is cargo on PATH?");
    eprintln!(
        "[compile-leg] build finished in {:.1}s",
        build_start.elapsed().as_secs_f64()
    );

    // Which bins actually produced an executable *in this build* (fresh or
    // cached-and-verified) — read from cargo's JSON artifact stream, never from
    // a directory listing, so a stale binary can't fake a pass.
    let mut executables: BTreeMap<String, PathBuf> = BTreeMap::new();
    let mut build_errors: BTreeMap<String, String> = BTreeMap::new();
    for line in String::from_utf8_lossy(&output.stdout).lines() {
        let Ok(msg) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        match msg.get("reason").and_then(|r| r.as_str()) {
            Some("compiler-artifact") => {
                let Some(exe) = msg.get("executable").and_then(|e| e.as_str()) else {
                    continue;
                };
                if let Some(target) = msg.get("target").and_then(|t| t.get("name"))
                    && let Some(target) = target.as_str()
                    && bin_to_fixture.contains_key(target)
                {
                    executables.insert(target.to_string(), PathBuf::from(exe));
                }
            }
            Some("compiler-message") => {
                let level = msg
                    .get("message")
                    .and_then(|m| m.get("level"))
                    .and_then(|l| l.as_str())
                    .unwrap_or("");
                if level != "error" && level != "error: internal compiler error" {
                    continue;
                }
                let Some(target) = msg
                    .get("target")
                    .and_then(|t| t.get("name"))
                    .and_then(|n| n.as_str())
                else {
                    continue;
                };
                if !bin_to_fixture.contains_key(target) {
                    continue;
                }
                let text = msg
                    .get("message")
                    .and_then(|m| m.get("message"))
                    .and_then(|m| m.as_str())
                    .unwrap_or("rustc error");
                let code = msg
                    .get("message")
                    .and_then(|m| m.get("code"))
                    .and_then(|c| c.get("code"))
                    .and_then(|c| c.as_str())
                    .unwrap_or("");
                build_errors.entry(target.to_string()).or_insert_with(|| {
                    if code.is_empty() {
                        text.to_string()
                    } else {
                        format!("[{code}] {text}")
                    }
                });
            }
            _ => {}
        }
    }

    // ── Phase 3: run each built binary, diff stdout against the golden ───
    for (bin, name) in &bin_to_fixture {
        let expected = expected_by_name[name].clone();
        let Some(exe) = executables.get(bin) else {
            let err = build_errors.get(bin).cloned().unwrap_or_else(|| {
                "emitted Rust did not build (no artifact, no diagnostic)".into()
            });
            statuses.insert(name.clone(), Status::BuildError(err));
            continue;
        };
        match run_binary(exe) {
            Err(()) => {
                statuses.insert(name.clone(), Status::Timeout);
            }
            Ok((stdout, stderr, ok)) => {
                let actual = lines_of(&stdout);
                if actual == expected {
                    statuses.insert(name.clone(), Status::Pass);
                } else {
                    let note = if ok {
                        String::new()
                    } else {
                        // First *non-empty* stderr line: a Ball `throw` compiles to
                        // a `panic_any`, and the panic message is the actionable
                        // signal (the leading line is often blank).
                        let first = stderr
                            .lines()
                            .find(|l| !l.trim().is_empty())
                            .unwrap_or("<no stderr>");
                        format!(
                            " [exited non-zero: {}]",
                            first.chars().take(120).collect::<String>()
                        )
                    };
                    statuses.insert(
                        name.clone(),
                        Status::Fail {
                            actual,
                            expected,
                            note,
                        },
                    );
                }
            }
        }
    }

    // ── Report ───────────────────────────────────────────────────────────
    if let Some(only) = &single {
        if let Some(source) = sources.get(only) {
            eprintln!("--- emitted Rust ---\n{source}");
        }
        match statuses.get(only) {
            Some(Status::Fail {
                actual, expected, ..
            }) => {
                eprintln!("--- expected ({}) ---", expected.len());
                for l in expected {
                    eprintln!("  {l}");
                }
                eprintln!("--- actual ({}) ---", actual.len());
                for l in actual {
                    eprintln!("  {l}");
                }
            }
            Some(other) => eprintln!("--- {other:?} ---"),
            None => {}
        }
    }

    let passed = statuses
        .values()
        .filter(|s| matches!(s, Status::Pass))
        .count();
    let failed = total - passed;

    // The canonical summary line the conformance-matrix workflow greps. `total`
    // is the golden-having (executed) fixture count; the 4 behavioral carve-outs
    // are reported separately, never as passes.
    println!(
        "\nResults: {passed} passed, {failed} failed, {total} total ({skipped} skipped carve-outs)"
    );

    if failed > 0 {
        println!("\n--- failures ---");
        for (name, status) in &statuses {
            match status {
                Status::Pass => {}
                Status::CompileError(e) => println!(
                    "  {name}: COMPILE-ERROR {}",
                    e.lines()
                        .next()
                        .unwrap_or("")
                        .chars()
                        .take(160)
                        .collect::<String>()
                ),
                Status::BuildError(e) => println!(
                    "  {name}: BUILD-ERROR {}",
                    e.lines()
                        .next()
                        .unwrap_or("")
                        .chars()
                        .take(160)
                        .collect::<String>()
                ),
                Status::Timeout => println!("  {name}: TIMEOUT"),
                Status::Fail {
                    actual,
                    expected,
                    note,
                } => {
                    let a = actual.first().map(|s| s.as_str()).unwrap_or("<none>");
                    let e = expected.first().map(|s| s.as_str()).unwrap_or("<none>");
                    println!(
                        "  {name}: FAIL (got {} lines, want {}) first: {a:?} vs {e:?}{note}",
                        actual.len(),
                        expected.len()
                    );
                }
            }
        }
    }
}
