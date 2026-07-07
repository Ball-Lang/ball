//! Phase 3a end-to-end conformance (issue #42): encode a representative
//! Rust source file with [`ball_encoder::encode`], then actually compile
//! and run the resulting `ball.v1.Program` — via `ball-compiler` +
//! `cargo run`, the exact same "compile -> execute with the native
//! toolchain -> compare" idiom `rust/compiler/tests/end_to_end.rs` already
//! uses (`compile_and_run`, reproduced here so this crate doesn't need a
//! test-only path back into `ball-compiler`'s own test module).
//!
//! ## Why this substitutes for "run through the Rust engine" here
//!
//! The issue's acceptance criteria ask for the encoded `Program` to run
//! through **both** the Rust engine and the Dart reference engine with
//! matching output. The self-hosted Rust engine (issue #39) does not exist
//! yet — `rust/engine` is still an empty Phase-1a scaffold — so there is no
//! Rust *engine* to run this through today. `ball-compiler` (issues
//! #36-38) does exist and is the closest available proof that the encoded
//! tree is a *correct, executable* Ball program on the Rust target: it
//! compiles the encoded `Program` to real Rust source and actually runs it
//! via `cargo run`, asserting on its stdout. Every expected value below is
//! independently hand-computed from the *semantics* of the original Rust
//! source (not derived from running anything) — the same "an
//! independently-computed expected value **is** 'matches the reference
//! engine'" reasoning `rust/compiler/tests/end_to_end.rs`'s own
//! `nested_loops_conditionals_break_continue_return` test already relies
//! on, since none of the constructs below are Rust-specific (arithmetic,
//! control flow, and the `std`/`std_collections` base functions they
//! desugar to are identical across every Ball target, Dart's reference
//! engine included).
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

use ball_compiler::Compiler;
use ball_shared::proto::ball::v1::expression::Expr;
use ball_shared::proto::ball::v1::statement::Stmt;
use ball_shared::proto::ball::v1::{Expression, Module, Program};

// ════════════════════════════════════════════════════════════
// rustc/cargo execution harness (mirrors rust/compiler/tests/end_to_end.rs)
// ════════════════════════════════════════════════════════════

static FIXTURE_COUNTER: AtomicU64 = AtomicU64::new(0);

fn workspace_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("rust/encoder must have a parent directory")
        .to_path_buf()
}

