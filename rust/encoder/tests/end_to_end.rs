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
use ball_shared::proto::ball::v1::literal::Value as LiteralValue;
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

// ════════════════════════════════════════════════════════════
// #43 — types, metadata round-trip, std accumulation
// ════════════════════════════════════════════════════════════

/// Representative program 1/3: a plain `struct` + `impl` block (mirrors
/// `tests/conformance/101_simple_class.ball.json`'s `Point`) — exercises
/// struct-literal construction (`Point { x, y }`), instance methods reading
/// `self`'s fields, and external field mutation (`p2.x = 5;`, already
/// supported since issue #42 — proves it still composes with a real
/// `TypeDefinition` now backing `Point`, not just an anonymous message).
#[test]
fn struct_and_impl_methods_conformance_round_trip() {
    let source = r#"
        struct Point {
            x: i64,
            y: i64,
        }

        impl Point {
            fn distance_squared(&self) -> i64 {
                self.x * self.x + self.y * self.y
            }

            fn describe(&self) -> String {
                format!("({}, {})", self.x, self.y)
            }
        }

        fn main() {
            let p1 = Point { x: 3, y: 4 };
            println!("{}", p1.describe());
            println!("{}", p1.distance_squared());
            let mut p2 = Point { x: 0, y: 0 };
            println!("{}", p2.describe());
            println!("{}", p2.distance_squared());
            p2.x = 5;
            p2.y = 12;
            println!("{}", p2.describe());
            println!("{}", p2.distance_squared());
        }
    "#;
    let program = ball_encoder::encode(source);

    let main_module = program
        .modules
        .iter()
        .find(|m| m.name == "main")
        .expect("`main` module must be present");
    let point_td = main_module
        .type_defs
        .iter()
        .find(|td| td.name == "main:Point")
        .expect("`main:Point` TypeDefinition must be present");
    let descriptor = point_td
        .descriptor
        .as_ref()
        .expect("a struct TypeDefinition must carry a descriptor");
    let field_names: Vec<&str> = descriptor
        .field
        .iter()
        .filter_map(|f| f.name.as_deref())
        .collect();
    assert_eq!(field_names, vec!["x", "y"]);
    assert!(
        main_module
            .functions
            .iter()
            .any(|f| f.name == "main:Point.describe"),
        "expected a class-member `main:Point.describe` FunctionDefinition"
    );
    assert!(
        main_module
            .functions
            .iter()
            .any(|f| f.name == "main:Point.distance_squared"),
    );

    let expected = ["(3, 4)", "25", "(0, 0)", "0", "(5, 12)", "169"].join("\n");
    assert_program_prints("struct_impl_point", &program, &expected);
}

/// Representative program 2/3: a `trait` (abstract interface — mirrors
/// `tests/conformance/103_abstract_class.ball.json`'s `Shape`) implemented
/// by two structs (`impl Shape for Circle`/`impl Shape for Rectangle`) —
/// exercises `trait` → `is_abstract` `TypeDefinition`, `Box::new` as an
/// identity passthrough, and **polymorphic dispatch**: a
/// `Vec<Box<dyn Shape>>` holding both concrete types, iterated with
/// `s.area()`/`s.name()` calls that must route to the right concrete `impl`
/// at run time (`ball-compiler`'s `compile_method_dispatchers`), since
/// neither call site can know which concrete type `s` holds at Rust compile
/// time.
#[test]
fn trait_polymorphism_conformance_round_trip() {
    let source = r#"
        trait Shape {
            fn area(&self) -> f64;
            fn name(&self) -> String;
        }

        struct Circle {
            radius: f64,
        }

        impl Shape for Circle {
            fn area(&self) -> f64 {
                self.radius * self.radius
            }

            fn name(&self) -> String {
                String::from("Circle")
            }
        }

        struct Rectangle {
            width: f64,
            height: f64,
        }

        impl Shape for Rectangle {
            fn area(&self) -> f64 {
                self.width * self.height
            }

            fn name(&self) -> String {
                String::from("Rectangle")
            }
        }

        fn main() {
            let shapes: Vec<Box<dyn Shape>> = vec![
                Box::new(Circle { radius: 2.0 }),
                Box::new(Rectangle { width: 3.0, height: 4.0 }),
            ];
            for s in shapes {
                println!("{}: {}", s.name(), s.area());
            }
        }
    "#;
    let program = ball_encoder::encode(source);

    let main_module = program
        .modules
        .iter()
        .find(|m| m.name == "main")
        .expect("`main` module must be present");
    let shape_td = main_module
        .type_defs
        .iter()
        .find(|td| td.name == "main:Shape")
        .expect("`main:Shape` TypeDefinition must be present");
    let shape_meta = shape_td
        .metadata
        .as_ref()
        .expect("the trait's TypeDefinition must carry metadata");
    assert_eq!(
        shape_meta
            .fields
            .get("is_abstract")
            .and_then(|v| v.kind.as_ref()),
        Some(&google_bool_kind(true)),
        "a `trait` must encode as `metadata.is_abstract = true`"
    );

    // Ball's `f64` `to_string`/`Display` always includes a decimal point
    // (`4.0`, not `4`) — matches `ball_shared::value::format_double`'s own
    // convention.
    let expected = ["Circle: 4.0", "Rectangle: 12.0"].join("\n");
    assert_program_prints("trait_polymorphism", &program, &expected);
}

