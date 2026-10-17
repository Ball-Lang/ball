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
//! - `compiled_method_dispatcher_real_fallback_arm_re_encodes` restores the
//!   composite property #685/#632 established and #718's fix narrowed away
//!   (issue **#761**): the dispatcher's REAL fallback arm, extracted from the
//!   compiler's own output — never retyped by hand — is what re-encodes, not
//!   a synthetic stand-in. See its own doc comment for why the WHOLE
//!   dispatcher (scrutinee included) still cannot be the thing re-encoded
//!   while #718 stays open.
//!
//! ## RED-first against REAL rustc, not this crate's own belief about it
//! (issues #754/#717)
//!
//! `a_bare_panic_encodes_the_message_rust_itself_prints` and
//! `a_bare_unreachable_encodes_the_message_rust_itself_prints` used to assert
//! only that the ENCODED Ball tree contained a hard-coded literal
//! (`"explicit panic"`, `"internal error: entered unreachable code"`) —
//! strings this crate itself believes real Rust prints, copied by hand from
//! `library/core/src/panic.rs`'s doc comments rather than observed. A future
//! Rust edition that reworded either message would leave this suite green
//! while `Ball catch` quietly started binding a message real `panic!()`/
//! `unreachable!()` no longer produces. Both tests — and
//! `an_unreachable_throws_rusts_own_internal_error_message`'s own
//! ARGUMENT-carrying case — now run a REAL, un-encoded Rust program (no Ball
//! involved at all, via [`panic_message_from_real_rust`]) to capture what
//! `panic!()`/`unreachable!()` print on THIS toolchain today, and diff that
//! against the Ball round trip's own compiled-and-run output — so a wording
//! change on either side is what makes the comparison fail, not a hard-coded
//! assumption on only one of them.
//!
//! `compile_assert_without_a_message_round_trips_through_its_own_panic` and
//! `compile_assert_with_a_message_round_trips_through_its_own_panic` give
//! `base_call.rs::compile_assert` the dedicated round-trip case
//! `methods.rs`'s own module doc names it as owed: every other case in this
//! file reaches `encode_macro`'s `"panic"` arm only incidentally, through
//! the DISPATCHER's or a hand-written function's `panic!`, never through
//! `std.assert` — the only base function `compile_assert` exists to compile.
//! Its two emission shapes are both NEW relative to every other case here:
//! a bare `panic!("Assertion failed");` with no `{}` placeholder and no
//! interpolation at all, and `panic!("{}", <expr>);` whose format string
//! IS the placeholder, with no literal text before it.
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
//! pair was fixed on the COMPILER side instead (issue #712) — an encoder arm
//! for either would encode a compiler-internal spelling while still refusing
//! every real-world occurrence — and is gated here too, by
//! `spliced_collection_literal_compiler_output_re_encodes` and its run-proof
//! `a_spliced_collection_literal_still_splices_after_the_lowering_change`.
//! Re-run that sweep when you add a compiler emission shape — everything past
//! the first construct was invisible to the issue that named it.
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

use ball_lang_compiler::Compiler;
use ball_lang_shared::proto::ball::v1::expression::Expr;
use ball_lang_shared::proto::ball::v1::literal::Value as LiteralValue;
use ball_lang_shared::proto::ball::v1::statement::Stmt;
use ball_lang_shared::proto::ball::v1::{
    Expression, FieldValuePair, FunctionCall, FunctionDefinition, ListLiteral, Literal,
    MessageCreation, Module, ModuleImport, Program, Reference,
};

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

/// Calls the compiled, argument-less `boom` and prints the value a Ball
/// `catch` would bind — the Ball-side half of the comparison
/// `a_bare_panic_encodes_the_message_rust_itself_prints` runs against
/// [`panic_message_from_real_rust`]'s LIVE reference (issues #754/#717).
/// `boom` takes zero Ball-level parameters, so it is called with
/// `BallValue::Null` — every compiled function still takes exactly one
/// `input: BallValue` (`type_emit.rs::compile_function`'s fixed signature).
const BARE_PANIC_BALL_DRIVER_MAIN: &str = r#"
fn main() {
    std::panic::set_hook(Box::new(|_| {}));
    let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        boom(BallValue::Null)
    }));
    let _ = std::panic::take_hook();
    let payload = outcome.err().expect("a bare `panic!()` must still throw after the round trip");
    println!("{}", ball_to_string(ball_catch_payload(payload)));
}
"#;

