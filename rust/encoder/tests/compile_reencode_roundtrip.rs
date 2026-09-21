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
//! Three of the stages here are the library-mode ones on purpose: that is the
//! pipeline Tier A actually measures. The *script*-mode `compile()` wraps the
//! entry body in an immediately-invoked closure Tier A never reaches, so it
//! gets its own leg at the foot of this file (issue #687) — a re-encode of the
//! compiled entry point, plus two RUN-proofs, because the closure is not
//! interchangeable with the block it wraps: a Rust `return` inside it leaves
//! the CLOSURE, while a Ball `return` inside a `block` leaves the enclosing
//! FUNCTION.
//!
//! ## Stage 3 is an ENCODE gate, and the run-proofs sit beside it
//!
//! Stage 3's output is compiled and run for ONE program — the constructs #692
//! taught the encoder, in
//! [`re_compiling_the_re_encoded_program_still_computes_the_same_answer`] — and
//! for nothing else, and neither Tier A nor this test should pretend otherwise:
//! the compiler's output names runtime helpers (`ball_message_type_name`, …)
//! that are not user functions, so **re-compiling stage 3's output is not a
//! fixpoint at large**. What stage 3 measures for every other program is
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

// ════════════════════════════════════════════════════════════════════════════
// SCRIPT mode, and the immediately-invoked closure (issue #687)
// ════════════════════════════════════════════════════════════════════════════

/// Ordinary hand-written Rust using the early-exit idiom: a zero-argument
/// closure invoked on the spot, with a `return` inside it. A Rust `return`
/// there leaves the CLOSURE — `code` is bound to `10` and `classify` keeps
/// running — which is the whole reason the idiom exists.
///
/// `flag` is threaded through both arms so one run proves the taken
/// (`return 10`) and the fallen-through (`20`) path: a fixture exercising only
/// the early return could not tell a correct encoding from one that dropped
/// the closure body entirely.
const IIFE_EARLY_RETURN_SOURCE: &str = r#"
fn classify(flag: i64) -> i64 {
    let code = (|| -> i64 {
        if flag > 0 {
            return 10;
        }
        20
    })();
    println!("{}", code);
    code + 1
}

fn main() {
    println!("{}", classify(1));
    println!("{}", classify(0));
}
"#;

/// What `rustc` prints for [`IIFE_EARLY_RETURN_SOURCE`] itself — the reference
/// this round trip must reproduce. `classify(1)` binds `code = 10`, prints it
/// and returns `11`; `classify(0)` falls through to `20` and returns `21`.
const IIFE_EARLY_RETURN_EXPECTED_STDOUT: &str = "10\n11\n20\n21\n";

/// The entry body's own early exit — the behaviour the compiler's `fn main()`
/// IIFE exists for (#300). A Ball `return` here returns from the ENTRY
/// function, so `after` must never print.
const ENTRY_EARLY_RETURN_SOURCE: &str = r#"
fn main() {
    println!("before");
    if 1 > 0 {
        return;
    }
    println!("after");
}
"#;

/// `before` and nothing else: the `return` ends the entry body.
const ENTRY_EARLY_RETURN_EXPECTED_STDOUT: &str = "before\n";

/// `compile_entry_main`'s wrapper written out by hand — a zero-argument closure
/// with an early `return` that IS a whole function body. This is the shape the
/// entry-point IIFE takes, expressed as a construct this test owns, so its
/// behaviour can be run-proved through the round trip without re-compiling the
/// compiler's own output (see
/// [`an_entry_body_return_survives_the_compile_reencode_round_trip`] for why
/// that is off the table).
const ENTRY_SHAPED_WRAPPER_SOURCE: &str = r#"
fn entry_like(flag: i64) -> i64 {
    (|| -> i64 {
        println!("before");
        if flag > 0 {
            return 1;
        }
        println!("after");
        2
    })()
}

fn main() {
    println!("{}", entry_like(1));
}
"#;

/// The wrapper returns `1` to its caller and never reaches `after` — the exact
/// service the entry-point IIFE performs for `fn main()`.
const ENTRY_SHAPED_WRAPPER_EXPECTED_STDOUT: &str = "before\n1\n";

