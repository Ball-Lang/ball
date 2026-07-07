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
    ListLiteral, Literal, MessageCreation, Module, ModuleImport, Program, Reference, Statement,
    TypeDefinition,
};
use ball_shared::proto::google::protobuf::field_descriptor_proto::{Label, Type};
use ball_shared::proto::google::protobuf::value::Kind;
use ball_shared::proto::google::protobuf::{
    DescriptorProto, FieldDescriptorProto, ListValue, Struct, Value,
};
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
            // Every #37 fixture below is free to reach for `std_collections`/
            // `std_io` base calls (e.g. `list_push`) without each test having
            // to opt in individually — registering the module is what makes
            // `Compiler::is_base_module` recognize it; it's a no-op for
            // fixtures that never call into it.
            ball_shared::build_std_collections_module(),
            ball_shared::build_std_io_module(),
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

// ════════════════════════════════════════════════════════════
// #37 helpers: literals, operators, control flow, assignment
// ════════════════════════════════════════════════════════════

fn string_lit(value: &str) -> Expression {
    Expression {
        expr: Some(Expr::Literal(Literal {
            value: Some(LiteralValue::StringValue(value.to_string())),
        })),
    }
}

fn bool_lit(value: bool) -> Expression {
    Expression {
        expr: Some(Expr::Literal(Literal {
            value: Some(LiteralValue::BoolValue(value)),
        })),
    }
}

fn list_lit(elements: Vec<Expression>) -> Expression {
    Expression {
        expr: Some(Expr::Literal(Literal {
            value: Some(LiteralValue::ListValue(ListLiteral { elements })),
        })),
    }
}

/// A binary `std` base call: `bin_call("add", left, right)` == Ball's
/// `add(left: left, right: right)`.
fn bin_call(function: &str, left: Expression, right: Expression) -> Expression {
    call(
        "std",
        function,
        Some(args(vec![("left", left), ("right", right)])),
    )
}

/// A unary `std` base call (`UnaryInput { value }`).
fn un_call(function: &str, value: Expression) -> Expression {
    call("std", function, Some(args(vec![("value", value)])))
}

fn print_msg(message: Expression) -> Expression {
    call(
        "std",
        "print",
        Some(message_input("PrintInput", vec![("message", message)])),
    )
}

/// Named-type `message_creation` helper — same shape as `message()`, kept
/// as a distinct name here only for readability at call sites that want to
/// emphasize "this is a base function's typed input", not a user type.
fn message_input(type_name: &str, fields: Vec<(&str, Expression)>) -> Expression {
    message(type_name, fields)
}

/// Prints `tag` (a side effect) and then evaluates to `value` — used to make
/// laziness observable: if a supposedly-unevaluated branch runs, `tag`
/// appears in the captured stdout.
fn tap_print(tag: &str, value: Expression) -> Expression {
    block(vec![expr_stmt(print_msg(string_lit(tag)))], value)
}

fn assign_expr(target: Expression, value: Expression, op: &str) -> Expression {
    call(
        "std",
        "assign",
        Some(args(vec![
            ("target", target),
            ("value", value),
            ("op", string_lit(op)),
        ])),
    )
}

fn break_expr() -> Expression {
    call("std", "break", None)
}

fn continue_expr() -> Expression {
    call("std", "continue", None)
}

fn return_expr(value: Expression) -> Expression {
    call("std", "return", Some(args(vec![("value", value)])))
}

fn if_expr(condition: Expression, then: Expression, else_branch: Expression) -> Expression {
    call(
        "std",
        "if",
        Some(args(vec![
            ("condition", condition),
            ("then", then),
            ("else", else_branch),
        ])),
    )
}

/// A `for` init clause: a block of fresh `let`-bindings with no result
/// (`for (var i = 0, ...; ...)`) — the shape `Compiler::compile_for_init`
/// recognizes and declares `let mut`.
fn for_init_lets(bindings: Vec<(&str, Expression)>) -> Expression {
    Expression {
        expr: Some(Expr::Block(Box::new(Block {
            statements: bindings
                .into_iter()
                .map(|(name, value)| let_stmt(name, value))
                .collect(),
            result: None,
        }))),
    }
}

fn for_loop(
    init: Expression,
    condition: Expression,
    update: Expression,
    body: Expression,
) -> Expression {
    call(
        "std",
        "for",
        Some(args(vec![
            ("init", init),
            ("condition", condition),
            ("update", update),
            ("body", body),
        ])),
    )
}