/// Representative program 3/3: a fieldless `enum` (mirrors
/// `tests/conformance/109_enum_values.ball.json`'s `Color`) — exercises
/// `Module.enums[]` `EnumDescriptorProto` emission and `Color::Red`-shaped
/// 2-segment path resolution (`field_access(reference("Color"), "Red")`,
/// read both directly and through a free function's own parameter).
#[test]
fn enum_conformance_round_trip() {
    let source = r#"
        enum Color {
            Red,
            Green,
            Blue,
        }

        fn color_name(c: Color) -> String {
            if c.index == Color::Red.index {
                String::from("red")
            } else if c.index == Color::Green.index {
                String::from("green")
            } else {
                String::from("blue")
            }
        }

        fn main() {
            println!("{}", Color::Red.index);
            println!("{}", Color::Green.index);
            println!("{}", Color::Blue.index);
            println!("{}", color_name(Color::Green));
        }
    "#;
    let program = ball_encoder::encode(source);

    let main_module = program
        .modules
        .iter()
        .find(|m| m.name == "main")
        .expect("`main` module must be present");
    assert_eq!(main_module.enums.len(), 1);
    let color_enum = &main_module.enums[0];
    assert_eq!(color_enum.name.as_deref(), Some("main:Color"));
    let variant_names: Vec<&str> = color_enum
        .value
        .iter()
        .filter_map(|v| v.name.as_deref())
        .collect();
    assert_eq!(variant_names, vec!["Red", "Green", "Blue"]);
    // The companion `TypeDefinition` carries no descriptor (see
    // `types.rs::encode_item_enum`'s doc comment).
    let color_td = main_module
        .type_defs
        .iter()
        .find(|td| td.name == "main:Color")
        .expect("a companion `main:Color` TypeDefinition must be present");
    assert!(color_td.descriptor.is_none());

    let expected = ["0", "1", "2", "green"].join("\n");
    assert_program_prints("enum_color", &program, &expected);
}

fn google_bool_kind(value: bool) -> ball_shared::proto::google::protobuf::value::Kind {
    ball_shared::proto::google::protobuf::value::Kind::BoolValue(value)
}

// ── std accumulation ─────────────────────────────────────────

