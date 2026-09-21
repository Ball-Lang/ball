//! Stage 3 of the Tier A / round-trip pipeline for the Ball Rust runtime's
//! **is/as registry** and its **collection-literal constructors** (issue #692).
//!
//! `compile_reencode_roundtrip.rs` states the contract: every construct
//! `ball-lang-compiler` EMITS must be a construct `ball-lang-encoder` can read
//! back. #646 taught the encoder the `(|| -> BallValue { … })()` IIFE, the
//! `BallValue::…` scalar constructors and the `ball_*` runtime-helper table;
//! #739 taught it `BallList::new()`/`BallMap::new()`/`BallList::from` and the
//! `__ball_register_types` class prologue. This file covers what #692 still
//! names, measured as the remaining first-blockers of the `rust-roundtrip` row
//! in `.github/workflows/conformance-matrix.yml`
//! (run 35550645549, job `Rust Round-Trip Leg (measurement)`):
//!
//! | first blocker         | fixtures | what it is |
//! |-----------------------|----------|------------|
//! | `ball_map_create`     | 21       | the MAP-literal constructor |
//! | `ball_is_type`        | 18       | the registry's query side, from a compiled PATTERN |
//! | `ball_set_create`     | 7        | the SET-literal constructor |
//! | `ball_is`             | 3        | the registry's query side, from `std.is` |
//!
//! #739's own module doc said a behavioural `is`/`as` proof was "deliberately
//! NOT attempted … `ball_is` has no entry in `runtime_helpers.rs`, so such a
//! program stops one construct earlier". This slice is that entry, so the
//! sentence is retired here and in that file.
//!
//! ## Why these assertions are shaped this way
//!
//! Each test drives the REAL pipeline — compile a Ball program, encode the
//! compiled Rust — and FIRST asserts the compiler still emits the construct
//! under test. A stage-3 assertion alone can go green because the compiler
//! stopped emitting the shape, which would retire the gate instead of keeping
//! it.
//!
//! Stage 1 is a hand-built `Program` rather than encoded Rust, because Rust has
//! no `is`/`as` operator and no set literal: `ball_lang_encoder::encode` can
//! never produce a `std.is` or a `std.set_create` from Rust source, so
//! round-tripping from Rust could not reach these constructs at all. This is
//! the same honest construction `compiler_output.rs` uses for its hello-world.
//! The BEHAVIOURAL half — the re-encoded program still computing the same
//! answer — is the `rust-roundtrip` row itself, which runs each re-encoded
//! program on the Dart reference engine and byte-diffs the golden.

use ball_lang_compiler::Compiler;
use ball_lang_shared::proto::ball::v1::expression::Expr;
use ball_lang_shared::proto::ball::v1::literal::Value as LiteralValue;
use ball_lang_shared::proto::ball::v1::statement::Stmt;
use ball_lang_shared::proto::ball::v1::{
    Expression, FieldValuePair, FunctionCall, FunctionDefinition, ListLiteral, Literal,
    MessageCreation, Module, Program,
};

// ════════════════════════════════════════════════════════════
// Ball node builders
// ════════════════════════════════════════════════════════════

fn string_literal(value: &str) -> Expression {
    Expression {
        expr: Some(Expr::Literal(Literal {
            value: Some(LiteralValue::StringValue(value.to_string())),
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

fn list_literal(elements: Vec<Expression>) -> Expression {
    Expression {
        expr: Some(Expr::Literal(Literal {
            value: Some(LiteralValue::ListValue(ListLiteral { elements })),
        })),
    }
}

/// An anonymous `message_creation` — the "named arguments for a base call"
/// shape, and also the shape a switch case and a pattern carry.
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
            ..Default::default()
        })),
    }
}

fn std_call(function: &str, fields: Vec<(&str, Expression)>) -> Expression {
    Expression {
        expr: Some(Expr::Call(Box::new(FunctionCall {
            module: "std".to_string(),
            function: function.to_string(),
            input: Some(Box::new(message("", fields))),
            ..Default::default()
        }))),
    }
}

/// A whole `Program` whose `main` prints `body`. `base_functions` are the `std`
/// base functions it uses — a Ball program must declare every one it calls.
fn program_printing(body: Expression, base_functions: &[&str]) -> Program {
    let print_call = std_call("print", vec![("message", body)]);
    let mut std_functions: Vec<FunctionDefinition> = base_functions
        .iter()
        .map(|name| FunctionDefinition {
            name: (*name).to_string(),
            is_base: true,
            ..Default::default()
        })
        .collect();
    std_functions.push(FunctionDefinition {
        name: "print".to_string(),
        is_base: true,
        ..Default::default()
    });

    Program {
        name: "encoded".to_string(),
        version: "1.0.0".to_string(),
        entry_module: "main".to_string(),
        entry_function: "main".to_string(),
        modules: vec![
            Module {
                name: "std".to_string(),
                functions: std_functions,
                ..Default::default()
            },
            Module {
                name: "main".to_string(),
                functions: vec![FunctionDefinition {
                    name: "main".to_string(),
                    output_type: "void".to_string(),
                    body: Some(Box::new(print_call)),
                    ..Default::default()
                }],
                ..Default::default()
            },
        ],
        ..Default::default()
    }
}