/// **The #687 run-proof.** RED before the fix.
///
/// `encode_call` inlined EVERY immediately-invoked zero-argument closure into
/// the Ball `block` its body already was. That is sound only while the body
/// cannot exit early: a Ball `return` inside a `block` returns from the
/// enclosing FUNCTION, while the Rust `return` it came from returned only from
/// the closure. So this fixture's `return 10` silently became "return 10 from
/// `classify`", `println!("{}", code)` never ran for the first call, and the
/// program printed `10\n20\n21\n` — a wrong answer no encode-shape assertion
/// could see, which is why it is proven by BUILDING and RUNNING the compiled
/// output against what `rustc` prints for the original source.
#[test]
fn an_immediately_invoked_closures_return_stays_inside_the_closure() {
    let program = ball_lang_encoder::encode(IIFE_EARLY_RETURN_SOURCE);
    let compiled = Compiler::new(&program).compile();
    let stdout = compile_and_run("iife_early_return", &compiled);
    assert_eq!(
        stdout, IIFE_EARLY_RETURN_EXPECTED_STDOUT,
        "a `return` inside an immediately-invoked closure must return from the CLOSURE, exactly \
         as it does in the Rust this was encoded from — inlining the closure into a Ball block \
         re-binds it to the enclosing function"
    );
}

