//! The compiler↔encoder round trip (issue #632): every construct
//! `ball-lang-compiler` EMITS must be a construct `ball-lang-encoder` can read
//! back.
//!
//! ## What this gate is
//!
//! Tier A's Rust harness (`rust/tools/rq1-study`) runs three stages over each
//! third-party library file: **(1)** encode the Rust into Ball, **(2)** compile
//! that Ball back into Rust, **(3)** re-encode the compiled Rust. Stage 3 is
//! the only stage whose *input* is this repo's own output, and until this test
//! existed nothing in the test suite exercised it: `rust/compiler`'s tests
//! assert on emitted Rust and `rust/encoder`'s tests start from hand-written
//! Rust, so a construct the compiler emits and the encoder refuses was
//! invisible to both.
//!
//! It was not hypothetical. `type_emit.rs::compile_method_dispatchers` emits
//! one free dispatcher function per method short name, whose fallback arm was
//! a bare `panic!` — and `methods.rs::encode_macro` knew only
//! `println!`/`format!`/`vec!`. So **every** library with a struct and one
//! method failed stage 3 with ``unsupported macro invocation `panic!` ``.
//!
//! ## Why the assertions are what they are
//!
//! A shape assertion on the re-encoded Ball would pass on a `std.throw`
//! carrying the wrong message, and an encode-only assertion would pass on a
//! throw that no longer runs. So the round trip is closed all the way through
//! execution: the re-encoded program is compiled a SECOND time and run, and
//! its stdout must equal the original Rust source's own hand-computed output.
//! The fallback arm's *message* is asserted separately, because that string is
//! the value a Ball `catch` binds (`runtime.rs::ball_catch_payload` re-wraps a
//! non-Ball panic payload as `BallValue::String(message)`) and it is therefore
//! an observable the #616/#641 error-rendering contract governs.
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

use ball_lang_compiler::Compiler;
use ball_lang_shared::proto::ball::v1::expression::Expr;
use ball_lang_shared::proto::ball::v1::literal::Value as LiteralValue;
use ball_lang_shared::proto::ball::v1::statement::Stmt;
use ball_lang_shared::proto::ball::v1::{Expression, Program};

/// A struct with one instance method, called polymorphically — the smallest
/// source that makes `compile_method_dispatchers` emit a dispatcher with a
/// fallback arm. `3 + 4 == 7`, hand-computed from the Rust semantics.
const CLASS_WITH_METHOD_SOURCE: &str = r#"
struct Point {
    x: i64,
    y: i64,
}

impl Point {
    fn sum(&self) -> i64 {
        self.x + self.y
    }
}

fn main() {
    let p = Point { x: 3, y: 4 };
    println!("{}", p.sum());
}
"#;

const EXPECTED_STDOUT: &str = "7\n";

static FIXTURE_COUNTER: AtomicU64 = AtomicU64::new(0);

fn workspace_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("rust/encoder must have a parent directory")
        .to_path_buf()
}