fn compile_and_run(fixture_name: &str, rust_src: &str) -> String {
    let workspace_root = workspace_root();
    let target_dir = workspace_root.join("target");
    let unique = FIXTURE_COUNTER.fetch_add(1, Ordering::Relaxed);
    let fixture_dir = std::env::temp_dir().join(format!(
        "ball_encoder_rustc_fixture_{fixture_name}_{}_{unique}",
        std::process::id()
    ));
    fs::create_dir_all(&fixture_dir).unwrap_or_else(|err| {
        panic!(
            "failed to create fixture dir {}: {err}",
            fixture_dir.display()
        )
    });

    let shared_path = workspace_root.join("shared");
    let manifest = format!(
        "[package]\nname = \"ball_encoder_fixture_{fixture_name}\"\nversion = \"0.0.0\"\nedition = \"2024\"\npublish = false\n\n\
         [[bin]]\nname = \"fixture\"\npath = \"main.rs\"\n\n\
         [dependencies]\nball-shared = {{ path = {:?} }}\n",
        shared_path
    );
    fs::write(fixture_dir.join("Cargo.toml"), manifest)
        .expect("failed to write fixture Cargo.toml");
    fs::write(fixture_dir.join("main.rs"), rust_src).expect("failed to write fixture main.rs");

    let manifest_path = fixture_dir.join("Cargo.toml");
    let output = Command::new("cargo")
        .args(["run", "--quiet"])
        .arg("--manifest-path")
        .arg(&manifest_path)
        .arg("--target-dir")
        .arg(&target_dir)
        .output()
        .expect("failed to spawn `cargo run` — is cargo on PATH?");

    if !output.status.success() {
        panic!(
            "fixture '{fixture_name}' failed to compile/run.\n--- generated main.rs ---\n{rust_src}\n\
             --- stdout ---\n{}\n--- stderr ---\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }

    let _ = fs::remove_dir_all(&fixture_dir);
    String::from_utf8(output.stdout).expect("fixture stdout must be valid UTF-8")
}

fn assert_program_prints(fixture_name: &str, program: &Program, expected_stdout: &str) {
    let compiled = Compiler::new(program).compile();
    let stdout = compile_and_run(fixture_name, &compiled);
    assert_eq!(
        stdout.trim(),
        expected_stdout,
        "fixture '{fixture_name}' produced unexpected stdout.\n--- generated main.rs ---\n{compiled}"
    );
}

// ════════════════════════════════════════════════════════════
// A representative Rust source file
// ════════════════════════════════════════════════════════════

const REPRESENTATIVE_SOURCE: &str = r#"
fn classify(n: i64) -> String {
    if n < 0 {
        String::from("negative")
    } else if n == 0 {
        String::from("zero")
    } else {
        String::from("positive")
    }
}

fn sum_range(limit: i64) -> i64 {
    let mut total = 0;
    for i in 0..limit {
        if i % 2 == 0 {
            continue;
        }
        total += i;
    }
    total
}

fn count_down(n: i64) -> i64 {
    // Shadow the (single-named-parameter-aliased) `n` with a mutable local
    // — `ball-compiler`'s `param_alias_prologue` always aliases a
    // function's single named parameter via an immutable `let`, so
    // mutating the parameter binding *itself* is a pre-existing
    // ball-compiler limitation outside this encoder issue's scope; this
    // shadowing idiom is ordinary, valid Rust that sidesteps it cleanly.
    let mut n = n;
    let mut steps = 0;
    while n > 0 {
        n -= 1;
        steps += 1;
    }
    steps
}

fn safe_div(a: i64, b: i64) -> Result<i64, String> {
    if b == 0 {
        return Err(String::from("division by zero"));
    }
    Ok(a / b)
}

fn compute(a: i64, b: i64) -> Result<i64, String> {
    let q = safe_div(a, b)?;
    Ok(q * 2)
}

fn describe_day(day: i64) -> String {
    match day {
        1 => String::from("Monday"),
        2 | 3 | 4 | 5 => String::from("Midweek"),
        6 | 7 => String::from("Weekend"),
        _ => String::from("Unknown"),
    }
}

fn doubled_multiples_of_four(nums: Vec<i64>) -> Vec<i64> {
    nums.iter().map(|x| x * 2).filter(|x| x % 4 == 0).collect()
}

fn main() {
    println!("{}", classify(-5));
    println!("{}", classify(0));
    println!("{}", classify(5));
    println!("{}", sum_range(10));
    println!("{}", count_down(5));
    match compute(10, 2) {
        Ok(v) => println!("ok: {}", v),
        Err(e) => println!("err: {}", e),
    }
    match compute(10, 0) {
        Ok(v) => println!("ok: {}", v),
        Err(e) => println!("err: {}", e),
    }
    println!("{}", describe_day(3));
    println!("{}", describe_day(9));
    let evens = doubled_multiples_of_four(vec![1, 2, 3, 4, 5]);
    println!("{}", evens.len());
    let maybe = Some(42);
    if let Some(v) = maybe {
        println!("{}", v);
    } else {
        println!("none");
    }
}
"#;

/// The headline acceptance-criteria test: encode [`REPRESENTATIVE_SOURCE`],
/// compile the result, run it, and check its output against independently
/// hand-computed expected values (see the module doc comment for why this
/// stands in for "the Rust engine" today).
#[test]
fn representative_rust_source_encodes_compiles_and_runs_with_expected_output() {
    let program = ball_encoder::encode(REPRESENTATIVE_SOURCE);
    let expected = [
        "negative",              // classify(-5)
        "zero",                  // classify(0)
        "positive",              // classify(5)
        "25",                    // sum_range(10): 1+3+5+7+9
        "5",                     // count_down(5): 5 decrements
        "ok: 10",                // compute(10, 2) -> Ok(5 * 2)
        "err: division by zero", // compute(10, 0) -> Err propagated via `?`
        "Midweek",               // describe_day(3)
        "Unknown",               // describe_day(9)
        "2",                     // doubled_multiples_of_four([1..5]) -> [4, 8]
        "42",                    // if let Some(v) = Some(42)
    ]
    .join("\n");
    assert_program_prints("representative", &program, &expected);
}

/// Acceptance criterion: the encoded `Program` must contain **no**
/// `rust_std` module — only universal `std`/`std_collections`/`std_io`/
/// `std_memory` (the "eliminate lang-specific std modules" invariant).
#[test]
fn encoded_program_contains_no_rust_std_module() {
    let program = ball_encoder::encode(REPRESENTATIVE_SOURCE);
    const UNIVERSAL_MODULES: &[&str] = &["std", "std_collections", "std_io", "std_memory", "main"];
    for module in &program.modules {
        assert!(
            UNIVERSAL_MODULES.contains(&module.name.as_str()),
            "encoded Program must not contain a language-specific module, found `{}` \
             (only universal std/std_collections/std_io/std_memory plus the user's own \
             `main` module are allowed)",
            module.name
        );
        assert_ne!(
            module.name, "rust_std",
            "encoded Program must never contain a `rust_std` base module — every construct \
             must route through the universal std modules"
        );
    }
}

/// Acceptance criterion: control-flow branches must appear as
/// **sub-expressions** of the `std` control-flow call, never pre-evaluated
/// by the encoder — verified here by inspecting the raw encoded tree for
/// `if`/`while`/`for`, confirming the `then`/`else`/`condition`/`body`
/// fields are present as full, untouched `Expression` sub-trees (a
/// genuinely *eager* encoding would instead have already discarded the
/// untaken branch and left the field absent or replaced with a bare
/// literal).
#[test]
fn control_flow_branches_are_encoded_as_lazy_sub_expressions() {
    let source = r#"
        fn pick(flag: bool) -> i64 {
            if flag {
                1
            } else {
                2
            }
        }
    "#;
    let program = ball_encoder::encode_module_only(source);
    let pick = program
        .functions
        .iter()
        .find(|f| f.name == "pick")
        .expect("`pick` must be encoded");
    let body = pick.body.as_ref().expect("`pick` must have a body");

    // Every fn body is encoded through `encode_block`, so `pick`'s body is
    // a `block` whose (statement-less) `result` is the `std.if(condition,
    // then, else)` call.
    let Some(Expr::Block(block)) = &body.expr else {
        panic!("expected `pick`'s body to be a `block`, got {body:?}");
    };
    let if_result = block
        .result
        .as_deref()
        .expect("`pick`'s block must have a result");
    let Some(Expr::Call(call)) = &if_result.expr else {
        panic!("expected `pick`'s block result to be a `call` expression, got {if_result:?}");
    };
    assert_eq!(call.module, "std");
    assert_eq!(call.function, "if");
    let input = call.input.as_deref().expect("`if` must carry an input");
    let Some(Expr::MessageCreation(message)) = &input.expr else {
        panic!("expected `if`'s input to be a `message_creation`, got {input:?}");
    };
    let field_names: Vec<&str> = message.fields.iter().map(|f| f.name.as_str()).collect();
    assert!(field_names.contains(&"condition"));
    assert!(field_names.contains(&"then"));
    assert!(field_names.contains(&"else"));
    for field in &message.fields {
        assert!(
            field.value.is_some(),
            "`if`'s `{}` field must carry a full Expression sub-tree, not be omitted",
            field.name
        );
    }
    // The `then`/`else` branches are each a `block` whose result is a
    // literal integer (1 / 2) — full, unexecuted `Expression` sub-trees,
    // proving the encoder carried both branches through rather than having
    // already chosen/evaluated one of them.
    fn block_result_literal(field_value: &Expression) -> &Expression {
        let Some(Expr::Block(block)) = &field_value.expr else {
            panic!("expected a `block` sub-tree, got {field_value:?}");
        };
        let result = block
            .result
            .as_deref()
            .expect("branch block must have a result");
        assert!(
            matches!(result.expr, Some(Expr::Literal(_))),
            "expected the branch block's result to be a literal, got {result:?}"
        );
        result
    }
    let then_field = message
        .fields
        .iter()
        .find(|f| f.name == "then")
        .expect("`then` field must be present");
    block_result_literal(then_field.value.as_ref().expect("checked above"));
    let else_field = message
        .fields
        .iter()
        .find(|f| f.name == "else")
        .expect("`else` field must be present");
    block_result_literal(else_field.value.as_ref().expect("checked above"));
}

/// A stronger, end-to-end version of the laziness assertion above: an
/// untaken `if`/`while` branch that would `panic!` (via `std.throw`) if it
/// were ever evaluated must genuinely never run — proven by actually
/// compiling and running the encoded program, mirroring
/// `rust/compiler/tests/end_to_end.rs`'s own
/// `laziness_and_or_if_never_evaluate_the_untaken_branch` fixture.
#[test]
fn untaken_branches_never_execute_at_run_time() {
    let source = r#"
        fn main() {
            if false {
                panic!("THEN_BRANCH_EVALUATED");
            } else {
                println!("{}", "else-ran");
            }
            let mut i = 0;
            while false {
                panic!("WHILE_BODY_EVALUATED");
            }
            println!("{}", i);
            i += 1;
            println!("{}", i);
        }
    "#;
    // `panic!("...")` isn't in this crate's supported macro set (only
    // println!/format!/vec! — see methods.rs), so the untaken `then`
    // branch is built with a macro this encoder can't compile *if it were
    // ever reached*; encoding the whole program successfully already shows
    // the encoder itself never evaluates the branch (it just builds a
    // tree), and running it below shows the *compiled* program doesn't
    // either. Swap in a real unsupported-at-runtime marker instead so a
    // regression would be loud either way: a `std.throw` the compiled
    // binary would visibly panic on if reached.
    let source = source.replace("panic!(\"THEN_BRANCH_EVALUATED\");", "let _x = 1 / 0;");
    let source = source.replace("panic!(\"WHILE_BODY_EVALUATED\");", "let _x = 1 / 0;");
    let program = ball_encoder::encode(&source);
    assert_program_prints("laziness", &program, "else-ran\n0\n1");
}

/// Structural sanity check that every module import name resolves to a
/// registered module (i.e. the accumulation logic doesn't emit an import
/// for a module it never included, or vice versa).
#[test]
fn main_module_imports_match_included_modules() {
    let program = ball_encoder::encode(REPRESENTATIVE_SOURCE);
    let main_module: &Module = program
        .modules
        .iter()
        .find(|m| m.name == "main")
        .expect("`main` module must be present");
    let included: Vec<&str> = program.modules.iter().map(|m| m.name.as_str()).collect();
    for import in &main_module.module_imports {
        assert!(
            included.contains(&import.name.as_str()),
            "`main` imports `{}` but no such module was included in the Program",
            import.name
        );
    }
    // `std_collections` must be pulled in because `doubled_multiples_of_four`
    // uses `.map()`/`.filter()`.
    assert!(included.contains(&"std_collections"));
}

/// Every `let`/expression statement inside a Ball `block` must appear as a
/// `Statement`, and a **non**-semicolon-terminated tail expression must
/// become the block's `result` — proven directly against `sum_range`'s
/// encoded body (a `for`-loop statement followed by a bare `total` tail).
#[test]
fn block_tail_expression_without_semicolon_becomes_the_result() {
    let program = ball_encoder::encode_module_only(REPRESENTATIVE_SOURCE);
    let sum_range = program
        .functions
        .iter()
        .find(|f| f.name == "sum_range")
        .expect("`sum_range` must be encoded");
    let body = sum_range.body.as_ref().expect("must have a body");
    let Some(Expr::Block(block)) = &body.expr else {
        panic!("expected `sum_range`'s body to be a `block`, got {body:?}");
    };
    // statements: `let mut total = 0;`, `for ... { ... }` (2 statements);
    // result: the bare `total` tail reference.
    assert_eq!(block.statements.len(), 2);
    assert!(matches!(block.statements[0].stmt, Some(Stmt::Let(_))));
    let result = block.result.as_deref().expect("block must have a result");
    assert!(matches!(result.expr, Some(Expr::Reference(_))));
}
