//! The compiler↔encoder round trip (issue #632): every construct
//! `ball-lang-compiler` EMITS must be a construct `ball-lang-encoder` can read
//! back.
//!
//! ## What this gate is
//!
//! Tier A's Rust harness (`rust/tools/rq1-study`) runs three stages over each
//! third-party library file: **(1)** `encode_library` the Rust into Ball,
//! **(2)** `compile_library` that Ball back into Rust, **(3)** `encode_library`
//! the compiled Rust again. Stage 3 is the only stage whose *input* is this
//! repo's own output, and until this test existed nothing in the suite
//! exercised it: `rust/compiler`'s tests assert on emitted Rust and
//! `rust/encoder`'s tests start from hand-written Rust, so a construct the
//! compiler emits and its own encoder refuses was invisible to both.
//!
//! It was not hypothetical. `type_emit.rs::compile_method_dispatchers` emits
//! one free dispatcher function per method short name, whose fallback arm was
//! a bare `panic!` — and `methods.rs::encode_macro` knew only
//! `println!`/`format!`/`vec!`. So **every** library with a struct and one
//! method failed stage 3 with ``unsupported macro invocation `panic!` ``.
//!
//! The three stages here are the library-mode ones on purpose: that is the
//! pipeline Tier A actually measures. The *script*-mode `compile()` wraps the
//! entry body in an immediately-invoked closure this encoder also cannot read
//! back — a second instance of the same invariant, in a shape Tier A never
//! reaches; it is pinned as its own documented gap in
//! `documented_gaps.rs::compiled_entry_point_iife_is_a_documented_gap` and
//! tracked as issue #687.
//!
//! ## Stage 3 is an ENCODE gate, and the run-proofs sit beside it
//!
//! Stage 3's output is deliberately **not** compiled and run here, and neither
//! Tier A nor this test should pretend otherwise: the compiler's output names
//! runtime helpers (`ball_field_get`, `ball_message_type_name`, …) that are not
//! user functions, so **re-compiling stage 3's output is not a fixpoint anyone
//! has claimed**. What stage 3 measures — the only thing it measures — is
//! whether the encoder can read the compiler's output at all.
//!
//! Since #646 that reading is fail-loud: `encoder/src/runtime_helpers.rs` maps
//! the helpers that have a universal-`std` inverse, and an UNMAPPED `ball_*`
//! aborts the file instead of becoming a same-file call to a function nobody
//! declared. That table covers the universal-`std` subset only, so a compiled
//! library naming any other helper stops at the first one — the dispatcher's
//! `ball_message_type_name` scrutinee is the instance that reached CI, pinned
//! as
//! `documented_gaps.rs::compiled_method_dispatcher_scrutinee_is_a_documented_gap`
//! and tracked as issue **#718**. Do not read a green run of this file as
//! "stage 3 is green for libraries at large"; the `documented_gaps.rs` pins
//! are the honest inventory.
//!
//! So the behavioural half is proven on the constructs themselves, each through
//! a real `cargo build` + run of compiler output driven by a hand-written
//! `main`:
//!
//! - `dispatcher_fallback_throws_the_target_neutral_message` reaches the
//!   dispatcher's fallback arm on purpose and prints the value a Ball `catch`
//!   would bind (`runtime.rs::ball_catch_payload` re-wraps a non-Ball panic
//!   payload as `BallValue::String(message)`). That message is an observable
//!   the #616/#641 error-rendering contract governs, so it is asserted as
//!   bytes.
//! - `a_formatted_panic_throws_the_message_rust_itself_would_print` does the
//!   same for the new `panic!` → `std.throw` arm on ordinary user code: the
//!   caught value must read exactly what the original Rust `panic!` says.
//! - `an_unreachable_throws_rusts_own_internal_error_message` does it for
//!   `unreachable!`, the SECOND macro the compiler emits
//!   (`base_call.rs::flow_propagation`). Its message is not the argument: Rust
//!   prefixes it with `internal error: entered unreachable code: `, so an
//!   encode-only assertion would pass on a throw that silently dropped the
//!   prefix a `catch` actually binds.
//!
//! ## Enumerate what the compiler emits — do not assume it is one construct
//!
//! #632 was found as a single `panic!`. Sweeping `rust/compiler/src` for
//! constructs inside EMITTED string literals found three more: `unreachable!`
//! (`flow_propagation`) and — in `compile_list_literal`'s imperative lowering,
//! which EVERY spliced collection literal goes through — `Vec::new()` together
//! with `matches!(__sp, BallValue::Null)`.
//!
//! `panic!` and `unreachable!` are mapped, and gated here. The list-literal
//! pair is not, and must not be: `matches!` is a pattern match over a
//! runtime-crate enum variant and `Vec::new()` an associated function on a
//! foreign type, so an encoder arm for either would encode a compiler-internal
//! spelling while still refusing every real-world occurrence. It is pinned
//! fail-loud as
//! `documented_gaps.rs::compiled_spliced_list_literal_is_a_documented_gap` and
//! tracked as issue #712, whose fix is compiler-side. Re-run that sweep when
//! you add a compiler emission shape — everything past the first construct was
//! invisible to the issue that named it.
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

