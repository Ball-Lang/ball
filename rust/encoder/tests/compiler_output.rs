//! The encoder must be able to read back what `ball-lang-compiler` EMITS, not
//! only idiomatic hand-written Rust (issue #642).
//!
//! Before this, the compiler's own output tripped four failures at once — the
//! unconditional `pub static Expression_Expr: LazyLock<BallValue>` namespaces,
//! the `(|| -> BallValue { … })()` IIFE the entry body is wrapped in, and the
//! `BallValue::String(…)`/`BallValue::Null` value constructors every literal
//! becomes, and — worse than a refusal — the `ball_*` runtime helpers every base
//! call becomes, which the bare-identifier call path silently encoded as calls to
//! functions nobody declared (a Program that died at RUN time with
//! `Function "main.ball_add" not found`) — so not one of the conformance fixtures could survive
//! Ball → Rust → Ball, and the `rust-roundtrip` matrix row measured a flat 0
//! while reporting the harness healthy.
//!
//! The whole-corpus proof is that row
//! (`rust/engine/tests/roundtrip_conformance.rs`, floored and ratcheted in
//! `conformance-matrix.yml`). These are the fast, in-workspace guards on the
//! SHAPE, so a regression is a failing `cargo test` rather than a matrix row
//! nobody ran. The Program is built in code rather than read from the corpus so
//! this crate needs no JSON/descriptor dev-dependency of its own.

use ball_lang_compiler::Compiler;
use ball_lang_shared::proto::ball::v1::expression::Expr;
use ball_lang_shared::proto::ball::v1::statement::Stmt;
use ball_lang_shared::proto::ball::v1::{
    Expression, FieldValuePair, FunctionCall, FunctionDefinition, Literal, MessageCreation, Module,
    Program,
};