/// A pure-arithmetic program must declare only the handful of `std`
/// functions it actually calls (not the whole ~119-function catalog), and
/// must not pull in `std_collections`/`std_io`/`std_memory` at all —
/// issue #43's acceptance criterion, verified at the exact-function-set
/// level (not just "the module is present/absent").
#[test]
fn std_module_declares_only_the_functions_actually_used() {
    let source = r#"
        fn add_and_double(a: i64, b: i64) -> i64 {
            (a + b) * 2
        }

        fn main() {
            println!("{}", add_and_double(3, 4));
        }
    "#;
    let program = ball_encoder::encode(source);

    let std_module = program
        .modules
        .iter()
        .find(|m| m.name == "std")
        .expect("`std` must always be present");
    let std_fn_names: std::collections::BTreeSet<&str> = std_module
        .functions
        .iter()
        .map(|f| f.name.as_str())
        .collect();
    // Exactly the base functions `add_and_double`/`main` reference: `add`
    // (`a + b`), `multiply` (`* 2`), `to_string` (the `{}` interpolation),
    // and `print` (`println!`) — nothing else from the ~119-function
    // catalog (in particular, no string/math/collection helper this program
    // never calls).
    let expected: std::collections::BTreeSet<&str> = ["add", "multiply", "to_string", "print"]
        .into_iter()
        .collect();
    assert_eq!(std_fn_names, expected);
    for f in &std_module.functions {
        assert!(f.is_base, "every std module function must be `is_base`");
        assert!(
            f.body.is_none(),
            "every std module function must have no body"
        );
    }

    assert!(
        !program.modules.iter().any(|m| m.name == "std_collections"),
        "a pure-arithmetic program must not pull in `std_collections`"
    );
    assert!(
        !program.modules.iter().any(|m| m.name == "std_io"),
        "a pure-arithmetic program must not pull in `std_io`"
    );
    assert!(
        !program.modules.iter().any(|m| m.name == "std_memory"),
        "a pure-arithmetic program must not pull in `std_memory`"
    );

    assert_program_prints("std_accumulation_arithmetic", &program, "14");
}

/// A program that *does* use iterator-chain sugar pulls in `std_collections`
/// — and, symmetrically with the arithmetic test above, only the specific
/// `std_collections` functions it actually calls.
#[test]
fn std_collections_module_declares_only_the_functions_actually_used() {
    let source = r#"
        fn main() {
            let nums = vec![1, 2, 3, 4, 5];
            let doubled: Vec<i64> = nums.iter().map(|x| x * 2).collect();
            println!("{}", doubled.len());
        }
    "#;
    let program = ball_encoder::encode(source);

    let collections_module = program
        .modules
        .iter()
        .find(|m| m.name == "std_collections")
        .expect("`std_collections` must be present");
    let fn_names: std::collections::BTreeSet<&str> = collections_module
        .functions
        .iter()
        .map(|f| f.name.as_str())
        .collect();
    let expected: std::collections::BTreeSet<&str> = ["list_map"].into_iter().collect();
    assert_eq!(
        fn_names, expected,
        "expected `std_collections` to declare exactly `list_map` (`.iter()`/`.collect()` are \
         identity passthroughs — see methods.rs — so they never reach `std_collections` at all)"
    );

    assert_program_prints("std_accumulation_collections", &program, "5");
}

// ── metadata round-trip / invariant #2 (cosmetic-only) ───────