/// Calls the compiled, argument-less `stop` and prints the value a Ball
/// `catch` would bind — the Ball-side half of
/// `an_unreachable_throws_rusts_own_internal_error_message`'s LIVE reference
/// comparison (issue #717).
const BARE_UNREACHABLE_BALL_DRIVER_MAIN: &str = r#"
fn main() {
    std::panic::set_hook(Box::new(|_| {}));
    let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        stop(BallValue::Null)
    }));
    let _ = std::panic::take_hook();
    let payload = outcome.err().expect("a bare `unreachable!()` must still throw after the round trip");
    println!("{}", ball_to_string(ball_catch_payload(payload)));
}
"#;

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

/// What REAL, un-encoded Rust — no Ball involved at all — prints for
/// `trigger` (a bare statement such as `panic!();` or
/// `unreachable!("bad state {}", 9);`), captured by actually compiling and
/// running it through [`compile_and_run`]. Issues #754/#717: every other
/// constant in this file that names Rust's own fixed panic wording
/// (`"explicit panic"`, the `unreachable!` prefix) is a string this crate
/// COPIED from `library/core/src/panic.rs`'s doc comments; this instead asks
/// the toolchain that will actually run CI what it prints TODAY, so a wording
/// change on either side of a comparison — this function's side or the Ball
/// round trip's — is what makes a test fail, never an assumption baked into
/// only one of them.
///
/// The returned string is the fixture's full stdout, including the trailing
/// newline `println!` adds — compare it directly against another
/// [`compile_and_run`] call's return value, never against a hand-written
/// literal.
fn panic_message_from_real_rust(fixture_name: &str, trigger: &str) -> String {
    let main = format!(
        r#"
fn main() {{
    std::panic::set_hook(Box::new(|_| {{}}));
    let outcome = std::panic::catch_unwind(|| {{
        {trigger}
    }});
    let _ = std::panic::take_hook();
    let payload = outcome.err().expect("the trigger must panic");
    let message = payload
        .downcast_ref::<&str>()
        .map(|s| s.to_string())
        .or_else(|| payload.downcast_ref::<String>().cloned())
        .expect("a `panic!`/`unreachable!` payload here must be a string");
    println!("{{message}}");
}}
"#
    );
    compile_and_run(fixture_name, &main)
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

/// Restores the composite property #685/#632 established and #718's fix
/// narrowed away (issue **#761**): "the compiler's REAL emitted dispatcher,
/// taken as emitted, re-encodes" — not two separate, weaker facts combined
/// (the compiled text merely CONTAINS the right substring; a hand-written
/// STAND-IN function, with a different parameter name and type AND a
/// different syntactic POSITION — a function-body statement, not a match-arm
/// expression, with `other` bound as a PARAMETER rather than a match-arm
/// BINDING — happens to encode correctly). An earlier version of this very
/// test made exactly that mistake: it wrapped the extracted `panic!` in
/// `fn fallback(other: String) -> String { panic!(..); }`, which exercises
/// `block.rs`'s statement-position macro handling and a parameter binding,
/// never the match-arm expression position and pattern binding the real
/// dispatcher actually uses (caught in review of this PR, since the two
/// shapes are not equivalent to this encoder — see
/// `control_flow.rs::encode_switch_arm`'s separate `syn::Pat::Ident`
/// catch-all-binding arm vs. `block.rs`'s plain statement handling).
/// `compiled_method_dispatcher_fallback_arm_is_the_mapped_panic_macro` keeps
/// its own two weaker facts — this test adds the composite one, never
/// replacing them.
///
/// The WHOLE dispatcher function, taken completely unmodified, still cannot
/// be the thing re-encoded: its scrutinee, `match
/// ball_message_type_name(&__self).as_str() { .. }`, has no universal-`std`
/// inverse — #718's OWN, separately tracked, still-open gap
/// (`documented_gaps.rs::compiled_method_dispatcher_scrutinee_is_a_documented_gap`).
/// Folding that gap into this assertion would make this test fail for #718's
/// reason while claiming to gate #632's/#761's — exactly the conflation #718
/// exists to keep apart. So this test first RE-CONFIRMS, **by the panic's own
/// message**, that the whole dispatcher is still blocked specifically there
/// (if #718 ever closes, or if some unrelated refusal starts firing first,
/// this assertion fails loud, naming what to re-measure, rather than silently
/// passing on a property it no longer checks) — and only then substitutes
/// **that one construct alone**, leaving every other byte of the compiler's
/// own output untouched: the `match` keyword, the owner arm
/// (`"main:Point" => Point::sum(input)`) and the real fallback arm — `other
/// => panic!("no method 'sum' for {}", other),` — in their real match-arm
/// POSITIONS, with `other` bound exactly as the dispatcher binds it: a
/// match-arm catch-all pattern, never a hand-written function parameter
/// standing in for it. The substituted value need not be a real type tag —
/// this test never RUNS the result (stage 3 is an ENCODE gate; see this
/// file's module doc comment), and the encoder never evaluates a `match`
/// subject's value, only its shape. The owner arm resolves too: every
/// compiled method is one-input (invariant #1), so `impl Point { pub fn
/// sum(input: BallValue) -> BallValue { .. } }` — right beside the
/// dispatcher, untouched — has no `self` receiver and is therefore
/// syntactically indistinguishable from a receiver-less associated function;
/// `types.rs::collect_impl_method_params` registers it exactly the way #491
/// slice 3 registers `Point::new(..)`, so `Point::sum(input)` resolves
/// through the ordinary local-associated-call path rather than tripping the
/// "UFCS call to an instance method" documented gap.
#[test]
fn compiled_method_dispatcher_real_fallback_arm_re_encodes() {
    let program = ball_lang_encoder::encode_library(CLASS_WITH_METHOD_SOURCE);
    let compiled = Compiler::new(&program).compile_library();

    let real_arm = "other => panic!(\"no method 'sum' for {}\", other),";
    assert!(
        compiled.contains(real_arm),
        "the compiler must still emit the fallback arm exactly as `{real_arm}` — if this \
         spelling changed, update the substitution below:\n{compiled}"
    );

    // The WHOLE dispatcher, completely unmodified, is still blocked by #718
    // — re-confirmed here, by the panic's own MESSAGE (not merely "it
    // panicked"), so this test cannot silently start asserting nothing once
    // #718 closes or some unrelated refusal starts firing first.
    let whole_dispatcher_result =
        std::panic::catch_unwind(|| ball_lang_encoder::encode_library(&compiled));
    let whole_dispatcher_err = whole_dispatcher_result.err().unwrap_or_else(|| {
        panic!(
            "the WHOLE compiled dispatcher now re-encodes cleanly — #718 has been closed. \
             Update this test (and documented_gaps.rs's \
             compiled_method_dispatcher_scrutinee_is_a_documented_gap) to assert the composite \
             success directly over the UNMODIFIED `compiled` text, instead of substituting the \
             scrutinee below."
        )
    });
    let whole_dispatcher_message = whole_dispatcher_err
        .downcast_ref::<String>()
        .cloned()
        .or_else(|| whole_dispatcher_err.downcast_ref::<&str>().map(|s| s.to_string()))
        .unwrap_or_default();
    assert!(
        whole_dispatcher_message.contains("ball_message_type_name"),
        "the whole dispatcher must fail on #718's own scrutinee specifically, never on some \
         unrelated refusal that would make this re-confirmation meaningless: \
         {whole_dispatcher_message}"
    );

    // Substitute ONLY that one construct — the single thing this test is not
    // about — and leave every other byte of the compiler's own output
    // untouched, including both match arms verbatim.
    let scrutinee = "ball_message_type_name(&__self).as_str()";
    assert_eq!(
        compiled.matches(scrutinee).count(),
        1,
        "expected exactly one compiled dispatcher scrutinee to substitute — if this source now \
         emits more than one (e.g. a second dispatcher), this test's single substitution is no \
         longer sound:\n{compiled}"
    );
    let scrutinee_fixed =
        compiled.replacen(scrutinee, "\"__ball_dispatcher_tag_placeholder\"", 1);

    let reencoded = ball_lang_encoder::encode_library(&scrutinee_fixed);
    let calls = std_calls(&reencoded);
    assert!(
        calls.iter().any(|name| name == "throw"),
        "the REAL fallback arm, read back from its real match-arm position with its real \
         catch-all binding, must survive re-encoding as a `std.throw`. std calls found: \
         {calls:?}"
    );
    let rendered = format!("{reencoded:?}");
    assert!(
        rendered.contains("no method 'sum' for "),
        "…carrying the dispatcher's own message byte-for-byte — never a hand-retyped stand-in: \
         {rendered}"
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

/// `panic!()` with no arguments, proven end to end against REAL rustc
/// (issues #754/#717). This used to assert only that the ENCODED Ball tree
/// contained the literal `"explicit panic"` — a string this crate itself
/// believes real Rust prints, copied by hand from
/// `library/core/src/panic.rs`'s doc comments, never observed. That is
/// self-referential: a future Rust edition that reworded the bare-`panic!()`
/// message would leave this assertion green while `Ball catch` quietly
/// started binding a message real `panic!()` no longer produces. Now both
/// sides are run: [`panic_message_from_real_rust`] compiles and runs a plain
/// Rust program (no Ball at all) that calls the real, unmodified `panic!()`
/// and captures what THIS toolchain prints for it today, and the Ball side is
/// compiled and run the same way — so a wording change on either side is
/// what fails the comparison, never an assumption baked into only one of
/// them.
#[test]
fn a_bare_panic_encodes_the_message_rust_itself_prints() {
    let reference_stdout = panic_message_from_real_rust("bare_panic_reference", "panic!();");

    let program = ball_lang_encoder::encode_library("fn boom() { panic!(); }");
    let calls = std_calls(&program);
    assert!(
        calls.iter().any(|name| name == "throw"),
        "a bare `panic!()` must encode as `std.throw`. std calls found: {calls:?}"
    );

    let compiled = Compiler::new(&program).compile_library();
    let stdout = compile_and_run(
        "bare_panic_ball",
        &format!("{compiled}\n{BARE_PANIC_BALL_DRIVER_MAIN}"),
    );
    assert_eq!(
        stdout, reference_stdout,
        "a bare `panic!()` must carry exactly what REAL, un-encoded Rust prints for it today — \
         never a hard-coded assumption about the wording"
    );
}

/// `unreachable!` — the compiler's OTHER emitted macro — proven end to end
/// against REAL rustc (issue #717). This used to assert only that the
/// Ball-compiled-and-run program's stdout equalled a literal
/// (`UNREACHABLE_EXPECTED_STDOUT`) copy-derived from this crate's OWN
/// `methods.rs::UNREACHABLE_MESSAGE` constant — checking "does the compiled
/// program print what the encoder THINKS `unreachable!()` prints", not "does
/// it print what `rustc`'s real `unreachable!()` prints". Now the reference
/// side is a plain, un-encoded Rust program that calls the real
/// `unreachable!("bad state {}", 9)` directly (no Ball involved), so a wording
/// change in a future Rust edition fails this comparison on BOTH an encoder
/// drift and a real toolchain drift, not only the former.
#[test]
fn an_unreachable_throws_rusts_own_internal_error_message() {
    let reference_stdout = panic_message_from_real_rust(
        "unreachable_reference",
        r#"unreachable!("bad state {}", 9);"#,
    );

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
        stdout, reference_stdout,
        "the caught value must read exactly what REAL, un-encoded Rust's own `unreachable!` \
         prints TODAY, prefix included — never a literal copied from this crate's own belief \
         about it"
    );
}

/// `unreachable!()` with no arguments, proven end to end against REAL rustc
/// (issues #754/#717) — the bare-macro sibling of
/// `a_bare_panic_encodes_the_message_rust_itself_prints`. Also pins the `": "`
/// separator's absence: with no arguments there is nothing to append, so a
/// naive prefix-plus-format encoding that always appended `": "` would show
/// up as an extra two characters real `unreachable!()` never prints.
#[test]
fn a_bare_unreachable_encodes_the_message_rust_itself_prints() {
    let reference_stdout =
        panic_message_from_real_rust("bare_unreachable_reference", "unreachable!();");
    assert!(
        !reference_stdout.contains("entered unreachable code: "),
        "this reference program's own trailing separator check is meaningless if real Rust's \
         bare `unreachable!()` ever starts carrying one: {reference_stdout:?}"
    );

    let program = ball_lang_encoder::encode_library("fn stop() { unreachable!(); }");
    let calls = std_calls(&program);
    assert!(
        calls.iter().any(|name| name == "throw"),
        "a bare `unreachable!()` must encode as `std.throw`. std calls found: {calls:?}"
    );

    let compiled = Compiler::new(&program).compile_library();
    let stdout = compile_and_run(
        "bare_unreachable_ball",
        &format!("{compiled}\n{BARE_UNREACHABLE_BALL_DRIVER_MAIN}"),
    );
    assert_eq!(
        stdout, reference_stdout,
        "a bare `unreachable!()` must carry exactly what REAL, un-encoded Rust prints for it \
         today — never a hard-coded assumption about the wording"
    );
}

// ════════════════════════════════════════════════════════════════════════════
// `std.assert` — a DEDICATED round trip for `compile_assert` (issues #754/#717)
// ════════════════════════════════════════════════════════════════════════════
//
// Every `panic!` case above reaches `encoder/src/methods.rs::encode_macro`'s
// `"panic"` arm only incidentally — through the dispatcher's own fallback, or
// through a hand-written Rust function. `base_call.rs::compile_assert` is a
// DIFFERENT compiler emission site for the same macro, and until now nothing
// exercised it directly: it is enumerated as an emission site in
// `methods.rs`'s own module doc comment, and it is reachable only by
// compiling a Ball program that calls `std.assert` — no Rust source the
// ENCODER produces ever calls it, so a hand-written `.rs` fixture cannot
// reach it. These two tests build that Ball program directly, via the proto
// types, the same way `documented_gaps.rs`'s `null_spread_program`/
// `map_comprehension_program` reach a shape no Rust source maps to either.
//
// `compile_assert` emits `panic!` TWO ways, and both are new relative to
// every macro case above: `panic!("Assertion failed");` with no `{}`
// placeholder and no interpolation at all (every other case here has either
// one placeholder with one argument, or none with no text either), and
// `panic!("{}", <expr>);` for a supplied message — the format string IS the
// placeholder, with no literal text before it (every other formatted case
// has literal text before its first placeholder). `build_format_args`
// handles an empty leading literal segment by just not pushing it, so this
// also exercises that path for real for the first time in this file.

/// Build the one-function library `check(input)` whose body is a raw
/// `std.assert(condition, message?)` call — `compile_assert`'s own direct
/// test subject. `condition` is read from `Reference("input")`
/// (`compile_reference` renders that as `input.clone()`), so calling the
/// compiled `check` with `BallValue::Bool(false)` always takes the panicking
/// branch.
fn assert_library(message: Option<Expression>) -> Program {
    let mut fields = vec![FieldValuePair {
        name: "condition".to_string(),
        value: Some(reference("input")),
    }];
    if let Some(message) = message {
        fields.push(FieldValuePair {
            name: "message".to_string(),
            value: Some(message),
        });
    }
    let body = Expression {
        expr: Some(Expr::Call(Box::new(FunctionCall {
            module: "std".to_string(),
            function: "assert".to_string(),
            input: Some(Box::new(Expression {
                expr: Some(Expr::MessageCreation(MessageCreation {
                    type_name: String::new(),
                    fields,
                    metadata: None,
                })),
            })),
            type_args: vec![],
        }))),
    };
    Program {
        name: "assert_fixture".to_string(),
        version: "1.0.0".to_string(),
        modules: vec![
            ball_lang_shared::build_std_module(),
            Module {
                name: "main".to_string(),
                functions: vec![FunctionDefinition {
                    name: "check".to_string(),
                    input_type: String::new(),
                    output_type: String::new(),
                    body: Some(Box::new(body)),
                    description: String::new(),
                    is_base: false,
                    metadata: None,
                }],
                module_imports: vec![ModuleImport {
                    name: "std".to_string(),
                    ..Default::default()
                }],
                ..Default::default()
            },
        ],
        entry_module: "main".to_string(),
        entry_function: String::new(),
        metadata: None,
    }
}

/// Calls the compiled `check` with a failing condition and prints the value
/// a Ball `catch` would bind.
const ASSERT_BALL_DRIVER_MAIN: &str = r#"
fn main() {
    std::panic::set_hook(Box::new(|_| {}));
    let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        check(BallValue::Bool(false))
    }));
    let _ = std::panic::take_hook();
    let payload = outcome.err().expect("a failing `std.assert` must still panic");
    println!("{}", ball_to_string(ball_catch_payload(payload)));
}
"#;

