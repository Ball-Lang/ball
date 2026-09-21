//! `while let PAT = EXPR { .. }` — issue #778.
//!
//! ## What was broken
//!
//! `rust/encoder/src/control_flow.rs::encode_while` handed its condition
//! straight to `encode_expr` with no `syn::Expr::Let` special case, unlike its
//! sibling `encode_if`. A `while let Some(x) = <iter-expr> { .. }` — the
//! canonical Rust idiom for draining an iterator, a channel or a work queue —
//! therefore fell through every `encode_expr` arm to `lib.rs`'s catch-all,
//! which named the construct **"let-guard outside if/while"** while firing
//! *inside* a `while`. Two defects in one: the feature was missing, and the
//! refusal misdescribed why.
//!
//! ## Why the tests did not catch it
//!
//! Nothing in `rust/encoder/tests/` encoded a `while let` at all —
//! `end_to_end.rs`'s representative source covers `if let` (`if let Some(v) =
//! maybe`) and a plain `while n > 0`, but never the two composed. The panic
//! text likewise had no pin, so its wording was free to drift from the
//! constructs that actually reach it. This file supplies both.
//!
//! ## What the encoding is
//!
//! Rust's own reference desugaring — `while let PAT = EXPR { BODY }` is
//! `loop { match EXPR { PAT => BODY, _ => break } }` — expressed in the
//! primitives Ball already has, because `std.while`'s `condition` is a plain
//! boolean with no pattern-binding slot:
//!
//! ```text
//! std.while(
//!   condition: true,
//!   body: block {
//!     let __ball_while_let = <EXPR>;                      // re-evaluated per iteration
//!     std.if(
//!       condition: std.not(__ball_while_let.is_err),      // matched?
//!       then:  block { let <bind> = __ball_while_let.value; <BODY> },
//!       else:  std.break(),
//!     )
//!   }
//! )
//! ```
//!
//! `is_err`/`value` is `lib.rs::option_result_message`'s unified
//! Option/Result "outcome" shape — the same discriminant check
//! `encode_if_let` and `encode_outcome_match` already use, so `Some`/`Ok`
//! (match on success) and `None`/`Err` (match on failure) both fall out of
//! `outcome_condition` unchanged.
//!
//! ## Why these are compile-and-run proofs, not shape assertions alone
//!
//! The desugaring's whole risk is *dynamic*: that the subject is evaluated
//! once per iteration rather than once, that the synthetic `break` exits the
//! loop rather than the enclosing function, and that the binding is live for
//! the body and dead after it. A tree-shape assertion cannot see any of those.
//! One structural test pins the shape (so a regression names the tree that
//! changed); the rest encode → compile → run and compare stdout against values
//! hand-computed from the semantics of the original Rust, never read off a run
//! — the same standard `end_to_end.rs` and `tuple_and_unit_structs.rs` hold.
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

use ball_lang_compiler::Compiler;
use ball_lang_shared::proto::ball::v1::expression::Expr;
use ball_lang_shared::proto::ball::v1::literal::Value as LiteralValue;
use ball_lang_shared::proto::ball::v1::statement::Stmt;
use ball_lang_shared::proto::ball::v1::{Expression, FunctionCall, Literal, Statement};

static FIXTURE_COUNTER: AtomicU64 = AtomicU64::new(0);

fn workspace_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("rust/encoder must have a parent directory")
        .to_path_buf()
}

