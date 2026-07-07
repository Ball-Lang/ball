//! Phase 2a end-to-end conformance: compile a Ball [`Program`] to Rust with
//! [`ball_compiler::Compiler`], then actually run the Rust toolchain
//! (`cargo run`, which invokes `rustc` under the hood) against the emitted
//! source and assert on the compiled binary's stdout. This is the same
//! "compile -> execute with the native toolchain -> compare" idiom the
//! TypeScript compiler's tests use (`ts/compiler/test/hello_world.test.ts`,
//! `execSync("node ...")`), adapted to Rust's `cargo`/`rustc`.
//!
//! Fixtures:
//! - `hello_world` / `fibonacci` — loaded from the real, cross-language
//!   `examples/*.ball.json` fixtures (proto3 JSON), round-tripped through
//!   `prost-reflect` exactly like `ball-shared`'s own test does
//!   (`rust/shared/src/lib.rs`).
//! - `factorial` and a `closures` fixture — issue #36's acceptance criteria
//!   name these explicitly, but neither exists as a committed
//!   `examples/`/`tests/conformance/` fixture yet (`examples/factorial/`
//!   doesn't exist; committing a new cross-language example is a repo-wide
//!   decision out of scope for this compiler-only issue), so they're built
//!   directly as `ball.v1.Program` values here, mirroring the same
//!   struct-literal style `rust/shared/src/value.rs`'s tests already use.
//! - `block_tail_value` / `field_access_and_message_creation` — small
//!   dedicated fixtures proving `block`'s tail-expression semantics and the
//!   `message_creation`/`field_access` pair, so all seven `Expression` node
//!   types are exercised by at least one passing, rustc-executed fixture.
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

use ball_compiler::Compiler;
use ball_shared::DESCRIPTOR_POOL;
use ball_shared::proto::ball::v1::expression::Expr;
use ball_shared::proto::ball::v1::literal::Value as LiteralValue;
use ball_shared::proto::ball::v1::statement::Stmt;
use ball_shared::proto::ball::v1::{
    Block, Expression, FieldAccess, FieldValuePair, FunctionCall, FunctionDefinition, LetBinding,
    Literal, MessageCreation, Module, ModuleImport, Program, Reference, Statement,
};
use ball_shared::proto::google::protobuf::value::Kind;
use ball_shared::proto::google::protobuf::{ListValue, Struct, Value};
use prost::Message;
use prost_reflect::DynamicMessage;

// ════════════════════════════════════════════════════════════
// Ball-expression construction helpers (mirror rust/shared/src/value.rs's
// test style)
// ════════════════════════════════════════════════════════════

fn int_lit(value: i64) -> Expression {
    Expression {
        expr: Some(Expr::Literal(Literal {
            value: Some(LiteralValue::IntValue(value)),
        })),
    }
}

fn reference(name: &str) -> Expression {
    Expression {
        expr: Some(Expr::Reference(Reference {
            name: name.to_string(),
        })),
    }
}

fn field_access(object: Expression, field: &str) -> Expression {
    Expression {
        expr: Some(Expr::FieldAccess(Box::new(FieldAccess {
            object: Some(Box::new(object)),
            field: field.to_string(),
        }))),
    }
}

/// An anonymous (`type_name` empty) `message_creation` — the "pack named
/// arguments for a base-function call" shape.
fn args(fields: Vec<(&str, Expression)>) -> Expression {
    Expression {
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
    }
}

/// A named (`type_name` non-empty) `message_creation` — a typed instance.
fn message(type_name: &str, fields: Vec<(&str, Expression)>) -> Expression {
    Expression {
        expr: Some(Expr::MessageCreation(MessageCreation {
            type_name: type_name.to_string(),
            fields: fields
                .into_iter()
                .map(|(name, value)| FieldValuePair {
                    name: name.to_string(),
                    value: Some(value),
                })
                .collect(),
            metadata: None,
        })),
    }
}

fn call(module: &str, function: &str, input: Option<Expression>) -> Expression {
    Expression {
        expr: Some(Expr::Call(Box::new(FunctionCall {
            module: module.to_string(),
            function: function.to_string(),
            input: input.map(Box::new),
            type_args: vec![],
        }))),
    }
}

fn let_stmt(name: &str, value: Expression) -> Statement {
    Statement {
        stmt: Some(Stmt::Let(LetBinding {
            name: name.to_string(),
            value: Some(value),
            metadata: None,
        })),
    }
}

fn expr_stmt(value: Expression) -> Statement {
    Statement {
        stmt: Some(Stmt::Expression(value)),
    }
}

fn block(statements: Vec<Statement>, result: Expression) -> Expression {
    Expression {
        expr: Some(Expr::Block(Box::new(Block {
            statements,
            result: Some(Box::new(result)),
        }))),
    }
}