/// `std.assert(condition)` with NO message: `compile_assert`'s `None` arm,
/// `panic!("Assertion failed");` — the one macro case in this whole file with
/// no `{}` placeholder and no interpolation at all.
#[test]
fn compile_assert_without_a_message_round_trips_through_its_own_panic() {
    let program = assert_library(None);
    let compiled = Compiler::new(&program).compile_library();
    assert!(
        compiled.contains("panic!(\"Assertion failed\");"),
        "compile_assert's no-message arm must still emit the bare literal `panic!` with no \
         interpolation — the shape this test exists to cover:\n{compiled}"
    );

    let reencoded = ball_lang_encoder::encode_library(&compiled);
    let calls = std_calls(&reencoded);
    assert!(
        calls.iter().any(|name| name == "throw"),
        "compile_assert's own `panic!(\"Assertion failed\")` must survive re-encoding as a \
         `std.throw`. std calls found: {calls:?}"
    );
    let rendered = format!("{reencoded:?}");
    assert!(
        rendered.contains("Assertion failed"),
        "…carrying the exact message: {rendered}"
    );

    let stdout = compile_and_run(
        "assert_no_message",
        &format!("{compiled}\n{ASSERT_BALL_DRIVER_MAIN}"),
    );
    assert_eq!(
        stdout, "Assertion failed\n",
        "a failing `std.assert` with no message must still print Dart's/every other target's \
         fixed `Assertion failed` text"
    );
}