/// Build and run `rust_src` in a scratch cargo package — the same harness
/// `end_to_end.rs`/`tuple_and_unit_structs.rs`/`static_methods.rs` use (unique
/// package/bin name so parallel fixtures never collide; the shared workspace
/// `target/` so the already-built `ball-lang-shared` dependency tree is
/// reused; every artifact cleaned up, including on failure).
fn compile_and_run(fixture_name: &str, rust_src: &str) -> String {
    let workspace_root = workspace_root();
    let target_dir = workspace_root.join("target");
    let unique = FIXTURE_COUNTER.fetch_add(1, Ordering::Relaxed);
    let slug = format!("{fixture_name}_{}_{unique}", std::process::id());
    let fixture_dir = std::env::temp_dir().join(format!("ball_encoder_while_let_fixture_{slug}"));
    fs::create_dir_all(&fixture_dir).unwrap_or_else(|err| {
        panic!(
            "failed to create fixture dir {}: {err}",
            fixture_dir.display()
        )
    });

    let shared_path = workspace_root.join("shared");
    let bin_name = format!("ball_encoder_while_let_fixture_{slug}");
    let manifest = format!(
        "[package]\nname = \"{bin_name}\"\nversion = \"0.0.0\"\nedition = \"2024\"\npublish = false\n\n\
         [[bin]]\nname = \"{bin_name}\"\npath = \"main.rs\"\n\n\
         [dependencies]\nball-lang-shared = {{ path = {:?} }}\n",
        shared_path
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

/// Encode `source`, compile it, run it, and assert its stdout.
fn assert_encodes_compiles_and_prints(fixture_name: &str, source: &str, expected: &str) {
    let program = ball_lang_encoder::encode(source);
    let compiled = Compiler::new(&program).compile();
    let stdout = compile_and_run(fixture_name, &compiled);
    assert_eq!(
        stdout.trim_end().replace("\r\n", "\n"),
        expected,
        "fixture '{fixture_name}'\n--- original rust ---\n{source}\n\
         --- generated main.rs ---\n{compiled}"
    );
}

// ════════════════════════════════════════════════════════════
// Executable proofs
// ════════════════════════════════════════════════════════════

/// The headline case: a `while let Some(v) = <call>` drain loop, whose
/// subject must be re-evaluated on every iteration (a once-evaluated subject
/// loops forever; a never-evaluated one exits immediately) and whose `None`
/// must terminate the loop rather than the enclosing function.
///
/// `next_step(0..4)` yields `Some(n + 1)`, `next_step(5)` yields `None`, so
/// the bound values are 1, 2, 3, 4, 5 and `total` is 1+2+3+4+5 == 15 over
/// exactly 5 iterations.
#[test]
fn while_let_some_drains_and_terminates() {
    let source = r#"
fn next_step(n: i64) -> Option<i64> {
    if n < 5 {
        Some(n + 1)
    } else {
        None
    }
}

fn main() {
    let mut cur = 0;
    let mut total = 0;
    let mut iterations = 0;
    while let Some(v) = next_step(cur) {
        total += v;
        cur = v;
        iterations += 1;
    }
    println!("{}", total);
    println!("{}", iterations);
    println!("{}", cur);
}
"#;
    assert_encodes_compiles_and_prints("while_let_some", source, "15\n5\n5");
}

/// `while let Ok(v) = ...` — the failure-arm mirror. `outcome_condition`
/// discriminates on the same `is_err` field, so `Err` terminates the loop
/// exactly as `None` does, and the bound `v` is the success payload.
///
/// `step(1) -> Ok(2)`, `step(2) -> Ok(3)`, `step(3) -> Err(..)`: two
/// iterations, and `cur` lands on 3.
#[test]
fn while_let_ok_terminates_on_err() {
    let source = r#"
fn step(n: i64) -> Result<i64, String> {
    if n < 3 {
        Ok(n + 1)
    } else {
        Err(String::from("done"))
    }
}

fn main() {
    let mut cur = 1;
    let mut rounds = 0;
    while let Ok(v) = step(cur) {
        rounds += 1;
        cur = v;
    }
    println!("{}", rounds);
    println!("{}", cur);
}
"#;
    assert_encodes_compiles_and_prints(
        "while_let_ok",
        source,
        "2
3",
    );
}

/// The `while let` binding is live for the BODY only. An enclosing local of
/// the same name must be neither read nor written by the loop — the exact
/// failure `Encoder::with_pattern_binding` exists to prevent (issue #630),
/// and the one that would be silent here: without the pattern frame, `v`
/// inside the body resolves to the OUTER `v`, so the loop would overwrite it
/// and the final `println!` would print 5 instead of 99.
#[test]
fn while_let_binding_does_not_clobber_an_enclosing_local() {
    let source = r#"
fn next_step(n: i64) -> Option<i64> {
    if n < 5 {
        Some(n + 1)
    } else {
        None
    }
}

fn main() {
    let v = 99;
    let mut cur = 0;
    let mut last = 0;
    while let Some(v) = next_step(cur) {
        last = v;
        cur = v;
    }
    println!("{}", v);
    println!("{}", last);
}
"#;
    assert_encodes_compiles_and_prints("while_let_scope", source, "99\n5");
}

/// A LABELED `while let`, broken out of from an inner loop by its label.
/// The label must wrap the `std.while` the desugaring produces (so
/// `wrap_label`'s directly-nested-loop fast path still applies), and the
/// desugaring's own synthetic `break` must remain UNLABELED so it exits the
/// `while let` itself and never the labelled outer loop by accident.
///
/// `'outer` is broken on the first inner `j` whose `v + j == 4`: with
/// `v == 1` on the first iteration that is `j == 3`, so `hits` counts
/// j == 0, 1, 2 -> 3.
#[test]
fn labeled_while_let_breaks_by_label_from_an_inner_loop() {
    let source = r#"
fn next_step(n: i64) -> Option<i64> {
    if n < 5 {
        Some(n + 1)
    } else {
        None
    }
}

fn main() {
    let mut cur = 0;
    let mut hits = 0;
    'outer: while let Some(v) = next_step(cur) {
        for j in 0..5 {
            if v + j == 4 {
                break 'outer;
            }
            hits += 1;
        }
        cur = v;
    }
    println!("{}", hits);
}
"#;
    assert_encodes_compiles_and_prints("while_let_labeled", source, "3");
}

/// A `while let` NESTED inside another `while let`. Both desugarings
/// introduce a temporary under the same fixed name, so the inner one must
/// shadow within its own block and leave the outer one's per-iteration value
/// intact — otherwise the outer loop reads the inner subject and either spins
/// forever or exits early.
///
/// Outer yields v = 1, 2, 3 (3 iterations, `outer_count` == 3); for each,
/// the inner drains `0 -> 1 -> 2` (2 iterations each), so `inner_count` == 6.
#[test]
fn nested_while_let_temporaries_do_not_collide() {
    let source = r#"
fn up_to(limit: i64, n: i64) -> Option<i64> {
    if n < limit {
        Some(n + 1)
    } else {
        None
    }
}

fn main() {
    let mut outer_cur = 0;
    let mut outer_count = 0;
    let mut inner_count = 0;
    while let Some(v) = up_to(3, outer_cur) {
        outer_count += 1;
        let mut inner_cur = 0;
        while let Some(w) = up_to(2, inner_cur) {
            inner_count += 1;
            inner_cur = w;
        }
        outer_cur = v;
    }
    println!("{}", outer_count);
    println!("{}", inner_count);
}
"#;
    assert_encodes_compiles_and_prints("while_let_nested", source, "3\n6");
}

// ════════════════════════════════════════════════════════════
// Structural proof
// ════════════════════════════════════════════════════════════

fn as_call(expr: &Expression) -> &FunctionCall {
    match &expr.expr {
        Some(Expr::Call(call)) => call,
        other => panic!("expected a call, got {other:?}"),
    }
}

/// The `std` call named `function`, if this expression is one.
fn call_named<'a>(expr: &'a Expression, function: &str) -> Option<&'a FunctionCall> {
    match &expr.expr {
        Some(Expr::Call(call)) if call.function == function => Some(call),
        _ => None,
    }
}