/// The SCRIPT-mode leg of the compiler↔encoder round trip (#687), beside the
/// library-mode legs above. `Compiler::compile()` wraps the entry body in
/// `(|| -> BallValue { … })()`, a construct no library-mode stage ever
/// produces, so nothing in this file reached it.
///
/// The first assertion is a staleness guard, not decoration: if the compiler
/// ever stops emitting the wrapper, this test would keep passing while
/// exercising nothing.
#[test]
fn script_mode_compiler_output_re_encodes() {
    let program = ball_lang_encoder::encode(r#"fn main() { println!("{}", 6 * 7); }"#);
    let compiled = Compiler::new(&program).compile();
    assert!(
        compiled.contains("(|| -> BallValue {"),
        "script mode must still wrap the entry body in an immediately-invoked closure — \
         otherwise this test no longer exercises the construct it names:\n{compiled}"
    );

    let reencoded = ball_lang_encoder::encode(&compiled);
    assert_eq!(reencoded.entry_function, "main");
    let calls = std_calls(&reencoded);
    assert!(
        calls.iter().any(|name| name == "print"),
        "the entry body's `println!` must survive the round trip — a re-encode that dropped the \
         wrapper's body would still produce a structurally valid Program. std calls found: \
         {calls:?}"
    );
    assert!(
        calls.iter().any(|name| name == "multiply"),
        "the entry body's arithmetic must survive too. std calls found: {calls:?}"
    );
}

/// #687's second half: the entry IIFE is LOAD-BEARING (#300), so whatever shape
/// the encoder gives it must not cost the behaviour it buys.
///
/// Three steps. The third run-proves the wrapper's own semantics on a
/// hand-written construct of the same shape; the whole-program re-compile it
/// used to stand in for is now its own test — see
/// [`re_compiling_the_re_encoded_program_still_computes_the_same_answer`],
/// which #692 unblocked by teaching the encoder that
/// `pub fn __ball_register_types()` is the compiler's class prologue rather
/// than a user function (re-emitting it was `error[E0428]: the name
/// `__ball_register_types` is defined multiple times`).
#[test]
fn an_entry_body_return_survives_the_compile_reencode_round_trip() {
    // 1. The real entry point, end to end: Rust -> Ball -> Rust -> run.
    let program = ball_lang_encoder::encode(ENTRY_EARLY_RETURN_SOURCE);
    let compiled = Compiler::new(&program).compile();
    assert_eq!(
        compile_and_run("entry_return", &compiled),
        ENTRY_EARLY_RETURN_EXPECTED_STDOUT,
        "a `return` in the entry body must end the entry body"
    );

    // 2. Re-encoding that output keeps the early exit AND everything around it
    //    — a re-encode that dropped the wrapper's body would still yield a
    //    structurally valid Program.
    let reencoded = ball_lang_encoder::encode(&compiled);
    let calls = std_calls(&reencoded);
    assert!(
        calls.iter().any(|name| name == "return"),
        "the entry body's early exit must survive the re-encode. std calls found: {calls:?}"
    );
    assert_eq!(
        calls.iter().filter(|name| *name == "print").count(),
        2,
        "both `println!`s must survive, the unreachable one included — dropping it would be a \
         silent edit, not a round trip. std calls found: {calls:?}"
    );

    // 3. The wrapper's own semantics, run-proved on the construct rather than
    //    on the compiler's output: an early `return` inside a zero-argument
    //    closure that IS a function body yields to that function's caller.
    let wrapper = ball_lang_encoder::encode(ENTRY_SHAPED_WRAPPER_SOURCE);
    let wrapper_compiled = Compiler::new(&wrapper).compile();
    assert_eq!(
        compile_and_run("entry_shaped_wrapper", &wrapper_compiled),
        ENTRY_SHAPED_WRAPPER_EXPECTED_STDOUT,
        "the entry-point wrapper's shape must still stop at its `return` and hand the value to \
         its caller after the round trip"
    );
}

// ════════════════════════════════════════════════════════════════════════════
// The whole-program FIXPOINT (issue #692)
// ════════════════════════════════════════════════════════════════════════════

/// One class instance, one list literal, and a read out of each — the two
/// constructs #692 taught the encoder (the `BallMap::new()` message builder and
/// `BallValue::List(BallList::from(vec![…]))`), in a program small enough to
/// hand-compute.
const COLLECTION_AND_CLASS_SOURCE: &str = r#"
struct Point {
    x: i64,
    y: i64,
}

fn main() {
    let p = Point { x: 3, y: 4 };
    let xs = vec![10, 20, 30];
    println!("{}", p.x);
    println!("{}", xs[1]);
}
"#;

/// What `rustc` prints for [`COLLECTION_AND_CLASS_SOURCE`] itself.
const COLLECTION_AND_CLASS_EXPECTED_STDOUT: &str = "3\n20\n";

/// **The #692 run-proof, and the strongest gate in this file:** Rust -> Ball ->
/// Rust -> Ball -> Rust, BUILT and RUN at both ends, both times printing what
/// `rustc` prints for the original source.
///
/// The second compile is what makes this more than an encode-shape assertion.
/// A re-encode that read the message builder as *some* structurally valid node
/// — a block that mutates a map, say, or a call to a function nobody declares —
/// still yields a Program `ball check` accepts; only compiling it again and
/// running it can tell that node from the `message_creation` it came from.
///
/// It is also the fixpoint this file's module doc comment used to rule out: the
/// compiler's `pub fn __ball_register_types()` came back as an ordinary user
/// function, so a second compile emitted it twice
/// (`error[E0428]: the name `__ball_register_types` is defined multiple
/// times`). Recognizing it as the class prologue is half of #692, and this test
/// is where that half is observed rather than asserted about.
#[test]
fn re_compiling_the_re_encoded_program_still_computes_the_same_answer() {
    let stage1 = ball_lang_encoder::encode(COLLECTION_AND_CLASS_SOURCE);
    let stage2 = Compiler::new(&stage1).compile();
    assert_eq!(
        compile_and_run("fixpoint_stage2", &stage2),
        COLLECTION_AND_CLASS_EXPECTED_STDOUT,
        "the first compile must already reproduce what `rustc` prints for the source — \
         otherwise the second one is measuring nothing"
    );

    let stage3 = ball_lang_encoder::encode(&stage2);
    let stage4 = Compiler::new(&stage3).compile();
    assert_eq!(
        compile_and_run("fixpoint_stage4", &stage4),
        COLLECTION_AND_CLASS_EXPECTED_STDOUT,
        "re-compiling the RE-ENCODED program must still print the same answer: a message \
         builder or a list constructor read back as anything but the node it compiled from \
         would produce a valid Program with a different result"
    );
}