fn for_in_loop(variable: &str, iterable: Expression, body: Expression) -> Expression {
    call(
        "std",
        "for_in",
        Some(args(vec![
            ("variable", string_lit(variable)),
            ("iterable", iterable),
            ("body", body),
        ])),
    )
}

fn while_loop(condition: Expression, body: Expression) -> Expression {
    call(
        "std",
        "while",
        Some(args(vec![("condition", condition), ("body", body)])),
    )
}

fn do_while_loop(body: Expression, condition: Expression) -> Expression {
    call(
        "std",
        "do_while",
        Some(args(vec![("body", body), ("condition", condition)])),
    )
}

fn switch_case(value: Expression, body: Expression) -> Expression {
    message(
        "SwitchCase",
        vec![
            ("value", value),
            ("is_default", bool_lit(false)),
            ("body", body),
        ],
    )
}

fn switch_default(body: Expression) -> Expression {
    message(
        "SwitchCase",
        vec![("is_default", bool_lit(true)), ("body", body)],
    )
}

fn switch_expr(subject: Expression, cases: Vec<Expression>) -> Expression {
    call(
        "std",
        "switch",
        Some(args(vec![("subject", subject), ("cases", list_lit(cases))])),
    )
}

fn throw_expr(value: Expression) -> Expression {
    call("std", "throw", Some(args(vec![("value", value)])))
}

fn catch_clause(variable: &str, body: Expression) -> Expression {
    message(
        "CatchClause",
        vec![("variable", string_lit(variable)), ("body", body)],
    )
}

fn try_expr(body: Expression, catches: Vec<Expression>) -> Expression {
    call(
        "std",
        "try",
        Some(args(vec![("body", body), ("catches", list_lit(catches))])),
    )
}

fn list_push_call(list: Expression, value: Expression) -> Expression {
    call(
        "std_collections",
        "list_push",
        Some(args(vec![("list", list), ("value", value)])),
    )
}

fn list_set_call(list: Expression, index: Expression, value: Expression) -> Expression {
    call(
        "std_collections",
        "list_set",
        Some(args(vec![
            ("list", list),
            ("index", index),
            ("value", value),
        ])),
    )
}