fn lambda(body: Expression) -> Expression {
    Expression {
        expr: Some(Expr::Lambda(Box::new(FunctionDefinition {
            name: String::new(),
            input_type: String::new(),
            output_type: String::new(),
            body: Some(Box::new(body)),
            description: String::new(),
            is_base: false,
            metadata: None,
        }))),
    }
}

/// Builds the `metadata.params = [{name: <name>}]` shape the Dart/C++/TS
/// compilers' encoders emit for a single positional parameter (see
/// `dart/compiler/lib/compiler.dart`'s `_addParameters`), which
/// `Compiler::param_alias_prologue` reads to alias `input` to a readable
/// name.
fn single_param_metadata(name: &str) -> Struct {
    let mut param_fields = HashMap::new();
    param_fields.insert(
        "name".to_string(),
        Value {
            kind: Some(Kind::StringValue(name.to_string())),
        },
    );
    let mut fields = HashMap::new();
    fields.insert(
        "params".to_string(),
        Value {
            kind: Some(Kind::ListValue(ListValue {
                values: vec![Value {
                    kind: Some(Kind::StructValue(Struct {
                        fields: param_fields,
                    })),
                }],
            })),
        },
    );
    Struct { fields }
}

fn user_fn(
    name: &str,
    input_type: &str,
    output_type: &str,
    body: Expression,
    param_name: Option<&str>,
) -> FunctionDefinition {
    FunctionDefinition {
        name: name.to_string(),
        input_type: input_type.to_string(),
        output_type: output_type.to_string(),
        body: Some(Box::new(body)),
        description: String::new(),
        is_base: false,
        metadata: param_name.map(single_param_metadata),
    }
}

fn program_with_main(functions: Vec<FunctionDefinition>) -> Program {
    Program {
        name: "test".to_string(),
        version: "1.0.0".to_string(),
        modules: vec![
            ball_shared::build_std_module(),
            Module {
                name: "main".to_string(),
                functions,
                module_imports: vec![ModuleImport {
                    name: "std".to_string(),
                    ..Default::default()
                }],
                ..Default::default()
            },
        ],
        entry_module: "main".to_string(),
        entry_function: "main".to_string(),
        metadata: None,
    }
}

/// `print(to_string(<value>))` — the shape both `hello_world` and
/// `fibonacci` use for their final output.
fn print_to_string(value: Expression) -> Expression {
    call(
        "std",
        "print",
        Some(message(
            "PrintInput",
            vec![(
                "message",
                call("std", "to_string", Some(args(vec![("value", value)]))),
            )],
        )),
    )
}

// ════════════════════════════════════════════════════════════
// examples/*.ball.json loader (mirrors rust/shared/src/lib.rs's round trip)
// ════════════════════════════════════════════════════════════

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

fn load_example(name: &str) -> Program {
    let path = repo_root()
        .join("examples")
        .join(name)
        .join(format!("{name}.ball.json"));
    let json = fs::read_to_string(&path)
        .unwrap_or_else(|err| panic!("failed to read {}: {err}", path.display()));
    let mut json_value: serde_json::Value =
        serde_json::from_str(&json).expect("example .ball.json must be valid JSON");
    if let serde_json::Value::Object(map) = &mut json_value {
        map.remove("@type");
    }
    let program_descriptor = DESCRIPTOR_POOL
        .get_message_by_name("ball.v1.Program")
        .expect("ball.v1.Program must be resolvable from the embedded descriptor pool");
    let dynamic =
        DynamicMessage::deserialize(program_descriptor, json_value).unwrap_or_else(|err| {
            panic!("{name}.ball.json must deserialize as a ball.v1.Program: {err}")
        });
    Program::decode(dynamic.encode_to_vec().as_slice())
        .expect("binary re-encoded from the DynamicMessage must decode as a typed ball.v1.Program")
}

// ════════════════════════════════════════════════════════════
// rustc/cargo execution harness
// ════════════════════════════════════════════════════════════

static FIXTURE_COUNTER: AtomicU64 = AtomicU64::new(0);

fn workspace_root() -> PathBuf {
    // CARGO_MANIFEST_DIR = .../rust/compiler; the workspace root (containing
    // the member crates + the shared, git-ignored `target/`) is its parent.
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("rust/compiler must have a parent directory")
        .to_path_buf()
}