// ════════════════════════════════════════════════════════════
// Reading the re-encoded Program back
// ════════════════════════════════════════════════════════════

fn all_expressions(program: &Program) -> Vec<Expression> {
    let mut out = Vec::new();
    for module in &program.modules {
        if module.functions.iter().all(|f| f.is_base) {
            continue;
        }
        for function in &module.functions {
            if let Some(body) = &function.body {
                walk(body, &mut out);
            }
        }
    }
    out
}

fn walk(expr: &Expression, out: &mut Vec<Expression>) {
    out.push(expr.clone());
    let Some(kind) = &expr.expr else { return };
    match kind {
        Expr::Call(call) => {
            if let Some(input) = &call.input {
                walk(input, out);
            }
        }
        Expr::MessageCreation(creation) => {
            for field in &creation.fields {
                if let Some(value) = &field.value {
                    walk(value, out);
                }
            }
        }
        Expr::FieldAccess(access) => {
            if let Some(object) = &access.object {
                walk(object, out);
            }
        }
        Expr::Block(block) => {
            for statement in &block.statements {
                match &statement.stmt {
                    Some(Stmt::Expression(inner)) => walk(inner, out),
                    Some(Stmt::Let(binding)) => {
                        if let Some(value) = &binding.value {
                            walk(value, out);
                        }
                    }
                    None => {}
                }
            }
            if let Some(result) = &block.result {
                walk(result, out);
            }
        }
        Expr::Lambda(lambda) => {
            if let Some(body) = &lambda.body {
                walk(body, out);
            }
        }
        Expr::Literal(literal) => {
            if let Some(LiteralValue::ListValue(list)) = &literal.value {
                for element in &list.elements {
                    walk(element, out);
                }
            }
        }
        Expr::Reference(_) => {}
    }
}

/// Every `std.<function>` call in `program`, as
/// `(function, [(field name, field summary)])`. A field summary is its string
/// or int literal spelled out, `[…]` for a list literal, `{a: …}` for a
/// message-creation, `std.f({…})` for a nested `std` call, and `<expr>` for
/// anything else — enough to assert the exact node without asserting on
/// unrelated detail.
fn std_calls(program: &Program) -> Vec<(String, Vec<(String, String)>)> {
    all_expressions(program)
        .iter()
        .filter_map(|expr| match &expr.expr {
            Some(Expr::Call(call)) if call.module == "std" => Some((
                call.function.clone(),
                call.input
                    .as_ref()
                    .map(|input| match &input.expr {
                        Some(Expr::MessageCreation(creation)) => creation
                            .fields
                            .iter()
                            .map(|field| {
                                (
                                    field.name.clone(),
                                    field.value.as_ref().map_or_else(
                                        || "<absent>".to_string(),
                                        summarize_expression,
                                    ),
                                )
                            })
                            .collect(),
                        _ => Vec::new(),
                    })
                    .unwrap_or_default(),
            )),
            _ => None,
        })
        .collect()
}