/// Build and run `rust_src` in a scratch cargo package — the same harness
/// `end_to_end.rs`/`mixed_impl_items.rs` use (unique package/bin name so
/// parallel fixtures never collide; the shared workspace `target/` so the
/// already-built `ball-lang-shared` dependency tree is reused; every artifact
/// cleaned up, including on failure).
fn compile_and_run(fixture_name: &str, rust_src: &str) -> String {
    let workspace_root = workspace_root();
    let target_dir = workspace_root.join("target");
    let unique = FIXTURE_COUNTER.fetch_add(1, Ordering::Relaxed);
    let slug = format!("{fixture_name}_{}_{unique}", std::process::id());
    let fixture_dir = std::env::temp_dir().join(format!("ball_encoder_roundtrip_fixture_{slug}"));
    fs::create_dir_all(&fixture_dir).unwrap_or_else(|err| {
        panic!(
            "failed to create fixture dir {}: {err}",
            fixture_dir.display()
        )
    });

    let shared_path = workspace_root.join("shared");
    let bin_name = format!("ball_encoder_roundtrip_fixture_{slug}");
    let manifest = format!(
        "[package]\nname = \"{bin_name}\"\nversion = \"0.0.0\"\nedition = \"2024\"\npublish = false\n\n\
         [[bin]]\nname = \"{bin_name}\"\npath = \"main.rs\"\n\n\
         [dependencies]\nball-lang-shared = {{ path = {shared_path:?} }}\n",
    );
    fs::write(fixture_dir.join("Cargo.toml"), manifest)
        .expect("failed to write fixture Cargo.toml");
    fs::write(fixture_dir.join("main.rs"), rust_src).expect("failed to write fixture main.rs");

    let manifest_path = fixture_dir.join("Cargo.toml");
    let build = Command::new("cargo")
        .args(["build", "--quiet"])
        .arg("--manifest-path")
        .arg(&manifest_path)
        .arg("--target-dir")
        .arg(&target_dir)
        .output()
        .expect("failed to spawn `cargo build` — is cargo on PATH?");

    if !build.status.success() {
        let _ = fs::remove_dir_all(&fixture_dir);
        panic!(
            "fixture '{fixture_name}' failed to COMPILE.\n--- generated main.rs ---\n{rust_src}\n\
             --- stdout ---\n{}\n--- stderr ---\n{}",
            String::from_utf8_lossy(&build.stdout),
            String::from_utf8_lossy(&build.stderr),
        );
    }

    let exe = target_dir.join("debug").join(if cfg!(windows) {
        format!("{bin_name}.exe")
    } else {
        bin_name.clone()
    });
    let output = Command::new(&exe).output().unwrap_or_else(|err| {
        panic!(
            "fixture '{fixture_name}' built but its binary {} could not be run: {err}",
            exe.display()
        )
    });

    let _ = fs::remove_dir_all(&fixture_dir);
    let _ = fs::remove_file(&exe);
    for sidecar in ["d", "pdb"] {
        let _ = fs::remove_file(
            target_dir
                .join("debug")
                .join(format!("{bin_name}.{sidecar}")),
        );
    }

    if !output.status.success() {
        panic!(
            "fixture '{fixture_name}' failed to run.\n--- generated main.rs ---\n{rust_src}\n\
             --- stdout ---\n{}\n--- stderr ---\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }

    String::from_utf8(output.stdout).expect("fixture stdout must be valid UTF-8")
}

/// Every `std.<function>` called anywhere in `program`'s user modules.
fn std_calls(program: &Program) -> Vec<String> {
    let mut names = Vec::new();
    for module in &program.modules {
        if module.functions.iter().all(|f| f.is_base) {
            continue; // a base module declaration, not user code
        }
        for function in &module.functions {
            if let Some(body) = &function.body {
                collect_std_calls(body, &mut names);
            }
        }
    }
    names
}

fn collect_std_calls(expr: &Expression, out: &mut Vec<String>) {
    let Some(kind) = &expr.expr else { return };
    match kind {
        Expr::Call(call) => {
            if call.module == "std" {
                out.push(call.function.clone());
            }
            if let Some(input) = &call.input {
                collect_std_calls(input, out);
            }
        }
        Expr::MessageCreation(creation) => {
            for field in &creation.fields {
                if let Some(value) = &field.value {
                    collect_std_calls(value, out);
                }
            }
        }
        Expr::FieldAccess(access) => {
            if let Some(object) = &access.object {
                collect_std_calls(object, out);
            }
        }
        Expr::Block(block) => {
            for statement in &block.statements {
                match &statement.stmt {
                    Some(Stmt::Expression(inner)) => collect_std_calls(inner, out),
                    Some(Stmt::Let(binding)) => {
                        if let Some(value) = &binding.value {
                            collect_std_calls(value, out);
                        }
                    }
                    None => {}
                }
            }
            if let Some(result) = &block.result {
                collect_std_calls(result, out);
            }
        }
        Expr::Lambda(lambda) => {
            if let Some(body) = &lambda.body {
                collect_std_calls(body, out);
            }
        }
        Expr::Literal(literal) => {
            if let Some(LiteralValue::ListValue(list)) = &literal.value {
                for element in &list.elements {
                    collect_std_calls(element, out);
                }
            }
        }
        Expr::Reference(_) => {}
    }
}

/// Stage 1 → 2 → 3, the exact Tier A pipeline, closed through a second
/// compile and a real run.
#[test]
fn compiled_method_dispatcher_re_encodes_and_still_runs() {
    // ── Stage 1: Rust → Ball ──
    let program = ball_lang_encoder::encode(CLASS_WITH_METHOD_SOURCE);

    // ── Stage 2: Ball → Rust ──
    let compiled = Compiler::new(&program).compile();
    assert!(
        compiled.contains("pub fn sum(input: BallValue) -> BallValue"),
        "the compiler must emit a free dispatcher for `sum` — otherwise this test is not \
         exercising the construct it claims to:\n{compiled}"
    );

    // ── Stage 3: the compiler's own output → Ball ──
    // RED before issue #632's fix: `encode_macro` refused the dispatcher's
    // `panic!` fallback arm.
    let reencoded = ball_lang_encoder::encode(&compiled);

    let calls = std_calls(&reencoded);
    assert!(
        calls.iter().any(|name| name == "throw"),
        "the dispatcher's fallback arm must survive stage 3 as a `std.throw` — never be dropped \
         silently. std calls found: {calls:?}"
    );

    // ── The round trip is behaviour-preserving, not merely structural ──
    let recompiled = Compiler::new(&reencoded).compile();
    let stdout = compile_and_run("reencoded_dispatcher", &recompiled);
    assert_eq!(
        stdout, EXPECTED_STDOUT,
        "the twice-round-tripped program must still print what the original Rust prints"
    );
}

/// The compiler half of the agreement: the fallback arm's message is the value
/// a `catch` binds, and it must be spelled the same way every other target
/// spells it — `go/compiler/library.go`'s
/// `panic(ballrt.Thrown{Value: "no method '<name>' for " + __t})` and
/// `csharp/compiler/src/TypeEmit.cs`'s
/// `throw new BallRuntimeException($"no method '<name>' for {__t}")`.
#[test]
fn dispatcher_fallback_message_matches_the_other_targets() {
    let program = ball_lang_encoder::encode(CLASS_WITH_METHOD_SOURCE);
    let compiled = Compiler::new(&program).compile();

    assert!(
        compiled.contains(r#"panic!("no method 'sum' for {}", other)"#),
        "the dispatcher fallback must throw the target-neutral `no method '<name>' for <type>` \
         message — no `ball-lang-compiler runtime:` prefix that no other target emits:\n{compiled}"
    );
}

/// `panic!` outside a dispatcher: ordinary third-party Rust uses it too, and it
/// is Rust's spelling of Ball's `std.throw` (`runtime.rs::ball_throw` is
/// literally `std::panic::panic_any`). The formatted message travels through
/// the same `std.concat`/`std.to_string` chain `format!` already encodes to.
#[test]
fn a_formatted_panic_encodes_as_std_throw() {
    let source = r#"
fn main() {
    let code = 7;
    panic!("boom {}", code);
}
"#;
    let program = ball_lang_encoder::encode(source);
    let calls = std_calls(&program);
    assert!(
        calls.iter().any(|name| name == "throw"),
        "`panic!` must encode as `std.throw`. std calls found: {calls:?}"
    );
    assert!(
        calls.iter().any(|name| name == "concat"),
        "the panic message must keep its interpolation, as `format!` does. \
         std calls found: {calls:?}"
    );
}

/// `panic!()` with no arguments. Rust's own message for it is `explicit panic`
/// (the `core::panic!()` expansion — `panic!()` is defined to panic with that
/// message), so the encoded throw carries exactly that, never an empty string.
#[test]
fn a_bare_panic_encodes_the_message_rust_itself_prints() {
    let source = r#"
fn main() {
    panic!();
}
"#;
    let program = ball_lang_encoder::encode(source);
    let main_module = program
        .modules
        .iter()
        .find(|m| m.name == "main")
        .expect("encoded program must carry a `main` module");
    let main_fn = main_module
        .functions
        .iter()
        .find(|f| f.name == "main")
        .expect("encoded program must carry `main`");
    let rendered = format!("{:?}", main_fn.body);
    assert!(
        rendered.contains("explicit panic"),
        "a bare `panic!()` must carry Rust's own `explicit panic` message: {rendered}"
    );
}