/// Writes `rust_src` as the `main.rs` of a small standalone Cargo package
/// (depending on `ball-shared` via a path dependency), builds and runs it
/// with `cargo run`, and returns its captured stdout. Panics with the
/// compiler/runtime output on any failure so a failing fixture's assertion
/// message is immediately actionable.
///
/// The throwaway package's `--target-dir` is pointed at the *workspace's
/// own* `target/` directory (not a fresh temp one) so `ball-shared` and its
/// dependency tree — already built for `cargo test -p ball-compiler` itself
/// — are reused instead of rebuilt from scratch per fixture.
fn compile_and_run(fixture_name: &str, rust_src: &str) -> String {
    let workspace_root = workspace_root();
    let target_dir = workspace_root.join("target");
    let unique = FIXTURE_COUNTER.fetch_add(1, Ordering::Relaxed);
    let fixture_dir = std::env::temp_dir().join(format!(
        "ball_rustc_fixture_{fixture_name}_{}_{unique}",
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
        "[package]\nname = \"ball_fixture_{fixture_name}\"\nversion = \"0.0.0\"\nedition = \"2024\"\npublish = false\n\n\
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
// Fixtures
// ════════════════════════════════════════════════════════════

#[test]
fn hello_world_compiles_and_runs() {
    let program = load_example("hello_world");
    assert_program_prints("hello_world", &program, "Hello, World!");
}

#[test]
fn fibonacci_compiles_and_runs() {
    // examples/fibonacci/fibonacci.ball.json computes fibonacci(10) and
    // prints it. Dart's reference engine (the conformance oracle) is
    // 1-indexed with fibonacci(1) == 1: 1,1,2,3,5,8,13,21,34,55 -> the 10th
    // term is 55.
    let program = load_example("fibonacci");
    assert_program_prints("fibonacci", &program, "55");
}

/// Recursive `factorial`, structurally mirroring `fibonacci.ball.json`
/// (`if`/`lte`/`return` base case, `multiply`/`subtract` recursive case) —
/// see the module doc comment for why this is a hand-built fixture rather
/// than `examples/factorial/`.
#[test]
fn factorial_compiles_and_runs() {
    let factorial_body = block(
        vec![expr_stmt(call(
            "std",
            "if",
            Some(args(vec![
                (
                    "condition",
                    call(
                        "std",
                        "lte",
                        Some(args(vec![("left", reference("n")), ("right", int_lit(1))])),
                    ),
                ),
                (
                    "then",
                    call("std", "return", Some(args(vec![("value", int_lit(1))]))),
                ),
            ])),
        ))],
        call(
            "std",
            "multiply",
            Some(args(vec![
                ("left", reference("n")),
                (
                    "right",
                    call(
                        "",
                        "factorial",
                        Some(call(
                            "std",
                            "subtract",
                            Some(args(vec![("left", reference("n")), ("right", int_lit(1))])),
                        )),
                    ),
                ),
            ])),
        ),
    );
    let main_body = block(
        vec![let_stmt("result", call("", "factorial", Some(int_lit(5))))],
        print_to_string(reference("result")),
    );
    let program = program_with_main(vec![
        user_fn("factorial", "int", "int", factorial_body, Some("n")),
        user_fn("main", "", "void", main_body, None),
    ]);
    assert_program_prints("factorial", &program, "120");
}

/// Proves a `lambda` correctly captures (`n`, from the enclosing block) and
/// uses (`input`, its own parameter) values from two different scopes:
/// `(input) => add(input, n)` closed over `n = 10`, called with `5`, must
/// yield `15`. Because a `let`-bound lambda is called through the exact
/// same Rust call syntax as a named function (see `compile_call`'s doc
/// comment), this exercises `lambda` + `block` + `call` + `reference`
/// together.
#[test]
fn closures_compile_and_run() {
    let adder_lambda = lambda(call(
        "std",
        "add",
        Some(args(vec![
            ("left", reference("input")),
            ("right", reference("n")),
        ])),
    ));
    let main_body = block(
        vec![let_stmt("n", int_lit(10)), let_stmt("adder", adder_lambda)],
        print_to_string(call("", "adder", Some(int_lit(5)))),
    );
    let program = program_with_main(vec![user_fn("main", "", "void", main_body, None)]);
    assert_program_prints("closures", &program, "15");
}

/// A `block`'s value is its **last** (`result`) expression, not its first
/// statement — proven by a block whose intermediate `let`s would produce a
/// different value than the tail if tail-expression semantics were wrong.
#[test]
fn block_tail_expression_determines_value() {
    let main_body = block(
        vec![let_stmt("a", int_lit(1)), let_stmt("b", int_lit(2))],
        print_to_string(call(
            "std",
            "add",
            Some(args(vec![
                ("left", reference("a")),
                ("right", reference("b")),
            ])),
        )),
    );
    let program = program_with_main(vec![user_fn("main", "", "void", main_body, None)]);
    assert_program_prints("block_tail_value", &program, "3");
}

/// `message_creation` (a named `Point` instance) + `field_access` (reading
/// `.x` back off it) round-tripped through a real compiled-and-run binary.
#[test]
fn message_creation_and_field_access_compile_and_run() {
    let point = message("Point", vec![("x", int_lit(42))]);
    let main_body = print_to_string(field_access(point, "x"));
    let program = program_with_main(vec![user_fn("main", "", "void", main_body, None)]);
    assert_program_prints("field_access", &program, "42");
}