fn list_pop_call(list: Expression) -> Expression {
    call(
        "std_collections",
        "list_pop",
        Some(args(vec![("list", list)])),
    )
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

/// Load a `.ball.json` file (a self-describing `google.protobuf.Any`-style
/// envelope carrying a cosmetic `"@type"` key — see `rust/shared/src/lib.rs`'s
/// own round-trip test) at `path` into a typed `Program`.
fn load_program_file(path: &std::path::Path) -> Program {
    let json = fs::read_to_string(path)
        .unwrap_or_else(|err| panic!("failed to read {}: {err}", path.display()));
    let mut json_value: serde_json::Value =
        serde_json::from_str(&json).expect(".ball.json must be valid JSON");
    if let serde_json::Value::Object(map) = &mut json_value {
        map.remove("@type");
    }
    let program_descriptor = DESCRIPTOR_POOL
        .get_message_by_name("ball.v1.Program")
        .expect("ball.v1.Program must be resolvable from the embedded descriptor pool");
    let dynamic =
        DynamicMessage::deserialize(program_descriptor, json_value).unwrap_or_else(|err| {
            panic!(
                "{} must deserialize as a ball.v1.Program: {err}",
                path.display()
            )
        });
    Program::decode(dynamic.encode_to_vec().as_slice())
        .expect("binary re-encoded from the DynamicMessage must decode as a typed ball.v1.Program")
}

fn load_example(name: &str) -> Program {
    let path = repo_root()
        .join("examples")
        .join(name)
        .join(format!("{name}.ball.json"));
    load_program_file(&path)
}

/// Load a `tests/conformance/<name>.ball.json` fixture plus its sibling
/// `<name>.expected_output.txt` (issue #38's `simple_class`/`abstract_class`/
/// `enum_values` acceptance fixtures — see `docs/TESTING_STRATEGY.md` for
/// why conformance fixtures are preferred over hand-built `Program`s
/// whenever a real one already exists in the corpus).
fn load_conformance_fixture(name: &str) -> (Program, String) {
    let dir = repo_root().join("tests/conformance");
    let program = load_program_file(&dir.join(format!("{name}.ball.json")));
    let expected_path = dir.join(format!("{name}.expected_output.txt"));
    let expected = fs::read_to_string(&expected_path)
        .unwrap_or_else(|err| panic!("failed to read {}: {err}", expected_path.display()));
    // Normalize CRLF -> LF: on a Windows checkout, git may check these fixture
    // files out with CRLF line endings, but `println!` (and every reference
    // engine) always emits bare `\n` — this is a checkout-line-ending detail,
    // not a real cross-platform behavior difference to assert on.
    (
        program,
        expected.replace("\r\n", "\n").trim_end().to_string(),
    )
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

// ════════════════════════════════════════════════════════════
// #37 — base-function dispatch + lazy control flow
// ════════════════════════════════════════════════════════════

/// **The key laziness fixture.** `std.if`/`std.and`/`std.or` must compile so
/// the untaken/short-circuited branch is never *reached* at run time, not
/// merely "its value discarded". Proven two ways per operator:
/// - A `tap_print` branch that would print a tell-tale tag if it ran —
///   asserted absent from stdout via the exact-match comparison below (if
///   it *were* eagerly evaluated, its tag would appear in the output and
///   the `assert_eq!` inside `assert_program_prints` would fail with a
///   legible diff).
/// - An `and(false, divide(1, 0))` — a naive eager implementation would
///   panic (integer division by zero) and crash the whole compiled binary,
///   which `compile_and_run` treats as a hard test failure (non-zero exit
///   status) with the generated source attached to the panic message.
#[test]
fn laziness_and_or_if_never_evaluate_the_untaken_branch() {
    let main_body = block(
        vec![
            expr_stmt(print_msg(un_call(
                "to_string",
                bin_call(
                    "and",
                    bool_lit(false),
                    tap_print("AND_RHS_EVALUATED", bool_lit(true)),
                ),
            ))),
            expr_stmt(print_msg(un_call(
                "to_string",
                bin_call(
                    "or",
                    bool_lit(true),
                    tap_print("OR_RHS_EVALUATED", bool_lit(false)),
                ),
            ))),
            expr_stmt(print_msg(un_call(
                "to_string",
                if_expr(
                    bool_lit(false),
                    tap_print("IF_THEN_EVALUATED", int_lit(1)),
                    tap_print("IF_ELSE_EVALUATED", int_lit(2)),
                ),
            ))),
        ],
        // Statement, not tail: proves the untaken branch of `and` isn't
        // evaluated even when it would otherwise panic (divide by zero),
        // not just when it would merely print.
        print_msg(un_call(
            "to_string",
            bin_call(
                "and",
                bool_lit(false),
                bin_call("divide", int_lit(1), int_lit(0)),
            ),
        )),
    );
    let program = program_with_main(vec![user_fn("main", "", "void", main_body, None)]);
    assert_program_prints(
        "laziness",
        &program,
        "false\ntrue\nIF_ELSE_EVALUATED\n2\nfalse",
    );
}

/// Nested `for` loops + `if` conditionals + `continue`/`break`/`return`,
/// hand-traced to the same result any conformant Ball engine (Dart's
/// reference included) must produce for this exact expression tree —
/// there's nothing Rust-specific in the arithmetic/control-flow, so an
/// independently-computed expected value **is** "matches the reference
/// engine".
///
/// `compute_nested_sum`: for i in 1..4, for j in 1..4: skip when i==j
/// (`continue`), stop the *inner* loop early when i==3 && j==1 (`break` —
/// must not also stop the outer loop), else accumulate `sum += i*j`.
/// i=1: j=2,3 → +2,+3 (j=1 skipped) = 5
/// i=2: j=1,3 → +2,+6 (j=2 skipped) = 13
/// i=3: j=1 → break immediately (sum unchanged) = 13
///
/// `first_multiple_of_seven(20)`: `for` loop with an early `return` from
/// inside the loop body — the first i in 1..=20 with `i % 7 == 0` is 7.
#[test]
fn nested_loops_conditionals_break_continue_return() {
    let inner_body = if_expr(
        bin_call("equals", reference("i"), reference("j")),
        continue_expr(),
        if_expr(
            bin_call(
                "and",
                bin_call("equals", reference("i"), int_lit(3)),
                bin_call("equals", reference("j"), int_lit(1)),
            ),
            break_expr(),
            assign_expr(
                reference("sum"),
                bin_call("multiply", reference("i"), reference("j")),
                "+=",
            ),
        ),
    );
    let outer_body = for_loop(
        for_init_lets(vec![("j", int_lit(1))]),
        bin_call("less_than", reference("j"), int_lit(4)),
        assign_expr(reference("j"), int_lit(1), "+="),
        inner_body,
    );
    let compute_nested_sum_body = block(
        vec![
            let_stmt("sum", int_lit(0)),
            expr_stmt(for_loop(
                for_init_lets(vec![("i", int_lit(1))]),
                bin_call("less_than", reference("i"), int_lit(4)),
                assign_expr(reference("i"), int_lit(1), "+="),
                outer_body,
            )),
        ],
        reference("sum"),
    );

    let first_multiple_body = block(
        vec![expr_stmt(for_loop(
            for_init_lets(vec![("i", int_lit(1))]),
            bin_call("lte", reference("i"), reference("limit")),
            assign_expr(reference("i"), int_lit(1), "+="),
            if_expr(
                bin_call(
                    "equals",
                    bin_call("modulo", reference("i"), int_lit(7)),
                    int_lit(0),
                ),
                return_expr(reference("i")),
                int_lit(0),
            ),
        ))],
        int_lit(-1),
    );

    let main_body = block(
        vec![
            let_stmt("nested_sum", call("", "compute_nested_sum", None)),
            let_stmt(
                "first_mult",
                call("", "first_multiple_of_seven", Some(int_lit(20))),
            ),
            expr_stmt(print_to_string(reference("nested_sum"))),
        ],
        print_to_string(reference("first_mult")),
    );

    let program = program_with_main(vec![
        user_fn(
            "compute_nested_sum",
            "",
            "int",
            compute_nested_sum_body,
            None,
        ),
        user_fn(
            "first_multiple_of_seven",
            "int",
            "int",
            first_multiple_body,
            Some("limit"),
        ),
        user_fn("main", "", "void", main_body, None),
    ]);
    assert_program_prints("nested_control_flow", &program, "13\n7");
}

/// Arithmetic / comparison / logic / bitwise operators, including the two
/// semantics that DON'T match a naive "just use Rust's operator" port:
/// Euclidean `modulo` (`-7 % 3 == 2`, not Rust's native `-1`) and a logical
/// (zero-filling) `unsigned_right_shift`.
#[test]
fn arithmetic_comparison_logic_bitwise_operators_match_reference_semantics() {
    let checks: Vec<Expression> = vec![
        bin_call("add", int_lit(2), int_lit(3)),            // 5
        bin_call("subtract", int_lit(10), int_lit(4)),      // 6
        bin_call("multiply", int_lit(6), int_lit(7)),       // 42
        bin_call("divide", int_lit(17), int_lit(5)),        // 3 (truncating)
        bin_call("divide_double", int_lit(17), int_lit(5)), // 3.4
        bin_call("modulo", int_lit(-7), int_lit(3)),        // 2 (Euclidean)
        un_call("negate", int_lit(9)),                      // -9
        bin_call("equals", int_lit(5), int_lit(5)),         // true
        bin_call("not_equals", int_lit(5), int_lit(6)),     // true
        bin_call("less_than", int_lit(3), int_lit(5)),      // true
        bin_call("greater_than", int_lit(5), int_lit(3)),   // true
        bin_call("lte", int_lit(5), int_lit(5)),            // true
        bin_call("gte", int_lit(5), int_lit(5)),            // true
        bin_call("and", bool_lit(true), bool_lit(false)),   // false
        bin_call("or", bool_lit(false), bool_lit(true)),    // true
        un_call("not", bool_lit(true)),                     // false
        bin_call("bitwise_and", int_lit(12), int_lit(10)),  // 8
        bin_call("bitwise_or", int_lit(12), int_lit(10)),   // 14
        bin_call("bitwise_xor", int_lit(12), int_lit(10)),  // 6
        un_call("bitwise_not", int_lit(0)),                 // -1
        bin_call("left_shift", int_lit(1), int_lit(4)),     // 16
        bin_call("right_shift", int_lit(-16), int_lit(2)),  // -4 (arithmetic)
        bin_call("unsigned_right_shift", int_lit(-1), int_lit(60)), // 15 (logical)
    ];
    let expected = [
        "5", "6", "42", "3", "3.4", "2", "-9", "true", "true", "true", "true", "true", "true",
        "false", "true", "false", "8", "14", "6", "-1", "16", "-4", "15",
    ]
    .join("\n");

    let mut statements: Vec<Statement> = checks
        .into_iter()
        .map(|check| expr_stmt(print_msg(un_call("to_string", check))))
        .collect();
    let tail = match statements.pop().expect("checks is non-empty") {
        Statement {
            stmt: Some(ball_shared::proto::ball::v1::statement::Stmt::Expression(last)),
        } => last,
        _ => unreachable!("every statement built above is Stmt::Expression"),
    };
    let main_body = block(statements, tail);
    let program = program_with_main(vec![user_fn("main", "", "void", main_body, None)]);
    assert_program_prints("operators", &program, &expected);
}

/// `while` — condition compiled inline and re-evaluated every iteration.
#[test]
fn while_loop_sums_one_through_five() {
    let main_body = block(
        vec![
            let_stmt("sum", int_lit(0)),
            let_stmt("i", int_lit(1)),
            expr_stmt(while_loop(
                bin_call("lte", reference("i"), int_lit(5)),
                block(
                    vec![expr_stmt(assign_expr(
                        reference("sum"),
                        reference("i"),
                        "+=",
                    ))],
                    assign_expr(reference("i"), int_lit(1), "+="),
                ),
            )),
        ],
        print_to_string(reference("sum")),
    );
    let program = program_with_main(vec![user_fn("main", "", "void", main_body, None)]);
    assert_program_prints("while_loop", &program, "15");
}

/// `do_while` — body runs once even though the condition is false from the
/// very first check.
#[test]
fn do_while_runs_body_at_least_once() {
    let main_body = block(
        vec![let_stmt("count", int_lit(0))],
        block(
            vec![expr_stmt(do_while_loop(
                assign_expr(reference("count"), int_lit(1), "+="),
                bool_lit(false),
            ))],
            reference("count"),
        ),
    );
    let main_body = print_to_string(main_body);
    let program = program_with_main(vec![user_fn("main", "", "void", main_body, None)]);
    assert_program_prints("do_while", &program, "1");
}

/// `for_in` — iterates a `List` literal, summing its elements.
#[test]
fn for_in_sums_a_list() {
    let main_body = block(
        vec![
            let_stmt("sum", int_lit(0)),
            expr_stmt(for_in_loop(
                "x",
                list_lit(vec![int_lit(10), int_lit(20), int_lit(30)]),
                assign_expr(reference("sum"), reference("x"), "+="),
            )),
        ],
        print_to_string(reference("sum")),
    );
    let program = program_with_main(vec![user_fn("main", "", "void", main_body, None)]);
    assert_program_prints("for_in", &program, "60");
}

/// `switch` — dispatches to the matching case's body (compiled as an
/// if-chain internally — see `base_call.rs::compile_switch`).
#[test]
fn switch_dispatches_to_the_matching_case() {
    let main_body = print_to_string(switch_expr(
        int_lit(2),
        vec![
            switch_case(int_lit(1), string_lit("one")),
            switch_case(int_lit(2), string_lit("two")),
            switch_default(string_lit("other")),
        ],
    ));
    let program = program_with_main(vec![user_fn("main", "", "void", main_body, None)]);
    assert_program_prints("switch", &program, "two");
}

/// `try`/`throw` — `throw` panics with the `BallValue` payload
/// (`std::panic::panic_any`); `try` catches it via `catch_unwind` and binds
/// the recovered value to the `catch` clause's variable.
#[test]
fn try_catch_recovers_a_thrown_value() {
    let main_body = print_to_string(try_expr(
        block(vec![expr_stmt(throw_expr(string_lit("boom")))], int_lit(0)),
        vec![catch_clause("e", reference("e"))],
    ));
    let program = program_with_main(vec![user_fn("main", "", "void", main_body, None)]);
    assert_program_prints("try_catch", &program, "boom");
}

/// Mutating `std_collections` calls (`list_push`/`list_set`/`list_pop`) —
/// and `assign` on a plain `let` variable — must mutate the *actual* bound
/// list, not a throwaway `.clone()`; see `crate::lvalue`'s module doc
/// comment for why that isn't automatic in Rust the way it is in Dart.
#[test]
fn list_mutations_affect_the_same_underlying_list() {
    let main_body = block(
        vec![
            let_stmt("items", list_lit(vec![int_lit(1), int_lit(2), int_lit(3)])),
            expr_stmt(list_push_call(reference("items"), int_lit(4))),
            expr_stmt(list_set_call(reference("items"), int_lit(0), int_lit(99))),
            expr_stmt(print_to_string(reference("items"))),
            let_stmt("popped", list_pop_call(reference("items"))),
        ],
        print_to_string(reference("popped")),
    );
    let program = program_with_main(vec![user_fn("main", "", "void", main_body, None)]);
    assert_program_prints("list_mutation", &program, "[99, 2, 3, 4]\n4");
}

// ════════════════════════════════════════════════════════════
// #38 — type emission + multi-module output
// ════════════════════════════════════════════════════════════

/// `tests/conformance/101_simple_class.ball.json` — a plain class
/// (`Point`, constructed via `Point(this.x, this.y)`) with two methods
/// (`describe`, `distanceSquared`) and a mutated field (`p2.x = 5;`).
/// Exercises: struct + `impl` emission, the constructor's positional
/// `arg0`/`arg1` → real field-name (`x`/`y`) remapping, and a method body
/// reading `self`'s fields as bare local aliases.
#[test]
fn simple_class_conformance_fixture_compiles_and_runs() {
    let (program, expected) = load_conformance_fixture("101_simple_class");
    assert_program_prints("simple_class", &program, &expected);
}

/// `tests/conformance/103_abstract_class.ball.json` — an abstract class
/// (`Shape`, `is_abstract: true`, two abstract methods) with two concrete
/// subclasses (`Circle`, `Rectangle`) that both declare `area`/`name`.
/// Exercises: abstract-class → `trait` emission, and — the crux of this
/// fixture — **polymorphic dispatch**: a `List<Shape>` holding both
/// concrete types, iterated with `s.area()`/`s.name()` calls that must
/// route to the right concrete `impl` at run time
/// (`compile_method_dispatchers`), since neither call site can know which
/// concrete type `s` holds at Rust compile time.
#[test]
fn abstract_class_conformance_fixture_compiles_and_runs() {
    let (program, expected) = load_conformance_fixture("103_abstract_class");
    assert_program_prints("abstract_class", &program, &expected);
}

/// `tests/conformance/109_enum_values.ball.json` — a Dart enum (`Color`)
/// with four members, iterated via `Color.values`, read via `c.index`, and
/// matched in a Dart-3-pattern `switch` (`case Color.red:` encodes as
/// `pattern_expr: ConstPattern { value: <fieldAccess Color.red> }`, not the
/// simpler `value` field most other switch fixtures use). Exercises: enum →
/// `pub static ...: LazyLock<BallValue>` namespace emission, the
/// `ball_field_get` virtual `"length"` property on `Color.values` (a
/// `List`), and `compile_switch`'s `ConstPattern` fallback.
#[test]
fn enum_values_conformance_fixture_compiles_and_runs() {
    let (program, expected) = load_conformance_fixture("109_enum_values");
    assert_program_prints("enum_values", &program, &expected);
}

/// A hand-built multi-module program: a `mathutils` module (holding
/// `double_it`) alongside the entry `main` module, which calls
/// `mathutils.double_it(21)`. Proves `Compiler::compile` emits `mathutils`
/// as its own nested `pub mod mathutils { ... }` (not inlined into `main`'s
/// own scope) *and* that the cross-module call resolves to
/// `mathutils::double_it(...)` and actually links/runs correctly — the
/// "multiple mods that link" half of #38's acceptance criteria (the
/// same-module case is already covered by every other fixture in this
/// file, which never emits a nested `mod` at all).
#[test]
fn multi_module_program_compiles_into_nested_mods_and_resolves_cross_module_calls() {
    let math_module = Module {
        name: "mathutils".to_string(),
        functions: vec![user_fn(
            "double_it",
            "int",
            "int",
            bin_call("multiply", reference("input"), int_lit(2)),
            None,
        )],
        ..Default::default()
    };
    let main_body = print_to_string(call("mathutils", "double_it", Some(int_lit(21))));
    let program = Program {
        name: "test".to_string(),
        version: "1.0.0".to_string(),
        modules: vec![
            ball_shared::build_std_module(),
            math_module,
            Module {
                name: "main".to_string(),
                functions: vec![user_fn("main", "", "void", main_body, None)],
                module_imports: vec![
                    ModuleImport {
                        name: "std".to_string(),
                        ..Default::default()
                    },
                    ModuleImport {
                        name: "mathutils".to_string(),
                        ..Default::default()
                    },
                ],
                ..Default::default()
            },
        ],
        entry_module: "main".to_string(),
        entry_function: "main".to_string(),
        metadata: None,
    };

    let compiled = Compiler::new(&program).compile();
    assert!(
        compiled.contains("pub mod mathutils"),
        "expected a nested `pub mod mathutils` block:\n{compiled}"
    );
    assert!(
        compiled.contains("mathutils::double_it("),
        "expected the cross-module call site to be qualified with `mathutils::`:\n{compiled}"
    );

    let stdout = compile_and_run("multi_module", &compiled);
    assert_eq!(
        stdout.trim(),
        "42",
        "fixture 'multi_module' produced unexpected stdout.\n--- generated main.rs ---\n{compiled}"
    );
}

/// A same-module method call (`describe`/`distanceSquared` on a single
/// `Point` class, no polymorphism) must resolve as a plain, unqualified
/// dispatcher call — `Compiler::compile_module_body` sets `current_module`
/// to `"main"` while compiling the entry module, so
/// `type_emit::resolve_user_call_name` must emit no `mod` qualification at
/// all for it (there's no `pub mod main { ... }` — the entry module's own
/// items are inlined at the top level).
#[test]
fn simple_class_fixture_does_not_emit_a_nested_mod_for_the_entry_module() {
    let (program, _expected) = load_conformance_fixture("101_simple_class");
    let compiled = Compiler::new(&program).compile();
    assert!(
        !compiled.contains("pub mod main"),
        "the entry module's own items must be inlined, not nested in a `mod`:\n{compiled}"
    );
    assert!(
        compiled.contains("pub struct main_Point"),
        "expected a `main_Point` struct emitted from `main:Point`'s TypeDefinition:\n{compiled}"
    );
    assert!(
        compiled.contains("impl main_Point"),
        "expected an `impl main_Point` block holding its constructor/methods:\n{compiled}"
    );
}

// ════════════════════════════════════════════════════════════
// #287 / #288 — param_alias_prologue mutability + receiver-less
// associated functions
// ════════════════════════════════════════════════════════════

/// Issue #287 — a function that reassigns its own single named parameter
/// (`Compiler::param_alias_prologue`'s `let <name> = input.clone();` alias)
/// must compile the alias as `let mut <name>`, not a plain immutable `let`,
/// which rustc rejects ("cannot assign twice to immutable variable").
/// `count_to_ten` treats its own parameter `n` like an ordinary mutable loop
/// counter — exactly the counter/accumulator shape #43's own encoder
/// invariant-#2 test hit and had to route around (see
/// `param_alias_prologue`'s doc comment in `rust/compiler/src/lib.rs`).
#[test]
fn function_reassigning_its_own_parameter_compiles_and_runs() {
    let count_to_ten_body = block(
        vec![expr_stmt(while_loop(
            bin_call("less_than", reference("n"), int_lit(10)),
            assign_expr(reference("n"), int_lit(1), "+="),
        ))],
        reference("n"),
    );
    let main_body = block(
        vec![let_stmt(
            "result",
            call("", "count_to_ten", Some(int_lit(3))),
        )],
        print_to_string(reference("result")),
    );
    let program = program_with_main(vec![
        user_fn("count_to_ten", "int", "int", count_to_ten_body, Some("n")),
        user_fn("main", "", "void", main_body, None),
    ]);

    let compiled = Compiler::new(&program).compile();
    assert!(
        compiled.contains("let mut n = input.clone();"),
        "a parameter reassigned in its own function body must alias as \
         `let mut`, not a plain immutable `let` (issue #287):\n{compiled}"
    );

    let stdout = compile_and_run("param_reassignment", &compiled);
    assert_eq!(
        stdout.trim(),
        "10",
        "fixture 'param_reassignment' produced unexpected stdout.\n--- generated main.rs ---\n{compiled}"
    );
}

/// A single-valued `int64` field for the hand-built `Point` `TypeDefinition`
/// below (mirrors `tests/conformance/101_simple_class.ball.json`'s own
/// `main:Point` descriptor).
fn int_field_descriptor(name: &str, number: i32) -> FieldDescriptorProto {
    FieldDescriptorProto {
        name: Some(name.to_string()),
        number: Some(number),
        r#type: Some(Type::Int64 as i32),
        label: Some(Label::Optional as i32),
        ..Default::default()
    }
}

/// `metadata.params = [{name: p0}, {name: p1}, ...]` — like
/// `single_param_metadata`, but for a multi-parameter class member (issue
/// #288's fixture needs two non-`self` parameters: `x`, `y`).
fn params_meta_value(names: &[&str]) -> Value {
    Value {
        kind: Some(Kind::ListValue(ListValue {
            values: names
                .iter()
                .map(|name| {
                    let mut fields = HashMap::new();
                    fields.insert(
                        "name".to_string(),
                        Value {
                            kind: Some(Kind::StringValue(name.to_string())),
                        },
                    );
                    Value {
                        kind: Some(Kind::StructValue(Struct { fields })),
                    }
                })
                .collect(),
        })),
    }
}

/// `metadata.kind = "method"`, `metadata.is_static = true` (when
/// `is_static`), `metadata.params = [...]` — the shape Dart's reference
/// encoder emits for any static class member
/// (`dart/encoder/lib/encoder.dart`'s `_encodeMethodDeclaration`: `meta['kind']
/// = 'method'; if (member.isStatic) meta['is_static'] = true;`), which is
/// what marks a class member as having no `self` receiver at the Ball IR
/// level (`ball-compiler`'s own Rust encoder doesn't emit this shape yet —
/// see `rust/encoder/src/types.rs`'s module doc comment — so this is
/// hand-built exactly like `factorial`/`closures` above).
fn static_method_meta(params: &[&str]) -> Struct {
    let mut fields = HashMap::new();
    fields.insert(
        "kind".to_string(),
        Value {
            kind: Some(Kind::StringValue("method".to_string())),
        },
    );
    fields.insert(
        "is_static".to_string(),
        Value {
            kind: Some(Kind::BoolValue(true)),
        },
    );
    if !params.is_empty() {
        fields.insert("params".to_string(), params_meta_value(params));
    }
    Struct { fields }
}

/// Issue #288 — `Point::new(x, y)`-style receiver-less associated function:
/// Rust's own idiom for a "constructor" is an ordinary associated `fn` with
/// no `self` receiver at all, unlike Dart's `Point(this.x, this.y)`
/// init-formal-parameter shape (which is `metadata.kind: "constructor"` and
/// already routes through `Compiler::compile_constructor`, never touching
/// `method_prologue`). `main:Point.new` here is a `kind: "method"`,
/// `is_static: true` class member instead — the shape that actually
/// triggered the #288 panic — with a real body that builds and returns a
/// `main:Point` message directly from its own two parameters.
///
/// Exercises both halves of the fix:
/// - `Compiler::method_prologue` must skip extracting a `"self"` field that
///   a receiver-less call never packs into `input`.
/// - `Compiler::compile_method_dispatchers` must route a single-owner
///   static short name straight into its `impl` block instead of matching
///   on a receiver's (nonexistent) runtime type.
#[test]
fn receiver_less_associated_function_compiles_and_runs() {
    let point_type = TypeDefinition {
        name: "main:Point".to_string(),
        descriptor: Some(DescriptorProto {
            name: Some("main:Point".to_string()),
            field: vec![int_field_descriptor("x", 1), int_field_descriptor("y", 2)],
            ..Default::default()
        }),
        type_params: vec![],
        description: "Class metadata for main:Point".to_string(),
        metadata: None,
    };

    // `Point::new(x, y)`: builds and returns a `main:Point` message directly
    // from its own two parameters — no `self` receiver at all.
    let point_new = FunctionDefinition {
        name: "main:Point.new".to_string(),
        input_type: String::new(),
        output_type: "main:Point".to_string(),
        body: Some(Box::new(message(
            "main:Point",
            vec![("x", reference("x")), ("y", reference("y"))],
        ))),
        description: String::new(),
        is_base: false,
        metadata: Some(static_method_meta(&["x", "y"])),
    };

    let main_body = block(
        vec![let_stmt(
            "p",
            call(
                "",
                "new",
                Some(args(vec![("x", int_lit(3)), ("y", int_lit(4))])),
            ),
        )],
        print_to_string(bin_call(
            "add",
            field_access(reference("p"), "x"),
            field_access(reference("p"), "y"),
        )),
    );

    let program = Program {
        name: "test".to_string(),
        version: "1.0.0".to_string(),
        modules: vec![
            ball_shared::build_std_module(),
            Module {
                name: "main".to_string(),
                functions: vec![point_new, user_fn("main", "", "void", main_body, None)],
                type_defs: vec![point_type],
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
    };

    let compiled = Compiler::new(&program).compile();
    assert!(
        !compiled.contains("let self_ = ball_field_get"),
        "a receiver-less associated function must not extract a `self` \
         field it was never packed (issue #288):\n{compiled}"
    );
    assert!(
        !compiled.contains("ball_message_type_name(&__self)"),
        "a single-owner static short name must not compile a self-typed \
         dispatch match arm (issue #288):\n{compiled}"
    );

    let stdout = compile_and_run("receiver_less_assoc_fn", &compiled);
    assert_eq!(
        stdout.trim(),
        "7",
        "fixture 'receiver_less_assoc_fn' produced unexpected stdout.\n--- generated main.rs ---\n{compiled}"
    );
}