use ball_lang_compiler::Compiler;
use ball_lang_shared::proto::ball::v1::expression::Expr;
use ball_lang_shared::proto::ball::v1::literal::Value as LiteralValue;
use ball_lang_shared::proto::ball::v1::statement::Stmt;
use ball_lang_shared::proto::ball::v1::{Expression, Program};

/// A library with one struct and one instance method — the smallest source
/// that makes `compile_method_dispatchers` emit a dispatcher with a fallback
/// arm.
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
"#;

/// A `main` the COMPILER did not write, appended to the compiled library so the
/// dispatcher can actually be run. It calls the dispatcher twice: once with a
/// real `Point` receiver (`3 + 4`, hand-computed from the Rust semantics
/// above), and once with a receiver of a type that owns no `sum`, so the
/// fallback arm fires and its thrown value is printed exactly as a Ball `catch`
/// would see it.
const DISPATCHER_DRIVER_MAIN: &str = r#"
fn main() {
    let mut fields = BallMap::new();
    fields.insert("x".to_string(), BallValue::Int(3));
    fields.insert("y".to_string(), BallValue::Int(4));
    let mut input = BallMap::new();
    input.insert(
        "self".to_string(),
        BallValue::Message(BallMessage::new("main:Point", fields)),
    );
    println!("{}", ball_to_string(sum(BallValue::Map(input))));

    let mut stranger = BallMap::new();
    stranger.insert(
        "self".to_string(),
        BallValue::Message(BallMessage::new("main:Stranger", BallMap::new())),
    );
    std::panic::set_hook(Box::new(|_| {}));
    let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        sum(BallValue::Map(stranger))
    }));
    let _ = std::panic::take_hook();
    let payload = outcome.err().expect("the dispatcher fallback arm must throw");
    println!("{}", ball_to_string(ball_catch_payload(payload)));
}
"#;

/// `7` from the real receiver, then the fallback arm's message — the same
/// string `go/compiler/library.go` and `csharp/compiler/src/TypeEmit.cs` throw.
const DISPATCHER_EXPECTED_STDOUT: &str = "7\nno method 'sum' for main:Stranger\n";

/// Ordinary user code whose only interesting construct is a formatted `panic!`.
const PANICKING_LIBRARY_SOURCE: &str = r#"
fn boom(code: i64) -> i64 {
    panic!("boom {}", code);
}
"#;

/// Calls the compiled `boom` and prints the value a Ball `catch` would bind.
const PANIC_DRIVER_MAIN: &str = r#"
fn main() {
    std::panic::set_hook(Box::new(|_| {}));
    let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        boom(BallValue::Int(7))
    }));
    let _ = std::panic::take_hook();
    let payload = outcome.err().expect("`panic!` must still throw after the round trip");
    println!("{}", ball_to_string(ball_catch_payload(payload)));
}
"#;

/// Byte-identical to what `panic!("boom {}", code)` itself prints for `code =
/// 7` — the whole point of routing the message through `format!`'s own
/// `std.concat`/`std.to_string` chain rather than dropping it.
const PANIC_EXPECTED_STDOUT: &str = "boom 7\n";

/// `unreachable!` in ordinary user code. The compiler emits this macro too
/// (`base_call.rs::flow_propagation`, for a `break`/`continue` inside a `try`
/// with no enclosing loop), so the round-trip invariant covers it.
const UNREACHABLE_LIBRARY_SOURCE: &str = r#"
fn impossible(state: i64) -> i64 {
    unreachable!("bad state {}", state);
}
"#;

