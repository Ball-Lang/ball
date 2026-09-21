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
//! ## A PR gate, but not from `cargo test`
//!
//! `#[ignore]` by default (a long, whole-corpus sweep that shells out to Dart),
//! so `cargo test --workspace` in the PR-gated `Rust` CI job never runs it. Its
//! CI home is the `rust-roundtrip` row in
//! `.github/workflows/conformance-matrix.yml`, which since #619 has a
//! path-filtered `pull_request` trigger sharing its `push` filter — so the row
//! runs on any PR touching `rust/**` with no dispatch. `tools/ci/roundtrip_floor.sh`
//! gates harness health (a parseable `Results:` line, integer counts,
//! `total >= 1`), `passed >= 1`, the `RUST_ROUNDTRIP_FLOOR` ratchet, and — since
//! #693 — that no fixture TIMED OUT. Never the failure count itself. Run it
//! explicitly:
//!
//! ```bash
//! cargo test -p ball-lang-engine --test roundtrip_conformance -- --ignored --nocapture
//! ```
//!
//! `BALL_FIXTURE=<name>` runs a single fixture; `BALL_DART=<path>` overrides the
//! Dart launcher; `BALL_TIMEOUT_MS=<ms>` overrides the per-fixture budget
//! (default 60 000 — the same spelling Go's leg uses).
//!
//! ## The row names its own leaders (issue #790)
//!
//! The sweep prints a `Failure buckets (cause -> fixtures), most frequent
//! first:` block before its `Results:` line, one line per CAUSE
//! ([`failure_bucket`]), ranked by how many fixtures it dams.
//!
//! Without it the only per-failure output is `roundtrip_floor.sh`'s "first
//! still-failing fixture", which is the **alphabetically** first one — and
//! reading that as "the leader" is how `rust/AGENTS.md` came to publish
//! `ball_message_type_name` (23 fixtures) as the leader at 138 when the real
//! leader was `ball_arg_get` (63), a bucket 2.7x larger. A row whose leaders
//! have to be re-derived by hand from `--nocapture` output is a row whose
//! published leaders rot; the histogram is re-derived every run, and the sweep
//! asserts it totals to `failed` so it can never be a number no run produced.
//!
//! ## The harness must not be able to hang
//!
//! A re-encoded program that never terminates is the #55 class: it type-checks,
//! `ball check` accepts it, and the only symptom is that it does not stop.
//! Issue #693 is the measured instance — 28 loop fixtures re-encoded "clean"
//! and hung, every one of them killed by the per-fixture budget below. That
//! budget is the difference between a leg that REPORTS 28 hangs and a leg that
//! wedges its own 90-minute job, so it is self-tested on a fabricated runaway
//! (`a_runaway_fixture_is_killed_at_the_budget_and_reported_as_a_timeout`)
//! rather than assumed from reading the poll loop, and a `timeout` outcome is a
//! hard error in `tools/ci/roundtrip_floor.sh` rather than one more increment
//! of `failed`.
use std::panic::{self, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use ball_lang_compiler::Compiler;
use ball_lang_shared::DESCRIPTOR_POOL;
use ball_lang_shared::proto::ball::v1::Program;
use prost::Message;
use prost_reflect::{DynamicMessage, SerializeOptions};

/// Per-fixture wall-clock budget for the Dart run, in milliseconds.
///
/// A re-encoded program that never terminates is the #55 class — it is not
/// caught by anything upstream, because it type-checks and `ball check` accepts
/// it — so the sweep must kill it rather than wait. Issue #693's 28 loop
/// fixtures are what that budget is for.
const DEFAULT_TIMEOUT_MS: u64 = 60_000;

/// One `BALL_TIMEOUT_MS` spelling -> a budget; `None` (unset) is
/// [`DEFAULT_TIMEOUT_MS`].
///
/// Deliberately PURE, so the budget's rules are provable without writing the
/// environment. `std::env::set_var` is `unsafe` precisely because another
/// thread may be inside `getenv`, and libtest runs a target's tests
/// concurrently — so a self-test that SET the variable could only be justified
/// by "nothing else runs in this process", a claim that was already false here
/// (`the_repo_root_handed_to_the_dart_cli_is_not_a_verbatim_path` is a second
/// non-`#[ignore]`d test) and that every test added to this file falsifies
/// again. Parsing through a seam costs nothing and keeps the proof honest.
fn parse_timeout(raw: Option<&str>) -> Duration {
    match raw {
        Some(raw) => {
            // Fail loud: a typo'd budget must never fall back to the default and
            // report a number nobody asked for.
            let ms: u64 = raw.trim().parse().unwrap_or_else(|_| {
                panic!(
                    "BALL_TIMEOUT_MS is {raw:?}, not a whole number of milliseconds — refusing to \
                     silently fall back to {DEFAULT_TIMEOUT_MS}ms"
                )
            });
            assert!(ms >= 1, "BALL_TIMEOUT_MS must be at least 1ms, got {ms}");
            Duration::from_millis(ms)
        }
        None => Duration::from_millis(DEFAULT_TIMEOUT_MS),
    }
}

/// The per-fixture budget, overridable through `BALL_TIMEOUT_MS` — the same
/// spelling `go/engine/conformance/roundtrip.go` uses.
///
/// An operator needs it to shorten a sweep on a slow machine. A budget that
/// cannot be reached from a test is a budget nobody has measured, so it is
/// reached in two halves that are each pinned below: [`parse_timeout`] owns the
/// spelling, and [`run_dart`] takes the budget as an ARGUMENT so the runaway
/// self-test can prove the kill in milliseconds without touching the
/// environment.
fn fixture_timeout() -> Duration {
    parse_timeout(std::env::var("BALL_TIMEOUT_MS").ok().as_deref())
}

fn repo_root() -> PathBuf {
    let canonical = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("the repo root must resolve from rust/engine");
    strip_verbatim_prefix(&canonical)
}

/// Drop Windows' `\\?\` VERBATIM prefix, which `Path::canonicalize` always
/// returns there.
///
/// Not cosmetic, and not Windows-pedantry: a verbatim path is not a path every
/// tool accepts, and the Dart CLI is one that does not — handed
/// `\\?\D:\…\ball.dart` it prints `\\?\ prefix is not supported` on stderr and
/// **exits 0**. So the sweep's `code != 0` arm never fired; every fixture came
/// back as a golden MISMATCH (`expected(5): 1 | actual(0): <none>`) and the leg
/// reported a confident `Results: 0 passed` that was entirely an artifact of the
/// launcher. A measurement that is silently wrong is worse than one that fails,
/// which is why this is stripped rather than worked around at the call site.
/// (CI runs the row on `ubuntu-latest`, where `canonicalize` adds no prefix, so
/// the row itself was never affected — only every local Windows run of it.)
///
/// A verbatim UNC path (`\\?\UNC\server\share`) maps back to `\\server\share`;
/// anything else keeps its own spelling.
fn strip_verbatim_prefix(path: &Path) -> PathBuf {
    let text = path.to_string_lossy();
    if let Some(rest) = text.strip_prefix(r"\\?\UNC\") {
        return PathBuf::from(format!(r"\\{rest}"));
    }
    match text.strip_prefix(r"\\?\") {
        Some(rest) => PathBuf::from(rest),
        None => path.to_path_buf(),
    }
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

fn run_dart(
    dart: &str,
    ball_json: &Path,
    root: &Path,
    budget: Duration,
) -> Result<(i32, String, String), String> {
    // `Command` has no built-in timeout; the Dart CLI's own engine is not
    // driven here with a budget, so a runaway fixture would hang. Spawn and
    // poll so a hung child is killed rather than wedging the sweep. The budget
    // is a PARAMETER rather than a read of `fixture_timeout()` so the runaway
    // self-test can shorten it to milliseconds without writing the environment
    // out from under the other tests sharing this process (see
    // [`parse_timeout`]).
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

    let deadline = std::time::Instant::now() + budget;
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
    let budget = fixture_timeout();
    let (code, stdout, stderr) = match run_dart(dart, &ball_json, root, budget) {
        Ok(result) => result,
        Err(e) if e == "__timeout__" => {
            return Outcome::of("timeout", format!("killed after {budget:?}"));
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

// ════════════════════════════════════════════════════════════════════════════
// Bucketing a failure by its CAUSE — the row naming its own leaders (#790)
// ════════════════════════════════════════════════════════════════════════════

/// Longest bucket key printed before it is elided. Long enough to separate two
/// neighbouring causes, short enough that the histogram stays a column.
const MAX_BUCKET_KEY: usize = 60;

/// `text`, cut to [`MAX_BUCKET_KEY`] CHARACTERS (never bytes — a detail line
/// carries `—` and `…`, and slicing one mid-codepoint would panic).
fn truncate_key(text: &str) -> String {
    if text.chars().count() <= MAX_BUCKET_KEY {
        text.to_string()
    } else {
        text.chars().take(MAX_BUCKET_KEY).collect::<String>() + "…"
    }
}

/// One failure's CAUSE, as a key stable enough to count.
///
/// The two shapes that dominate this leg both name the thing the encoder
/// refused in their first clause, so the key is that name and nothing else:
///
/// * ``unsupported runtime helper `ball_arg_get(...)` — …`` -> ``unsupported
///   runtime helper `ball_arg_get` `` (every fixture blocked on one compiler
///   helper is ONE line, not 63);
/// * ``unsupported call target `BallFlow :: Normal (ball_throw ({ … ``  ->
///   ``unsupported call target `BallFlow :: Normal` `` — the path HEAD, since
///   the operand is a whole compiled sub-expression that differs per fixture.
///
/// Everything else keeps its status plus a truncated detail, which fragments
/// the tail — deliberately: the tail is where a NEW cause first shows up, and
/// collapsing it into one "other" bucket would hide exactly that.
fn failure_bucket(status: &str, detail: &str) -> String {
    // The refusals are multi-line `panic!` messages that `first_line` has
    // already flattened and truncated; collapse the continuation indentation so
    // the key does not carry the panic's own wrapping.
    let collapsed = detail.split_whitespace().collect::<Vec<_>>().join(" ");

    if let Some((_, rest)) = collapsed.split_once("unsupported runtime helper `") {
        let name = rest.split('(').next().unwrap_or(rest).trim();
        return format!("unsupported runtime helper `{}`", truncate_key(name));
    }
    if let Some((_, rest)) = collapsed.split_once("unsupported call target `") {
        let head = rest.split(['(', '{', '`']).next().unwrap_or(rest).trim();
        return format!("unsupported call target `{}`", truncate_key(head));
    }

    match status {
        // A golden diff's detail is the fixture's own first line of output, so
        // it is unique per fixture and would make one bucket each.
        "fail" => "golden mismatch".to_string(),
        "timeout" => "timeout".to_string(),
        other => format!("{other}: {}", truncate_key(&collapsed)),
    }
}

/// `(status, detail)` pairs -> `(bucket, fixtures)`, most frequent FIRST.
///
/// Frequency order is the whole point: this row exists to say where the corpus
/// is dammed, and `roundtrip_floor.sh`'s "first still-failing fixture" line is
/// the alphabetically-first failure, which is a different question (see
/// `a_failure_is_bucketed_by_its_cause_not_by_its_fixture`). Ties break on the
/// key so two runs of the same tree print byte-identical blocks and a diff
/// between runs means something.
fn failure_histogram(failures: &[(String, String)]) -> Vec<(String, usize)> {
    let mut counts: std::collections::BTreeMap<String, usize> = std::collections::BTreeMap::new();
    for (status, detail) in failures {
        *counts.entry(failure_bucket(status, detail)).or_default() += 1;
    }
    let mut ranked: Vec<(String, usize)> = counts.into_iter().collect();
    ranked.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    ranked
}

// ════════════════════════════════════════════════════════════════════════════
// The harness's own correctness: the launcher path, and the per-fixture budget
// ════════════════════════════════════════════════════════════════════════════

/// **The root this sweep hands the Dart CLI must be a path the Dart CLI
/// accepts.** On Windows `canonicalize` returns a `\\?\` VERBATIM path, and
/// `dart run \\?\…\ball.dart` prints `\\?\ prefix is not supported` and exits
/// **0** — so the sweep's `code != 0` arm never fires and every fixture is
/// reported as a golden mismatch instead. That is a silently wrong measurement,
/// which is exactly what a measurement row must never produce, so the prefix is
/// stripped ([`strip_verbatim_prefix`]) and asserted here rather than assumed.
///
/// Both halves matter. The prefix assertion alone would pass on a root that no
/// longer points at anything, so the launcher script this sweep actually runs
/// has to exist under it — the positive floor.
#[test]
fn the_repo_root_handed_to_the_dart_cli_is_not_a_verbatim_path() {
    let root = repo_root();
    let text = root.to_string_lossy().into_owned();
    assert!(
        !text.starts_with(r"\\?\"),
        "repo_root() must not carry Windows' verbatim prefix — the Dart CLI rejects one and \
         exits 0, turning every fixture into a phantom golden mismatch: {text}"
    );
    let launcher = root.join("dart/cli/bin/ball.dart");
    assert!(
        launcher.is_file(),
        "…and it must still resolve the launcher this sweep runs: {}",
        launcher.display()
    );

    // The mapping itself, on both spellings, independent of the host OS.
    assert_eq!(
        strip_verbatim_prefix(Path::new(r"\\?\D:\packages\ball")),
        PathBuf::from(r"D:\packages\ball")
    );
    assert_eq!(
        strip_verbatim_prefix(Path::new(r"\\?\UNC\host\share\ball")),
        PathBuf::from(r"\\host\share\ball")
    );
    assert_eq!(
        strip_verbatim_prefix(Path::new("/home/runner/work/ball/ball")),
        PathBuf::from("/home/runner/work/ball/ball")
    );
}

/// A fabricated runaway: a program that ignores every argument and never exits.
/// Compiled with `rustc` at test time rather than shipped as a `[[bin]]` — a
/// binary whose whole purpose is to hang has no business inside the published
/// `ball-lang-engine` crate, and `rustc` is on `PATH` wherever `cargo test` can
/// run at all.
const RUNAWAY_SOURCE: &str =
    "fn main() { loop { std::thread::sleep(std::time::Duration::from_secs(3600)); } }";

/// Build [`RUNAWAY_SOURCE`] and return the executable's path.
fn build_runaway_launcher(dir: &Path) -> PathBuf {
    std::fs::create_dir_all(dir).expect("failed to create the runaway scratch directory");
    let source = dir.join("runaway.rs");
    std::fs::write(&source, RUNAWAY_SOURCE).expect("failed to write the runaway source");
    let exe = dir.join(if cfg!(windows) {
        "ball_runaway.exe"
    } else {
        "ball_runaway"
    });
    let status = Command::new("rustc")
        .arg("--edition")
        .arg("2021")
        .arg("-o")
        .arg(&exe)
        .arg(&source)
        .current_dir(dir)
        .status()
        .expect("could not run `rustc` to build the fabricated runaway");
    assert!(
        status.success(),
        "rustc failed to build the fabricated runaway (exit {status:?})"
    );
    exe
}

/// **The `BALL_TIMEOUT_MS` spelling is part of the contract**, not an
/// implementation detail: `go/engine/conformance/roundtrip.go` reads the same
/// one, and an operator shortening a sweep on a slow machine has nothing else
/// to reach for. Since [`run_dart`] now takes the budget as an argument — so
/// the runaway self-test below never writes the environment out from under a
/// concurrently-running test — this pure parse is the half that proves the
/// spelling still reaches the sweep, and that a TYPO is loud rather than a
/// silent fall back to the production 60 s.
#[test]
fn the_per_fixture_budget_is_read_from_ball_timeout_ms() {
    assert_eq!(parse_timeout(Some("300")), Duration::from_millis(300));
    assert_eq!(parse_timeout(Some("  1500  ")), Duration::from_millis(1500));
    assert_eq!(
        parse_timeout(None),
        Duration::from_millis(DEFAULT_TIMEOUT_MS),
        "an unset BALL_TIMEOUT_MS must be the production budget"
    );

    // A budget nobody asked for is worse than no budget: `60s`/`1.5`/`-1` are
    // the spellings an operator actually types, and each one silently meaning
    // 60 000 ms would make a sweep's timings a fiction.
    for typo in ["", "60s", "1.5", "-1", "0"] {
        assert!(
            catch_panic_message(|| parse_timeout(Some(typo))).is_err(),
            "`BALL_TIMEOUT_MS={typo}` must fail loud, never fall back to {DEFAULT_TIMEOUT_MS}ms"
        );
    }
}

/// **The harness must not be able to hang.**
///
/// A sweep that shells out per fixture and waits without a budget is itself a
/// defect: the 28 loop fixtures of issue #693 re-encoded "clean" and then never
/// terminated, and without a per-fixture kill the leg would have wedged its
/// 90-minute job instead of reporting them. The kill therefore has to be proven
/// on a REAL runaway child, not assumed from reading the poll loop.
///
/// The budget reaches [`run_dart`] as an ARGUMENT, so this self-test proves
/// the kill in milliseconds instead of burning the production 60 s without
/// writing `BALL_TIMEOUT_MS` out from under the other tests sharing this
/// process. A hard-coded budget is an untestable budget; an environment write
/// in a concurrently-running test target is an `unsafe` nobody can justify
/// once a second test exists. The env SPELLING is pinned separately, by
/// `the_per_fixture_budget_is_read_from_ball_timeout_ms`.
#[test]
fn a_runaway_fixture_is_killed_at_the_budget_and_reported_as_a_timeout() {
    let root = repo_root();
    // Any real fixture path: the fabricated launcher never reads its arguments.
    let ball_json = conformance_dir().join("28_fibonacci.ball.json");
    assert!(
        ball_json.is_file(),
        "the self-test needs a real fixture path to hand the launcher: {}",
        ball_json.display()
    );

    let scratch = std::env::temp_dir().join(format!("ball_runaway_{}", std::process::id()));
    let runaway = build_runaway_launcher(&scratch);

    // Milliseconds, handed straight to `run_dart`: no environment write, and
    // nothing hard-coded inside the poll loop.
    let budget = Duration::from_millis(300);
    let started = std::time::Instant::now();
    let result = run_dart(&runaway.to_string_lossy(), &ball_json, &root, budget);
    let elapsed = started.elapsed();

    let _ = std::fs::remove_dir_all(&scratch);

    assert_eq!(
        result.as_ref().err().map(String::as_str),
        Some("__timeout__"),
        "a child that never exits must come back as the `__timeout__` sentinel \
         `round_trip_one` reports as the `timeout` status, not as a hang and not as a \
         generic error: {result:?}"
    );
    assert!(
        elapsed < Duration::from_secs(10),
        "the per-fixture budget must reach `run_dart` as an argument so the kill is provable \
         in milliseconds; the runaway was only killed after {elapsed:?}, which means the budget \
         is a hard-coded constant this self-test cannot reach"
    );
}

// ════════════════════════════════════════════════════════════════════════════
// The row must be able to name its own failure LEADERS (issue #790)
// ════════════════════════════════════════════════════════════════════════════

/// Real failure lines from this row's own CI log — run 35593505327, job
/// 106313208884 (`Results: 138 passed, 225 failed, 363 total`) — as
/// `(status, detail, the bucket the cause belongs in)`.
///
/// Copied verbatim, ellipsis and all: [`Outcome::of`] stores [`first_line`]'s
/// 200-character truncation, so this is exactly the text the bucketer sees at
/// run time. Fabricated strings would only prove the bucketer agrees with
/// whatever the test author imagined the harness prints.
const MEASURED_FAILURES: &[(&str, &str, &str)] = &[
    (
        "encode-error",
        "ball-lang-encoder: unsupported runtime helper `ball_arg_get(...)` —                  rust/encoder/src/runtime_helpers.rs lists the helpers that have a universal                  std inverse. Encoding …",
        "unsupported runtime helper `ball_arg_get`",
    ),
    (
        "encode-error",
        "ball-lang-encoder: unsupported runtime helper `ball_message_type_name(...)` —                  rust/encoder/src/runtime_helpers.rs lists the helpers that have a universal                  std inverse.…",
        "unsupported runtime helper `ball_message_type_name`",
    ),
    (
        "encode-error",
        "ball-lang-encoder: unsupported call target `BallFlow :: Normal (ball_throw ({ let mut __ball_map = BallMap :: new () ; BallValue :: Message (BallMessage :: new (\"main:NotFound\" , __ball_map)) }))` — a…",
        "unsupported call target `BallFlow :: Normal`",
    ),
    (
        "encode-error",
        "ball-lang-encoder: unsupported call target `BallValue :: Function (BallFunction :: new (\"label\" , move | __ball_arg : BallValue | -> BallValue { label (ball_arg0_with_self (__ball_arg , __self_recv . …",
        "unsupported call target `BallValue :: Function`",
    ),
    ("fail", "expected(8): int?:7 | actual(8): other", "golden mismatch"),
    (
        "error",
        "dart run exited 255: <asynchronous suspension>",
        "error: dart run exited 255: <asynchronous suspension>",
    ),
];

/// **A measurement row that cannot name its own leaders is not a measurement.**
///
/// This leg's only per-failure output is `roundtrip_floor.sh`'s "first
/// still-failing fixture" line, which is the ALPHABETICALLY first failure —
/// and reading that line as "the leader" is how `rust/AGENTS.md` came to name
/// `ball_message_type_name` (23 fixtures) as the leader at 138 while the real
/// leader was `ball_arg_get` (63), a bucket 2.7x larger. Issue #790 had to be
/// filed to re-derive by hand what the run already knew, so the bucketing is a
/// function of the harness and is pinned on the row's OWN measured strings.
///
/// A bucket is the CAUSE, never the fixture: the two shapes the compiler emits
/// most (`ball_*` runtime helpers, and paths like `BallFlow::Normal` that the
/// `syn` encoder refuses as call targets) each collapse to one key naming the
/// helper or the path head, so 63 fixtures blocked on one gap read as one line
/// instead of 63.
#[test]
fn a_failure_is_bucketed_by_its_cause_not_by_its_fixture() {
    for (status, detail, expected) in MEASURED_FAILURES {
        assert_eq!(
            failure_bucket(status, detail),
            *expected,
            "a `{status}` failure must bucket by its cause; detail was: {detail}"
        );
    }
}

/// The histogram is ordered by frequency (the leader first — the whole point)
/// and TOTALS to the failure count, so a bucket can never silently swallow or
/// duplicate a fixture. Ties break on the key so the printed block is stable
/// run to run and a diff of two runs means something.
#[test]
fn the_histogram_orders_by_frequency_and_accounts_for_every_failure() {
    let pick = |bucket: &str| {
        let (status, detail, _) = MEASURED_FAILURES
            .iter()
            .find(|(_, _, expected)| *expected == bucket)
            .unwrap_or_else(|| panic!("no measured failure buckets as `{bucket}`"));
        (status.to_string(), detail.to_string())
    };

    let arg_get = pick("unsupported runtime helper `ball_arg_get`");
    let type_name = pick("unsupported runtime helper `ball_message_type_name`");
    let flow = pick("unsupported call target `BallFlow :: Normal`");
    let failures = vec![
        type_name.clone(),
        arg_get.clone(),
        flow.clone(),
        arg_get.clone(),
        type_name,
        flow,
        arg_get,
    ];

    let histogram = failure_histogram(&failures);
    assert_eq!(
        histogram,
        vec![
            ("unsupported runtime helper `ball_arg_get`".to_string(), 3),
            ("unsupported call target `BallFlow :: Normal`".to_string(), 2),
            ("unsupported runtime helper `ball_message_type_name`".to_string(), 2),
        ],
        "the histogram must rank by count (leader first) and break ties on the key"
    );
    assert_eq!(
        histogram.iter().map(|(_, count)| count).sum::<usize>(),
        failures.len(),
        "every failure must land in exactly one bucket — a histogram that does not add up to \
         the failure count is reporting a number no run produced"
    );
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
    let mut failures: Vec<(String, String)> = Vec::new();
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
            failures.push((outcome.status.to_string(), outcome.detail.clone()));
            println!("FAILING [{name}] {} {}", outcome.status, outcome.detail);
        }
    }

    let _ = std::fs::remove_dir_all(&workdir);
    let total = passed + failed;

    // The row naming its own leaders (#790). Without this block the only
    // per-failure output is `roundtrip_floor.sh`'s ALPHABETICALLY first
    // failure, and reading that as "the leader" is how `rust/AGENTS.md` came to
    // publish `ball_message_type_name` (23) as the leader at 138 when it was
    // `ball_arg_get` (63).
    let histogram = failure_histogram(&failures);
    println!();
    println!("Failure buckets (cause -> fixtures), most frequent first:");
    for (bucket, count) in &histogram {
        println!("  {count:>4}  {bucket}");
    }
    println!();
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
    // ...and the histogram must account for every one of them: a block that
    // does not add up to `failed` is publishing a number no run produced, which
    // is the failure mode this whole block exists to end.
    let bucketed: usize = histogram.iter().map(|(_, count)| count).sum();
    assert!(
        bucketed == failed,
        "the failure histogram totals {bucketed} fixtures but {failed} failed — a block that \
         does not add up is publishing a number no run produced"
    );
}