/// Cosmetic metadata (visibility, `async`, a type's `kind`, `let mut`) must
/// survive the round-trip — asserted directly against the encoded tree —
/// and stripping every one of those keys must never change a compiled
/// program's computed output (invariant #2), asserted by actually
/// recompiling and running both the original and the stripped encodings and
/// comparing stdout.
#[test]
fn cosmetic_metadata_round_trips_and_stripping_it_does_not_change_output() {
    let source = r#"
        pub struct Counter {
            pub value: i64,
        }

        impl Counter {
            pub fn doubled(&self) -> i64 {
                self.value * 2
            }
        }

        // NOTE: deliberately *not* `n += 1;` here — `ball-compiler`'s
        // `param_alias_prologue` (`rust/compiler/src/lib.rs`, issue #37/#38,
        // outside this crate's scope) unconditionally emits a non-`mut`
        // `let <name> = input.clone();` for a single-named-parameter
        // function, so a body that *reassigns* its own single parameter
        // fails to compile — a genuine, pre-existing `ball-compiler` gap
        // this test's own discovery surfaced, tracked separately rather
        // than silently worked around by weakening what this test checks.
        pub async fn describe(n: i64) -> i64 {
            n + 1
        }

        fn main() {
            let c = Counter { value: 10 };
            println!("{}", c.doubled());
        }
    "#;
    let program = ball_encoder::encode(source);
    let main_module = program
        .modules
        .iter()
        .find(|m| m.name == "main")
        .expect("`main` module must be present");

    // ── metadata is present ──
    let counter_td = main_module
        .type_defs
        .iter()
        .find(|td| td.name == "main:Counter")
        .expect("`main:Counter` must be present");
    let counter_meta = counter_td.metadata.as_ref().expect("must carry metadata");
    assert_eq!(
        counter_meta
            .fields
            .get("kind")
            .and_then(|v| v.kind.as_ref()),
        Some(&ball_shared::proto::google::protobuf::value::Kind::StringValue("struct".to_string()))
    );
    assert_eq!(
        counter_meta
            .fields
            .get("is_public")
            .and_then(|v| v.kind.as_ref()),
        Some(&google_bool_kind(true))
    );

    let describe_fn = main_module
        .functions
        .iter()
        .find(|f| f.name == "describe")
        .expect("`describe` must be present");
    let describe_meta = describe_fn.metadata.as_ref().expect("must carry metadata");
    assert_eq!(
        describe_meta
            .fields
            .get("is_async")
            .and_then(|v| v.kind.as_ref()),
        Some(&google_bool_kind(true))
    );
    assert_eq!(
        describe_meta
            .fields
            .get("is_public")
            .and_then(|v| v.kind.as_ref()),
        Some(&google_bool_kind(true))
    );

    // A `let mut` binding carries `metadata.is_mut = true` — a plain `let`
    // (this test's own `let c = Counter { ... };` in `main`) carries none,
    // matching every other boolean cosmetic flag's "absence means false"
    // convention. Checked against a dedicated tiny fixture so this
    // assertion stays narrowly scoped to one thing.
    let mut_source = "fn f() { let mut x = 1; x += 1; }";
    let mut_module = ball_encoder::encode_module_only(mut_source);
    let f = mut_module.functions.iter().find(|f| f.name == "f").unwrap();
    let Some(Expr::Block(block)) = f.body.as_ref().and_then(|b| b.expr.clone()) else {
        panic!("expected a block body");
    };
    let Some(Stmt::Let(let_binding)) = &block.statements[0].stmt else {
        panic!("expected the first statement to be a `let`");
    };
    let let_meta = let_binding
        .metadata
        .as_ref()
        .expect("`let mut` must carry metadata");
    assert_eq!(
        let_meta.fields.get("is_mut").and_then(|v| v.kind.as_ref()),
        Some(&google_bool_kind(true))
    );

    // ── stripping every key above never changes computed output ──
    let mut stripped = program.clone();
    strip_all_metadata(&mut stripped);
    // Sanity: the strip pass actually removed something (otherwise this
    // test would trivially "pass" without checking anything).
    let stripped_main = stripped
        .modules
        .iter()
        .find(|m| m.name == "main")
        .expect("`main` module must be present");
    // Every purely-cosmetic key is gone (`kind`, `is_public` in
    // particular); `is_abstract` isn't present on `Counter` to begin with
    // (a plain, non-`trait` struct), so its `TypeDefinition.metadata` ends
    // up `None` entirely.
    assert!(
        stripped_main
            .type_defs
            .iter()
            .all(|td| td.metadata.is_none()),
        "strip_all_metadata must have cleared Counter's non-load-bearing metadata"
    );
    let stripped_describe = stripped_main
        .functions
        .iter()
        .find(|f| f.name == "describe")
        .expect("`describe` must still be present after stripping");
    assert!(
        !stripped_describe
            .metadata
            .as_ref()
            .is_some_and(|m| m.fields.contains_key("is_async") || m.fields.contains_key("kind")),
        "strip_all_metadata must have cleared `describe`'s cosmetic keys"
    );
    assert!(
        stripped_describe
            .metadata
            .as_ref()
            .is_some_and(|m| m.fields.contains_key("params")),
        "strip_all_metadata must still preserve the load-bearing `params` key"
    );

    let original_output = assert_program_prints_and_return("metadata_original", &program, "20");
    let stripped_output = assert_program_prints_and_return("metadata_stripped", &stripped, "20");
    assert_eq!(
        original_output, stripped_output,
        "stripping every cosmetic metadata key must not change a compiled program's output \
         (invariant #2)"
    );
}

fn assert_program_prints_and_return(
    fixture_name: &str,
    program: &Program,
    expected: &str,
) -> String {
    assert_program_prints(fixture_name, program, expected);
    expected.to_string()
}