/// The Ball equivalent of `void main() { print('hello'); }` — the shape
/// `tests/conformance/265_enc_hello.ball.json` carries.
fn hello_program() -> Program {
    let print_call = Expression {
        expr: Some(Expr::Call(Box::new(FunctionCall {
            module: "std".to_string(),
            function: "print".to_string(),
            input: Some(Box::new(Expression {
                expr: Some(Expr::MessageCreation(MessageCreation {
                    type_name: String::new(),
                    fields: vec![FieldValuePair {
                        name: "message".to_string(),
                        value: Some(Expression {
                            expr: Some(Expr::Literal(Literal {
                                value: Some(
                                    ball_lang_shared::proto::ball::v1::literal::Value::StringValue(
                                        "hello".to_string(),
                                    ),
                                ),
                            })),
                        }),
                    }],
                    ..Default::default()
                })),
            })),
            ..Default::default()
        }))),
    };

    Program {
        name: "encoded".to_string(),
        version: "1.0.0".to_string(),
        entry_module: "main".to_string(),
        entry_function: "main".to_string(),
        modules: vec![
            Module {
                name: "std".to_string(),
                functions: vec![FunctionDefinition {
                    name: "print".to_string(),
                    is_base: true,
                    ..Default::default()
                }],
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

/// The compiler half: a program that references no oneof discriminator emits
/// none of their `LazyLock` namespaces. They used to be emitted
/// unconditionally — roughly 40 lines of dead statics at the head of every
/// compiled program, a hello-world included.
#[test]
fn compiler_output_has_no_dead_oneof_statics() {
    let program = hello_program();
    let source = Compiler::new(&program).compile();
    assert!(
        !source.contains("Expression_Expr"),
        "compiled hello-world still emits an unreferenced oneof namespace:\n{source}"
    );
}

/// The encoder half: the compiler's own hello-world re-encodes cleanly into a
/// Program that declares `std.print` — proof that the IIFE wrapper and the
/// `BallValue::String(…)` constructor were both recognised.
#[test]
fn encodes_compiler_output() {
    let program = hello_program();
    let source = Compiler::new(&program).compile();
    let reencoded = ball_lang_encoder::encode(&source);

    assert_eq!(reencoded.entry_function, "main");
    let std_module = reencoded
        .modules
        .iter()
        .find(|m| m.name == "std")
        .expect("the re-encoded program declares no std module");
    assert!(
        std_module.functions.iter().any(|f| f.name == "print"),
        "println! was not recognised as std.print: {std_module:?}"
    );
}

/// `BallValue::Null` is the compiler's spelling of a Ball null literal, and the
/// encoder must read it as one rather than fail on an unsupported path.
#[test]
fn ball_value_null_encodes_as_null_literal() {
    let program =
        ball_lang_encoder::encode("fn main() { let x = BallValue::Null; println!(\"{}\", x); }");
    let main = program
        .modules
        .iter()
        .find(|m| m.name == "main")
        .and_then(|m| m.functions.iter().find(|f| f.name == "main"))
        .expect("no main function");
    let body = main.body.as_ref().expect("main has no body");
    let block = match body.expr.as_ref().expect("main body has no expr") {
        Expr::Block(b) => b,
        other => panic!("main body is not a block: {other:?}"),
    };
    let first = block.statements.first().expect("main body is empty");
    let let_binding = match first.stmt.as_ref().expect("statement has no stmt") {
        Stmt::Let(l) => l,
        other => panic!("first statement is not a let: {other:?}"),
    };
    let value = let_binding.value.as_ref().expect("let has no value");
    match value.expr.as_ref().expect("let value has no expr") {
        Expr::Literal(lit) => {
            assert!(
                lit.value.is_none(),
                "BallValue::Null must encode as Ball null"
            );
        }
        other => panic!("BallValue::Null did not encode as a literal: {other:?}"),
    }
}

/// A `ball_*` runtime helper encodes to the `std` base call it is the emission
/// of. Before #642 a bare `ball_add(x, y)` fell through to the same-file-call
/// path and produced a Program that only failed at RUN time.
#[test]
fn runtime_helper_encodes_as_its_std_base_call() {
    let program = ball_lang_encoder::encode("fn main() { println!(\"{}\", ball_add(1, 2)); }");
    let std_module = program
        .modules
        .iter()
        .find(|m| m.name == "std")
        .expect("no std module");
    assert!(
        std_module.functions.iter().any(|f| f.name == "add"),
        "ball_add was not recognised as std.add: {std_module:?}"
    );
}

/// An UNMAPPED `ball_*` name fails loud. Silently encoding it as a same-file
/// call is the exact silent degradation issue #55's doctrine forbids.
#[test]
#[should_panic(expected = "unsupported runtime helper")]
fn unmapped_runtime_helper_fails_loud() {
    ball_lang_encoder::encode("fn main() { ball_no_such_helper(1); }");
}

/// A file that declares its OWN `fn ball_*` still wins — the table never
/// shadows a real same-file definition.
#[test]
fn same_file_ball_prefixed_fn_is_not_shadowed() {
    let program = ball_lang_encoder::encode(
        "fn ball_add(n: i64) -> i64 { n } fn main() { println!(\"{}\", ball_add(1)); }",
    );
    let main_module = program
        .modules
        .iter()
        .find(|m| m.name == "main")
        .expect("no main module");
    assert!(
        main_module.functions.iter().any(|f| f.name == "ball_add"),
        "the file's own ball_add was dropped: {main_module:?}"
    );
}

/// The compiler's own MUTATION idiom must write through to the variable it
/// borrows — the one shape whose mis-encoding is silent (issue #642).
///
/// `lvalue.rs::emit_mutation` lowers every Ball `assign` to
/// `{ let __val = ...; let __slot: &mut BallValue = (&mut i); ...;
/// *__slot = __new.clone(); __new }`. Ball has no references, so binding
/// `__slot` as a VALUE made the write land on a copy: `i` never changed, and
/// every loop whose counter is mutated that way ran forever. That is worse than
/// a refusal — the Program round-tripped "clean" and then hung, which is what 28
/// of the corpus's loop fixtures did on the Dart reference engine (killed after
/// 60 s) once the leg got far enough to run them.
#[test]
fn mutation_through_a_mut_alias_targets_the_borrowed_variable() {
    let program = ball_lang_encoder::encode(
        "fn main() { let mut i = BallValue::Int(0i64); \
         { let __val = ball_add(i.clone(), BallValue::Int(1i64)); \
           let __slot: &mut BallValue = (&mut i); \
           let __old = __slot.clone(); let __new = __val; \
           *__slot = __new.clone(); __new }; \
         println!(\"{}\", i); }",
    );

    let targets = assign_targets(&program);
    assert_eq!(
        targets,
        vec!["i".to_string()],
        "the assign must target the borrowed variable, not the alias binding: {targets:?}"
    );
    assert!(
        !declared_let_names(&program).iter().any(|n| n == "__slot"),
        "the `&mut` alias must not be emitted as a value binding: {:?}",
        declared_let_names(&program)
    );
}

/// A borrow of anything OTHER than a plain named variable is not an alias this
/// encoder models, and is left exactly as it was — never guessed at.
#[test]
fn a_borrow_of_a_non_variable_place_is_not_treated_as_an_alias() {
    let program = ball_lang_encoder::encode(
        "fn main() { let p = make(); let slot = &mut p.field; println!(\"{}\", slot); } \
         fn make() -> i64 { 1 }",
    );
    assert!(
        declared_let_names(&program).iter().any(|n| n == "slot"),
        "a `&mut <field>` binding must still be emitted: {:?}",
        declared_let_names(&program)
    );
}

/// Every `std.assign` target name in the program, in encounter order.
fn assign_targets(program: &Program) -> Vec<String> {
    let mut found = Vec::new();
    for module in &program.modules {
        for function in &module.functions {
            if let Some(body) = &function.body {
                collect_assign_targets(body, &mut found);
            }
        }
    }
    found
}

fn collect_assign_targets(expr: &Expression, out: &mut Vec<String>) {
    match expr.expr.as_ref() {
        Some(Expr::Call(call)) => {
            if call.function == "assign" {
                if let Some(input) = &call.input {
                    if let Some(Expr::MessageCreation(message)) = input.expr.as_ref() {
                        for field in &message.fields {
                            if field.name == "target" {
                                if let Some(Expr::Reference(reference)) =
                                    field.value.as_ref().and_then(|v| v.expr.as_ref())
                                {
                                    out.push(reference.name.clone());
                                }
                            }
                        }
                    }
                }
            }
            if let Some(input) = &call.input {
                collect_assign_targets(input, out);
            }
        }
        Some(Expr::Block(block)) => {
            for statement in &block.statements {
                match statement.stmt.as_ref() {
                    Some(Stmt::Expression(inner)) => collect_assign_targets(inner, out),
                    Some(Stmt::Let(binding)) => {
                        if let Some(value) = &binding.value {
                            collect_assign_targets(value, out);
                        }
                    }
                    _ => {}
                }
            }
            if let Some(result) = &block.result {
                collect_assign_targets(result, out);
            }
        }
        Some(Expr::MessageCreation(message)) => {
            for field in &message.fields {
                if let Some(value) = &field.value {
                    collect_assign_targets(value, out);
                }
            }
        }
        _ => {}
    }
}

/// Every `let` binding name the program declares, in encounter order.
fn declared_let_names(program: &Program) -> Vec<String> {
    let mut found = Vec::new();
    for module in &program.modules {
        for function in &module.functions {
            if let Some(body) = &function.body {
                collect_let_names(body, &mut found);
            }
        }
    }
    found
}

fn collect_let_names(expr: &Expression, out: &mut Vec<String>) {
    match expr.expr.as_ref() {
        Some(Expr::Block(block)) => {
            for statement in &block.statements {
                match statement.stmt.as_ref() {
                    Some(Stmt::Let(binding)) => {
                        out.push(binding.name.clone());
                        if let Some(value) = &binding.value {
                            collect_let_names(value, out);
                        }
                    }
                    Some(Stmt::Expression(inner)) => collect_let_names(inner, out),
                    _ => {}
                }
            }
            if let Some(result) = &block.result {
                collect_let_names(result, out);
            }
        }
        Some(Expr::Call(call)) => {
            if let Some(input) = &call.input {
                collect_let_names(input, out);
            }
        }
        Some(Expr::MessageCreation(message)) => {
            for field in &message.fields {
                if let Some(value) = &field.value {
                    collect_let_names(value, out);
                }
            }
        }
        _ => {}
    }
}
