//! Named-constructor call resolution and constructor initializer lists
//! (issue #527) — **emitted-source** assertions, so this suite is part of the
//! default `cargo test --workspace` and runs on EVERY PR (unlike
//! `compiler_conformance.rs`, which is `#[ignore]`d and shells out to cargo, and
//! unlike the whole-corpus `rust-compiler` leg, which lives only in
//! conformance-matrix.yml — a workflow with no `pull_request:` trigger that
//! ratchets an aggregate count rather than gating parity).
//!
//! The Dart encoder emits `Class.name(args)` as an ordinary method call whose
//! packed `self` field is a bare `reference{name: "Class"}` — the class name
//! itself, not a bound value. `compile_reference`'s final fallback formatted an
//! unrecognised name as `{}.clone()`, so the emitted Rust carried
//! `Countdown.clone()` and a bare `from(...)` — `error[E0425]: cannot find value
//! `Countdown``.

use std::fs;
use std::path::{Path, PathBuf};

use ball_lang_compiler::Compiler;
use ball_lang_shared::DESCRIPTOR_POOL;
use ball_lang_shared::proto::ball::v1::expression::Expr;
use ball_lang_shared::proto::ball::v1::literal::Value as LiteralValue;
use ball_lang_shared::proto::ball::v1::statement::Stmt;
use ball_lang_shared::proto::ball::v1::{
    Block, Expression, FieldValuePair, FunctionCall, FunctionDefinition, LetBinding, Literal,
    MessageCreation, Module, Program, Reference, Statement, TypeDefinition,
};
use ball_lang_shared::proto::google::protobuf::value::Kind;
use ball_lang_shared::proto::google::protobuf::{DescriptorProto, Struct, Value};
use prost::Message;
use prost_reflect::DynamicMessage;

fn repo_root() -> PathBuf {
    let mut dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    loop {
        if dir.join("proto/ball/v1/ball.proto").is_file() {
            return dir;
        }
        assert!(dir.pop(), "repo root not found");
    }
}

fn conformance(name: &str) -> PathBuf {
    repo_root().join("tests/conformance").join(name)
}

fn load_program(path: &Path) -> Program {
    let json = fs::read_to_string(path)
        .unwrap_or_else(|err| panic!("failed to read {}: {err}", path.display()));
    let mut json_value: serde_json::Value =
        serde_json::from_str(&json).expect(".ball.json must be valid JSON");
    if let serde_json::Value::Object(map) = &mut json_value {
        map.remove("@type");
    }
    let descriptor = DESCRIPTOR_POOL
        .get_message_by_name("ball.v1.Program")
        .expect("ball.v1.Program must resolve");
    let dynamic = DynamicMessage::deserialize(descriptor, json_value)
        .unwrap_or_else(|err| panic!("{} is not a ball.v1.Program: {err}", path.display()));
    Program::decode(dynamic.encode_to_vec().as_slice()).expect("typed decode")
}

fn compile_fixture(name: &str) -> String {
    Compiler::new(&load_program(&conformance(name))).compile()
}

/// Occurrences of `needle` in `haystack`.
fn occurrences(haystack: &str, needle: &str) -> usize {
    haystack.matches(needle).count()
}

#[test]
fn named_constructor_call_resolves_to_the_associated_fn() {
    let source = compile_fixture("436_recursive_ctor_named.ball.json");
    // Each associated fn must appear more than once: its own `pub fn`
    // declaration PLUS at least one resolved call site.
    assert!(
        occurrences(&source, "main_Countdown::from(") >= 1,
        "no resolved main_Countdown::from call site\n---\n{source}"
    );
    assert!(
        occurrences(&source, "main_Countdown::pair(") >= 1,
        "no resolved main_Countdown::pair call site\n---\n{source}"
    );
    // The class reference must never be compiled as a value.
    assert!(
        !source.contains("Countdown.clone()"),
        "class reference compiled as a value\n---\n{source}"
    );
}