/// `std.assert(condition, message)`: `compile_assert`'s `Some` arm,
/// `panic!("{}", <expr>);` — the format string IS the one `{}` placeholder,
/// with no literal text before it.
#[test]
fn compile_assert_with_a_message_round_trips_through_its_own_panic() {
    let program = assert_library(Some(string_literal("boom")));
    let compiled = Compiler::new(&program).compile_library();
    assert!(
        compiled.contains("panic!(\"{}\", BallValue::String(\"boom\".to_string()));"),
        "compile_assert's message arm must still emit a bare `panic!(\"{{}}\", <expr>)` with no \
         literal prefix before the placeholder:\n{compiled}"
    );

    let reencoded = ball_lang_encoder::encode_library(&compiled);
    let calls = std_calls(&reencoded);
    assert!(
        calls.iter().any(|name| name == "throw"),
        "compile_assert's own message-carrying `panic!` must survive re-encoding as a \
         `std.throw`. std calls found: {calls:?}"
    );
    let rendered = format!("{reencoded:?}");
    assert!(
        rendered.contains("boom"),
        "…carrying the exact supplied message: {rendered}"
    );

    let stdout = compile_and_run(
        "assert_with_message",
        &format!("{compiled}\n{ASSERT_BALL_DRIVER_MAIN}"),
    );
    assert_eq!(
        stdout, "boom\n",
        "a failing `std.assert` must print exactly its own supplied message"
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

// ════════════════════════════════════════════════════════════════════════════
// The SPLICED COLLECTION LITERAL (issue #712)
// ════════════════════════════════════════════════════════════════════════════
//
// `base_call.rs::compile_list_literal` abandons the direct `vec![…]` and builds
// the literal imperatively the moment ANY element splices, so one lowering
// carries every spread, collection-`if` and collection-`for` there is. The
// program below exercises all four element kinds in one literal, which is the
// point: the dispatcher case above was found as a single `panic!` and turned
// out to be four constructs, so a one-element pin here would repeat that
// mistake.
//
// The input is a Ball `Program`, not Rust source, and has to be: Rust has no
// `...`/`...?` syntax and no collection comprehension, so these elements can
// only enter the pipeline from the Ball side (`dart/encoder` emits them for
// `[...l]`, `[...?l]`, `[if (c) x]` and `[for (v in it) x]`).

/// The same program in LIBRARY shape — an empty `entry_function`, which is what
/// `encode_library` produces and what Tier A's stage 2 compiles.
///
/// It has to be a separate builder rather than the same `Program`:
/// `compile_module_body` SKIPS the function named by `entry_function`, because
/// in program mode `compile_entry_main` inlines it into `fn main()` instead. A
/// library-mode compile of a program that still names one therefore emits
/// nothing at all — measured, and the reason the RED commit's first failure was
/// an empty module rather than the refusal it was gating.
fn spliced_literal_library() -> Program {
    let mut program = spliced_literal_program();
    program.entry_function = String::new();
    program
}

/// `[1, ...[2, 3], if (true) 4, for (v in [5, 6]) v, ...?null]` printed through
/// `std.to_string` — all four spliceable element kinds in one literal, plus a
/// plain leading element so the non-splice `push` path is covered too.
fn spliced_literal_program() -> Program {
    let spread = std_element("spread", vec![("value", small_list(2, 3))]);
    let collection_if = std_element(
        "collection_if",
        vec![("condition", bool_literal(true)), ("then", int_literal(4))],
    );
    let collection_for = std_element(
        "collection_for",
        vec![
            ("variable", string_literal("v")),
            ("iterable", small_list(5, 6)),
            ("body", reference("v")),
        ],
    );
    let null_spread = std_element("null_spread", vec![("value", null_literal())]);
    let literal = list_literal(vec![
        int_literal(1),
        spread,
        collection_if,
        collection_for,
        null_spread,
    ]);
    // `std.print`'s input field is `message`, not `value` — `compile_print`
    // reads that name and a mismatch silently prints `null`.
    let printed = std_element("to_string", vec![("value", literal)]);
    let body = std_element("print", vec![("message", printed)]);

    Program {
        name: "spliced_literal".to_string(),
        version: "1.0.0".to_string(),
        modules: vec![
            ball_lang_shared::build_std_module(),
            Module {
                name: "main".to_string(),
                functions: vec![FunctionDefinition {
                    name: "splice".to_string(),
                    input_type: String::new(),
                    output_type: String::new(),
                    body: Some(Box::new(body)),
                    description: String::new(),
                    is_base: false,
                    metadata: None,
                }],
                module_imports: vec![ModuleImport {
                    name: "std".to_string(),
                    ..Default::default()
                }],
                ..Default::default()
            },
        ],
        entry_module: "main".to_string(),
        entry_function: "splice".to_string(),
        metadata: None,
    }
}

/// What `[1, ...[2, 3], if (true) 4, for (v in [5, 6]) v, ...?null]` must print
/// — the splice semantics themselves: each spliced element contributes its
/// CONTENTS, never itself as one nested element (issues #39/#300), and a
/// null-aware spread of null contributes nothing.
const SPLICED_LITERAL_EXPECTED_STDOUT: &str = "[1, 2, 3, 4, 5, 6]\n";

fn std_element(function: &str, fields: Vec<(&str, Expression)>) -> Expression {
    Expression {
        expr: Some(Expr::Call(Box::new(FunctionCall {
            module: "std".to_string(),
            function: function.to_string(),
            input: Some(Box::new(Expression {
                expr: Some(Expr::MessageCreation(MessageCreation {
                    type_name: String::new(),
                    fields: fields
                        .into_iter()
                        .map(|(name, value)| FieldValuePair {
                            name: name.to_string(),
                            value: Some(value),
                        })
                        .collect(),
                    metadata: None,
                })),
            })),
            type_args: vec![],
        }))),
    }
}

fn small_list(first: i64, second: i64) -> Expression {
    list_literal(vec![int_literal(first), int_literal(second)])
}

fn list_literal(elements: Vec<Expression>) -> Expression {
    Expression {
        expr: Some(Expr::Literal(Literal {
            value: Some(LiteralValue::ListValue(ListLiteral { elements })),
        })),
    }
}

fn int_literal(value: i64) -> Expression {
    Expression {
        expr: Some(Expr::Literal(Literal {
            value: Some(LiteralValue::IntValue(value)),
        })),
    }
}

fn bool_literal(value: bool) -> Expression {
    Expression {
        expr: Some(Expr::Literal(Literal {
            value: Some(LiteralValue::BoolValue(value)),
        })),
    }
}

fn string_literal(value: &str) -> Expression {
    Expression {
        expr: Some(Expr::Literal(Literal {
            value: Some(LiteralValue::StringValue(value.to_string())),
        })),
    }
}

/// Ball's `null` is a `Literal` with no `value` set — not a variant carrying a
/// null payload.
fn null_literal() -> Expression {
    Expression {
        expr: Some(Expr::Literal(Literal { value: None })),
    }
}

fn reference(name: &str) -> Expression {
    Expression {
        expr: Some(Expr::Reference(Reference {
            name: name.to_string(),
        })),
    }
}

/// #712's stage-3 gate: LIBRARY-mode compiler output containing a spliced
/// collection literal must re-encode.
///
/// Before #712 it could not. The imperative lowering opened with
/// `let mut __lit: Vec<BallValue> = Vec::new();` — an associated function on a
/// foreign type, which `lib.rs` refuses by design — and spelled the
/// null-spread guard as `matches!(__sp, BallValue::Null)`, a pattern match
/// `methods.rs` refuses by design. So EVERY library whose compiled output held
/// a spread, a collection-`if` or a collection-`for` stopped at
/// `reencode-error`, which is a far broader population than the method
/// dispatcher the same invariant was first found on.
///
/// The two `!contains` assertions are the staleness guard: if the lowering ever
/// reintroduces either construct this test must fail on the SHAPE, naming it,
/// rather than on whatever panic the encoder happens to raise second.
#[test]
fn spliced_collection_literal_compiler_output_re_encodes() {
    let program = spliced_literal_library();
    let compiled = Compiler::new(&program).compile_library();
    assert!(
        compiled.contains("push"),
        "this test is only exercising the construct it names while the spliced-literal lowering \
         is still the imperative one — a direct `vec![…]` here would mean the program stopped \
         splicing:\n{compiled}"
    );
    assert!(
        !compiled.contains("Vec::new()"),
        "the spliced-literal accumulator must not be a bare `Vec` (#712):\n{compiled}"
    );
    assert!(
        !compiled.contains("matches!"),
        "the null-spread guard must not be a `matches!` pattern (#712):\n{compiled}"
    );

    let reencoded = ball_lang_encoder::encode_library(&compiled);
    let calls = std_calls(&reencoded);
    for expected in ["for_in", "spread", "not_equals", "if"] {
        assert!(
            calls.iter().any(|name| name == expected),
            "the re-encoded lowering must still carry `std.{expected}` — a re-encode that \
             dropped a loop or a guard would pass a panic-free assertion just as cleanly. std \
             calls found: {calls:?}"
        );
    }
}

/// The behavioural half, run rather than asserted about: a lowering change is
/// only safe if the literal still SPLICES. An element that nested instead of
/// splicing (`[1, [2, 3], …]`) re-encodes exactly as cleanly and prints a
/// different answer — the #39/#300 bug this lowering exists to fix.
#[test]
fn a_spliced_collection_literal_still_splices_after_the_lowering_change() {
    let program = spliced_literal_program();
    let compiled = Compiler::new(&program).compile();
    assert_eq!(
        compile_and_run("spliced_literal", &compiled),
        SPLICED_LITERAL_EXPECTED_STDOUT,
        "each spliced element must contribute its CONTENTS, and `...?null` nothing at all"
    );
}