/// The named field of a call's `MessageCreation` input.
fn arg<'a>(expr: &'a Expression, name: &str) -> &'a Expression {
    let call = as_call(expr);
    let input = call.input.as_ref().expect("the call must carry an input");
    let Some(Expr::MessageCreation(message)) = &input.expr else {
        panic!("a std call's input is a message_creation");
    };
    message
        .fields
        .iter()
        .find(|f| f.name == name)
        .unwrap_or_else(|| panic!("no `{name}` field on {message:?}"))
        .value
        .as_ref()
        .expect("a field always carries a value")
}

/// The `while let` desugaring's exact tree: an always-true `std.while` whose
/// body re-binds the subject and then either runs the body or `std.break`s.
/// Pinned structurally so a regression reports *which* node changed rather
/// than only that a fixture's stdout moved.
#[test]
fn while_let_encodes_as_an_always_true_std_while_with_a_break_else() {
    let program = ball_lang_encoder::encode(
        "fn next(n: i64) -> Option<i64> { if n < 2 { Some(n + 1) } else { None } }\n\
         fn main() { let mut c = 0; while let Some(v) = next(c) { c = v; } println!(\"{}\", c); }",
    );
    let main_module = program
        .modules
        .iter()
        .find(|m| m.name == "main")
        .expect("the encoded program must carry a `main` module");
    let main_fn = main_module
        .functions
        .iter()
        .find(|f| f.name == "main")
        .expect("the encoded program must carry `main`");
    let body = main_fn.body.as_ref().expect("`main` must carry a body");
    let Some(Expr::Block(block)) = &body.expr else {
        panic!("`main`'s body is a block");
    };

    let while_call = block
        .statements
        .iter()
        .filter_map(statement_expression)
        .find(|expr| call_named(expr, "while").is_some())
        .expect("`main` must contain a `std.while` statement");

    // The condition is a literal `true` — the loop's real exit is the
    // synthetic `break` below, exactly as Rust's own
    // `loop { match .. { _ => break } }` desugaring works.
    assert_eq!(
        arg(while_call, "condition").expr,
        Some(Expr::Literal(Literal {
            value: Some(LiteralValue::BoolValue(true))
        })),
        "a `while let`'s `std.while` condition must be an unconditional `true`"
    );

    // The body is `block { let <tmp> = <subject>; std.if(...) }`.
    let while_body = arg(while_call, "body");
    let Some(Expr::Block(body_block)) = &while_body.expr else {
        panic!("a `while let` body is a block, got {while_body:?}");
    };
    let Some(Stmt::Let(binding)) = &body_block
        .statements
        .first()
        .expect("the body block must open with the subject binding")
        .stmt
    else {
        panic!("the body block must open with a `let` of the loop subject");
    };
    assert!(
        binding.name.starts_with("__ball_while_let"),
        "the subject temporary must be encoder-reserved, got `{}`",
        binding.name
    );
    let subject = binding
        .value
        .as_ref()
        .expect("the subject binding must carry a value");
    assert_eq!(
        as_call(subject).function,
        "next",
        "the subject must be re-evaluated inside the loop body, not hoisted"
    );

    let guard = body_block
        .result
        .as_deref()
        .expect("the body block must end in the match check");
    assert_eq!(as_call(guard).function, "if");
    assert_eq!(
        as_call(arg(guard, "else")).function,
        "break",
        "a non-matching subject must `break` the loop"
    );
    assert!(
        as_call(arg(guard, "else")).input.is_none(),
        "the synthetic break must be UNLABELED so it exits this loop only"
    );
}

fn statement_expression(statement: &Statement) -> Option<&Expression> {
    match &statement.stmt {
        Some(Stmt::Expression(expression)) => Some(expression),
        _ => None,
    }
}