/// Calls the compiled `impossible` and prints the value a Ball `catch` binds.
const UNREACHABLE_DRIVER_MAIN: &str = r#"
fn main() {
    std::panic::set_hook(Box::new(|_| {}));
    let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        impossible(BallValue::Int(9))
    }));
    let _ = std::panic::take_hook();
    let payload = outcome.err().expect("`unreachable!` must still throw after the round trip");
    println!("{}", ball_to_string(ball_catch_payload(payload)));
}
"#;

/// What Rust itself panics with for `unreachable!("bad state {}", 9)`:
/// `library/core/src/panic.rs`'s `unreachable_2021` expands to
/// `panic!("internal error: entered unreachable code: {}", format_args!(..))`.
/// The PREFIX is the part an encode-only assertion cannot see — a throw
/// carrying just `bad state 9` would look like a clean round trip and would
/// have changed what a `catch` binds.
const UNREACHABLE_EXPECTED_STDOUT: &str = "internal error: entered unreachable code: bad state 9\n";

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
            continue; // a base-module declaration, not user code
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

/// Stage 1 → 2, and the one property of the dispatcher stage 3 still turns on:
/// its fallback arm is a `panic!` — the construct #632 taught
/// `methods.rs::encode_macro` to read back as `std.throw`.
///
/// The FULL stage 1 → 2 → 3 round trip over a dispatcher is **open**, tracked
/// as issue #718 and pinned fail-loud by
/// `documented_gaps.rs::compiled_method_dispatcher_scrutinee_is_a_documented_gap`:
/// the dispatcher's scrutinee is `ball_message_type_name(&__self)`, a runtime
/// helper with no universal-`std` inverse, and since #646 an unmapped `ball_*`
/// is a hard refusal rather than a same-file call that would only die at run
/// time. That refusal fires one construct AHEAD of the `panic!`, which is why
/// this test asserts the arm from the compiled source and re-encodes the macro
/// on its own: the property #632 owns must not quietly ride on a round trip
/// that no longer reaches it.
#[test]
fn compiled_method_dispatcher_fallback_arm_is_the_mapped_panic_macro() {
    let program = ball_lang_encoder::encode_library(CLASS_WITH_METHOD_SOURCE);
    let compiled = Compiler::new(&program).compile_library();
    assert!(
        compiled.contains("pub fn sum(input: BallValue) -> BallValue"),
        "the compiler must emit a free dispatcher for `sum` — otherwise this test is not \
         exercising the construct it claims to:\n{compiled}"
    );
    assert!(
        compiled.contains("panic!(\"no method 'sum' for {}\", other)"),
        "the dispatcher's fallback arm must still be the `panic!` #632 mapped to `std.throw`, \
         carrying the target-neutral message:\n{compiled}"
    );

    // The mapping itself, observed rather than assumed — on the very macro that
    // arm is, a formatted `panic!`, encoded on its own so the dispatcher's
    // unrelated #718 refusal cannot mask it.
    let arm = ball_lang_encoder::encode_library(
        "fn fallback(t: i64) -> i64 { panic!(\"no method 'sum' for {}\", t); }",
    );
    let calls = std_calls(&arm);
    assert!(
        calls.iter().any(|name| name == "throw"),
        "the fallback arm's macro must encode as a `std.throw`. std calls found: {calls:?}"
    );
    let rendered = format!("{arm:?}");
    assert!(
        rendered.contains("no method 'sum' for "),
        "…carrying the dispatcher's own message, which is the value a Ball `catch` binds"
    );
}

/// The compiler half of the agreement, proven by running it: the fallback arm's
/// message is the value a `catch` binds, and it must be spelled the way every
/// other target spells it — `go/compiler/library.go`'s
/// `panic(ballrt.Thrown{Value: "no method '<name>' for " + __t})` and
/// `csharp/compiler/src/TypeEmit.cs`'s
/// `throw new BallRuntimeException($"no method '<name>' for {__t}")`. RED
/// before #632's fix, which dropped a `ball-lang-compiler runtime:` prefix no
/// other target emits.
#[test]
fn dispatcher_fallback_throws_the_target_neutral_message() {
    let program = ball_lang_encoder::encode_library(CLASS_WITH_METHOD_SOURCE);
    let compiled = Compiler::new(&program).compile_library();
    let stdout = compile_and_run(
        "dispatcher_fallback",
        &format!("{compiled}\n{DISPATCHER_DRIVER_MAIN}"),
    );
    assert_eq!(
        stdout, DISPATCHER_EXPECTED_STDOUT,
        "the dispatcher must compute the same value for a known receiver and throw the \
         target-neutral message for an unknown one"
    );
}