#[test]
fn constructor_initializer_list_is_applied_when_the_constructor_has_a_body() {
    let source = compile_fixture("438_ctor_initializer_list_with_body.ball.json");
    for want in [
        "\"pt\".to_string()",
        "\"origin\".to_string()",
        "\"axis\".to_string()",
        "\"constants\".to_string()",
        "BallValue::Double(0.5f64)",
        "BallValue::Int(-3i64)",
    ] {
        assert!(
            source.contains(want),
            "emitted Rust missing initializer value {want}\n---\n{source}"
        );
    }
}

/// A local whose name matches a class short name still wins: the call is a
/// dispatch on that local's VALUE, never on the class. (Python's
/// `sr in self.type_defs and not self.lookup(sr)` guard is the reference
/// semantics all four compilers copy.)
#[test]
fn shadowing_local_beats_named_constructor_dispatch() {
    fn str_lit(value: &str) -> Expression {
        Expression {
            expr: Some(Expr::Literal(Literal {
                value: Some(LiteralValue::StringValue(value.to_string())),
            })),
        }
    }
    fn meta(kind: &str) -> Struct {
        let mut fields = std::collections::BTreeMap::new();
        fields.insert(
            "kind".to_string(),
            Value {
                kind: Some(Kind::StringValue(kind.to_string())),
            },
        );
        Struct {
            fields: fields.into_iter().collect(),
        }
    }

    let call = Expression {
        expr: Some(Expr::Call(Box::new(FunctionCall {
            module: String::new(),
            function: "from".to_string(),
            input: Some(Box::new(Expression {
                expr: Some(Expr::MessageCreation(MessageCreation {
                    type_name: String::new(),
                    fields: vec![
                        FieldValuePair {
                            name: "self".to_string(),
                            value: Some(Expression {
                                expr: Some(Expr::Reference(Reference {
                                    name: "Countdown".to_string(),
                                })),
                            }),
                        },
                        FieldValuePair {
                            name: "arg0".to_string(),
                            value: Some(str_lit("x")),
                        },
                    ],
                    metadata: None,
                })),
            })),
            type_args: Vec::new(),
        }))),
    };

    let program = Program {
        name: "shadow".to_string(),
        version: "1.0.0".to_string(),
        entry_module: "main".to_string(),
        entry_function: "main".to_string(),
        modules: vec![Module {
            name: "main".to_string(),
            type_defs: vec![TypeDefinition {
                name: "main:Countdown".to_string(),
                descriptor: Some(DescriptorProto {
                    name: Some("main:Countdown".to_string()),
                    ..Default::default()
                }),
                metadata: Some(meta("class")),
                description: String::new(),
                type_params: Vec::new(),
            }],
            functions: vec![
                FunctionDefinition {
                    name: "main".to_string(),
                    body: Some(Box::new(Expression {
                        expr: Some(Expr::Block(Box::new(Block {
                            statements: vec![
                                Statement {
                                    stmt: Some(Stmt::Let(LetBinding {
                                        name: "Countdown".to_string(),
                                        value: Some(str_lit("shadowed")),
                                        metadata: None,
                                    })),
                                },
                                Statement {
                                    stmt: Some(Stmt::Expression(call)),
                                },
                            ],
                            result: None,
                        }))),
                    })),
                    ..Default::default()
                },
                FunctionDefinition {
                    name: "main:Countdown.from".to_string(),
                    body: Some(Box::new(str_lit("class"))),
                    metadata: Some(meta("constructor")),
                    ..Default::default()
                },
            ],
            ..Default::default()
        }],
        ..Default::default()
    };

    let source = Compiler::new(&program).compile();
    // `main_Countdown::from(` is the CALL-SITE spelling only — the constructor's
    // own declaration is `pub fn from(` inside `impl main_Countdown`, so its
    // absence here means the class-reference branch did not fire.
    assert!(
        !source.contains("main_Countdown::from("),
        "a shadowing local must not resolve as a class reference\n---\n{source}"
    );
}