fn summarize_expression(expr: &Expression) -> String {
    match &expr.expr {
        Some(Expr::Literal(literal)) => match &literal.value {
            Some(LiteralValue::StringValue(text)) => format!("{text:?}"),
            Some(LiteralValue::IntValue(value)) => value.to_string(),
            Some(LiteralValue::ListValue(list)) => format!(
                "[{}]",
                list.elements
                    .iter()
                    .map(summarize_expression)
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
            _ => "<literal>".to_string(),
        },
        Some(Expr::MessageCreation(creation)) => format!(
            "{{{}}}",
            creation
                .fields
                .iter()
                .map(|field| format!(
                    "{}: {}",
                    field.name,
                    field
                        .value
                        .as_ref()
                        .map_or_else(|| "<absent>".to_string(), summarize_expression)
                ))
                .collect::<Vec<_>>()
                .join(", ")
        ),
        Some(Expr::Call(call)) => format!(
            "{}.{}({})",
            call.module,
            call.function,
            call.input.as_ref().map_or_else(
                || "<absent>".to_string(),
                |input| summarize_expression(input)
            )
        ),
        _ => "<expr>".to_string(),
    }
}

/// The first `std.<function>` call in `program`, with its input fields.
fn first_std_call(program: &Program, function: &str) -> Vec<(String, String)> {
    let calls = std_calls(program);
    match calls.iter().find(|(name, _)| name.as_str() == function) {
        Some((_, fields)) => fields.clone(),
        None => panic!("the re-encoded program has no `std.{function}` call: {calls:?}"),
    }
}

/// Compile `program`, assert the compiled Rust still contains `emitted` — the
/// construct under test — and return the compiled source.
fn compile_emitting(program: &Program, emitted: &str) -> String {
    let compiled = Compiler::new(program).compile();
    assert!(
        compiled.contains(emitted),
        "the compiler must still emit `{emitted}` — otherwise this test is not exercising \
         the construct it claims to:\n{compiled}"
    );
    compiled
}

// ════════════════════════════════════════════════════════════
// 1. The is/as registry's query side
// ════════════════════════════════════════════════════════════

/// `std.is` compiles to `ball_is(value, "T")`
/// (`rust/compiler/src/base_call.rs::compile_type_op`), which must read back as
/// the very `std.is` node it compiled from — `{value, type: "int"}`, the shape
/// `dart/encoder`'s `IsExpression` arm emits.
#[test]
fn a_compiled_is_test_re_encodes_as_std_is() {
    let program = program_printing(
        std_call(
            "is",
            vec![("value", int_literal(7)), ("type", string_literal("int"))],
        ),
        &["is"],
    );
    let compiled = compile_emitting(&program, "ball_is(");

    let stage3 = ball_lang_encoder::encode(&compiled);
    assert_eq!(
        first_std_call(&stage3, "is"),
        vec![
            ("value".to_string(), "7".to_string()),
            ("type".to_string(), "\"int\"".to_string()),
        ],
    );
}

/// The negated form — a separate `std` base function, not `std.not` over
/// `std.is`, so it must come back as `is_not` rather than be normalized away.
#[test]
fn a_compiled_is_not_test_re_encodes_as_std_is_not() {
    let program = program_printing(
        std_call(
            "is_not",
            vec![
                ("value", int_literal(7)),
                ("type", string_literal("String")),
            ],
        ),
        &["is_not"],
    );
    let compiled = compile_emitting(&program, "ball_is_not(");

    let stage3 = ball_lang_encoder::encode(&compiled);
    assert_eq!(
        first_std_call(&stage3, "is_not"),
        vec![
            ("value".to_string(), "7".to_string()),
            ("type".to_string(), "\"String\"".to_string()),
        ],
    );
}

/// `std.as` — a strict cast, and the third member of the same
/// `compile_type_op` family.
#[test]
fn a_compiled_as_cast_re_encodes_as_std_as() {
    let program = program_printing(
        std_call(
            "as",
            vec![("value", int_literal(7)), ("type", string_literal("num"))],
        ),
        &["as"],
    );
    let compiled = compile_emitting(&program, "ball_as(");

    let stage3 = ball_lang_encoder::encode(&compiled);
    assert_eq!(
        first_std_call(&stage3, "as"),
        vec![
            ("value".to_string(), "7".to_string()),
            ("type".to_string(), "\"num\"".to_string()),
        ],
    );
}

/// A typed binder in a `switch` case compiles to the registry's OTHER query
/// helper: `rust/compiler/src/pattern.rs::type_check` emits the bare-`bool`
/// `ball_is_type(&subject, "T")`, which is the same discrimination `ball_is`
/// performs and therefore inverts to the same `std.is`. It is the single
/// largest remaining bucket the row's log names (18 fixtures).
#[test]
fn a_compiled_type_pattern_re_encodes_as_std_is() {
    let switch = std_call(
        "switch",
        vec![
            ("subject", int_literal(7)),
            (
                "cases",
                list_literal(vec![message(
                    "",
                    vec![
                        (
                            "pattern_expr",
                            message(
                                "VarPattern",
                                vec![
                                    ("name", string_literal("n")),
                                    ("type", string_literal("int")),
                                ],
                            ),
                        ),
                        ("body", string_literal("an int")),
                    ],
                )]),
            ),
        ],
    );
    let program = program_printing(switch, &["switch"]);
    let compiled = compile_emitting(&program, "ball_is_type(&");

    let stage3 = ball_lang_encoder::encode(&compiled);
    let is_call = first_std_call(&stage3, "is");
    assert_eq!(
        is_call
            .iter()
            .find(|(name, _)| name == "type")
            .map(|(_, summary)| summary.as_str()),
        Some("\"int\""),
        "the pattern's type test must come back as `std.is` against the same type name: \
         {is_call:?}"
    );
}

/// A COMPUTED type name has no Ball node — `std.is`'s `type` field is specified
/// as a string literal (`dart/encoder` writes `type.toSource()` into one), so
/// the encoder must refuse rather than invent a node whose `type` is an
/// expression no compiler reads.
#[test]
#[should_panic(expected = "a computed type name has no Ball")]
fn a_computed_type_name_fails_loud() {
    ball_lang_encoder::encode(
        r#"
fn main() {
    let t = "int";
    println!("{}", ball_is(BallValue::Int(1i64), t));
}
"#,
    );
}

// ════════════════════════════════════════════════════════════
// 2. The collection-literal constructors
// ════════════════════════════════════════════════════════════

/// `std.map_create` compiles to
/// `ball_map_create(BallValue::List(BallList::from(vec![[k, v], …])))`
/// (`base_call.rs::compile_map_create`) and must read back as the same
/// `map_create` node: one repeated `entry` field per pair, each an anonymous
/// `{key, value}` message-creation.
///
/// The `std.to_string({value: "a"})` around each string KEY is expected, and is
/// asserted rather than normalized away. `compile_expression` emits a Ball
/// string literal as `BallValue::String("a".to_string())`, and `.to_string()`
/// is NOT one of `methods.rs`'s identity passthroughs — in hand-written Rust,
/// which is this encoder's actual input, it genuinely IS `std.to_string`. Over
/// a `String` that op returns its operand unchanged, so the re-encoded program
/// computes the same map; the extra node is a node-fidelity difference, not a
/// behavioural one. It applies to EVERY compiled string literal, predates this
/// slice, and is out of #692's scope — see `rust/AGENTS.md`.
#[test]
fn a_compiled_map_literal_re_encodes_as_std_map_create() {
    let program = program_printing(
        std_call(
            "map_create",
            vec![
                (
                    "entry",
                    message(
                        "",
                        vec![("key", string_literal("a")), ("value", int_literal(1))],
                    ),
                ),
                (
                    "entry",
                    message(
                        "",
                        vec![("key", string_literal("b")), ("value", int_literal(2))],
                    ),
                ),
            ],
        ),
        &["map_create"],
    );
    let compiled = compile_emitting(&program, "ball_map_create(");

    let stage3 = ball_lang_encoder::encode(&compiled);
    assert_eq!(
        first_std_call(&stage3, "map_create"),
        vec![
            (
                "entry".to_string(),
                "{key: std.to_string({value: \"a\"}), value: 1}".to_string(),
            ),
            (
                "entry".to_string(),
                "{key: std.to_string({value: \"b\"}), value: 2}".to_string(),
            ),
        ],
    );
}

/// The empty map literal — `ball_map_create` over an EMPTY pair list, which
/// must not be confused with the comprehension lowering and must not silently
/// become a `BallMap::new()`-shaped node with an `element` field.
#[test]
fn an_empty_compiled_map_literal_re_encodes_as_an_entryless_map_create() {
    let program = program_printing(std_call("map_create", vec![]), &["map_create"]);
    let compiled = compile_emitting(&program, "ball_map_create(");

    let stage3 = ball_lang_encoder::encode(&compiled);
    assert_eq!(first_std_call(&stage3, "map_create"), Vec::new());
}

/// `std.set_create` compiles to `ball_set_create(<elements>)`, whose Ball input
/// names that list `elements` — NOT the table's `value`. A set is a distinct
/// Ball value from a list (`{'__ball_set__': […]}` on every target), so the
/// node must come back as `set_create`, never as the bare list inside it.
#[test]
fn a_compiled_set_literal_re_encodes_as_std_set_create() {
    let program = program_printing(
        std_call(
            "set_create",
            vec![(
                "elements",
                list_literal(vec![int_literal(1), int_literal(2)]),
            )],
        ),
        &["set_create"],
    );
    let compiled = compile_emitting(&program, "ball_set_create(");

    let stage3 = ball_lang_encoder::encode(&compiled);
    assert_eq!(
        first_std_call(&stage3, "set_create"),
        vec![("elements".to_string(), "[1, 2]".to_string())],
    );
}

/// The map COMPREHENSION lowering splices its entries into a local `Vec` and
/// hands `ball_map_create` that variable. Its Ball node is a `map_create` with
/// `element` fields — a different, larger inverse — so the encoder must fail
/// loud rather than emit an entry-less `map_create` that silently computes `{}`.
#[test]
#[should_panic(expected = "only encodable over a LITERAL")]
fn a_map_create_over_a_spliced_list_fails_loud() {
    ball_lang_encoder::encode(
        r#"
fn main() {
    let entries = vec![];
    println!("{}", ball_map_create(BallValue::List(BallList::from(entries))));
}
"#,
    );
}

/// The set half of the same refusal.
#[test]
#[should_panic(expected = "only encodable over a LITERAL")]
fn a_set_create_over_a_spliced_list_fails_loud() {
    ball_lang_encoder::encode(
        r#"
fn main() {
    let elements = vec![];
    println!("{}", ball_set_create(BallValue::List(BallList::from(elements))));
}
"#,
    );
}