/// `panic!` outside a dispatcher: ordinary third-party Rust uses it too, and it
/// is Rust's spelling of Ball's `std.throw` (`runtime.rs::ball_throw` is
/// literally `std::panic::panic_any`). Proven end to end — encode → compile →
/// `cargo build` → run — because the message must survive, not merely the
/// throw: a caught value reading `boom ` or `` would round-trip just as
/// cleanly and be silently wrong.
#[test]
fn a_formatted_panic_throws_the_message_rust_itself_would_print() {
    let program = ball_lang_encoder::encode_library(PANICKING_LIBRARY_SOURCE);

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

    let compiled = Compiler::new(&program).compile_library();
    let stdout = compile_and_run(
        "formatted_panic",
        &format!("{compiled}\n{PANIC_DRIVER_MAIN}"),
    );
    assert_eq!(
        stdout, PANIC_EXPECTED_STDOUT,
        "the caught value must read exactly what the original Rust `panic!` prints"
    );
}

/// `panic!()` with no arguments. Rust's own message for it is `explicit panic`
/// (`core`'s `panic!()` expands to a `panic("explicit panic")` call), so the
/// encoded throw carries exactly that, never an empty string that would lose
/// the failure's identity.
#[test]
fn a_bare_panic_encodes_the_message_rust_itself_prints() {
    let program = ball_lang_encoder::encode_library("fn boom() { panic!(); }");
    let boom = program
        .modules
        .iter()
        .find(|m| m.name == "main")
        .expect("encoded program must carry a `main` module")
        .functions
        .iter()
        .find(|f| f.name == "boom")
        .expect("encoded program must carry `boom`")
        .clone();
    let rendered = format!("{:?}", boom.body);
    assert!(
        rendered.contains("explicit panic"),
        "a bare `panic!()` must carry Rust's own `explicit panic` message: {rendered}"
    );
}

/// `unreachable!` — the compiler's OTHER emitted macro — proven end to end, for
/// the same reason its `panic!` sibling is: the message must survive, and here
/// the message is not simply the argument. Rust prefixes it with
/// `internal error: entered unreachable code: `, and that whole string is what
/// `ball_catch_payload` hands a Ball `catch`.
#[test]
fn an_unreachable_throws_rusts_own_internal_error_message() {
    let program = ball_lang_encoder::encode_library(UNREACHABLE_LIBRARY_SOURCE);

    let calls = std_calls(&program);
    assert!(
        calls.iter().any(|name| name == "throw"),
        "`unreachable!` must encode as `std.throw`. std calls found: {calls:?}"
    );
    assert!(
        calls.iter().any(|name| name == "concat"),
        "the prefix and the formatted argument must be joined, not one or the other. \
         std calls found: {calls:?}"
    );

    let compiled = Compiler::new(&program).compile_library();
    let stdout = compile_and_run(
        "unreachable_macro",
        &format!("{compiled}\n{UNREACHABLE_DRIVER_MAIN}"),
    );
    assert_eq!(
        stdout, UNREACHABLE_EXPECTED_STDOUT,
        "the caught value must read exactly what Rust's own `unreachable!` prints, prefix included"
    );
}

/// `unreachable!()` with no arguments carries Rust's fixed message and nothing
/// else — no stray `": "` separator, which a naive prefix-plus-format encoding
/// would leave behind.
#[test]
fn a_bare_unreachable_encodes_the_message_rust_itself_prints() {
    let program = ball_lang_encoder::encode_library("fn stop() { unreachable!(); }");
    let stop = program
        .modules
        .iter()
        .find(|m| m.name == "main")
        .expect("encoded program must carry a `main` module")
        .functions
        .iter()
        .find(|f| f.name == "stop")
        .expect("encoded program must carry `stop`")
        .clone();
    let rendered = format!("{:?}", stop.body);
    assert!(
        rendered.contains("internal error: entered unreachable code"),
        "a bare `unreachable!()` must carry Rust's own message: {rendered}"
    );
    assert!(
        !rendered.contains("entered unreachable code: "),
        "with no arguments there is nothing to append, so the `: ` separator must not appear: \
         {rendered}"
    );
}