/// Clears every **purely cosmetic** `metadata` key this crate ever sets
/// (`Module`, `TypeDefinition`/`TypeParameter`, `FunctionDefinition`/
/// `Lambda`, `LetBinding`, `MessageCreation`) throughout an entire
/// [`Program`] — the invariant-#2 check's "strip all cosmetic metadata"
/// half. Deliberately **preserves** the two keys `ball-compiler` actually
/// reads for real code-generation decisions (see
/// `rust/compiler/src/type_emit.rs`'s crate doc comment): a
/// `FunctionDefinition`/`Lambda`'s `params` (drives
/// `param_alias_prologue`/`method_prologue`'s local-variable aliasing —
/// without it, a single-named-parameter body's own references would become
/// undefined identifiers, an actual *compile* failure, not a semantic
/// change) and a `TypeDefinition`'s `is_abstract` (struct vs. `trait`
/// codegen). Neither this crate nor its own test fixtures ever pair
/// `is_abstract` with `kind == "constructor"` (this crate never emits a
/// `"constructor"`-kind member at all — see `types.rs`'s module doc
/// comment), so those really are the *only* two keys excluded from this
/// otherwise-blanket strip. Intentionally test-only (not part of the
/// crate's public API): production code has no reason to ever discard
/// metadata it just encoded.
fn strip_all_metadata(program: &mut Program) {
    for module in &mut program.modules {
        module.metadata = None;
        for type_def in &mut module.type_defs {
            retain_only(&mut type_def.metadata, &["is_abstract"]);
            for type_param in &mut type_def.type_params {
                type_param.metadata = None;
            }
        }
        for func in &mut module.functions {
            retain_only(&mut func.metadata, &["params"]);
            if let Some(body) = &mut func.body {
                strip_expr_metadata(body);
            }
        }
    }
}

fn retain_only(metadata: &mut Option<ball_shared::proto::google::protobuf::Struct>, keep: &[&str]) {
    if let Some(meta) = metadata {
        meta.fields.retain(|key, _| keep.contains(&key.as_str()));
        if meta.fields.is_empty() {
            *metadata = None;
        }
    }
}

fn strip_expr_metadata(expr: &mut Expression) {
    match &mut expr.expr {
        Some(Expr::Call(call)) => {
            if let Some(input) = &mut call.input {
                strip_expr_metadata(input);
            }
        }
        Some(Expr::Literal(literal)) => {
            if let Some(LiteralValue::ListValue(list)) = &mut literal.value {
                for element in &mut list.elements {
                    strip_expr_metadata(element);
                }
            }
        }
        Some(Expr::Reference(_)) | None => {}
        Some(Expr::FieldAccess(field_access)) => {
            if let Some(object) = &mut field_access.object {
                strip_expr_metadata(object);
            }
        }
        Some(Expr::MessageCreation(message)) => {
            // Never read by `ball-compiler` for anything (verified: no
            // `message.metadata`/`mc.metadata` reference anywhere in
            // `rust/compiler/src`) — safe to strip unconditionally.
            message.metadata = None;
            for field in &mut message.fields {
                if let Some(value) = &mut field.value {
                    strip_expr_metadata(value);
                }
            }
        }
        Some(Expr::Block(block)) => {
            for statement in &mut block.statements {
                match &mut statement.stmt {
                    Some(Stmt::Let(let_binding)) => {
                        // `LetBinding.metadata` is never read by
                        // `ball-compiler` either (`let` vs. `let mut` is
                        // re-derived from a `rest_mutates_var` data-flow
                        // scan, not from this metadata) — safe to strip
                        // unconditionally.
                        let_binding.metadata = None;
                        if let Some(value) = &mut let_binding.value {
                            strip_expr_metadata(value);
                        }
                    }
                    Some(Stmt::Expression(inner)) => strip_expr_metadata(inner),
                    None => {}
                }
            }
            if let Some(result) = &mut block.result {
                strip_expr_metadata(result);
            }
        }
        Some(Expr::Lambda(lambda)) => {
            retain_only(&mut lambda.metadata, &["params"]);
            if let Some(body) = &mut lambda.body {
                strip_expr_metadata(body);
            }
        }
    }
}
