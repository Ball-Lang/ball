//! Stage 3 of the Tier A / round-trip pipeline for the Ball Rust runtime's own
//! **collection constructors** and **class-registry prologue** (issue #692).
//!
//! `compile_reencode_roundtrip.rs` states the contract these tests extend:
//! every construct `ball-lang-compiler` EMITS must be a construct
//! `ball-lang-encoder` can read back. #646 taught the encoder the
//! `(|| -> BallValue { … })()` IIFE, the `BallValue::…` *scalar* constructors
//! and the `ball_*` runtime-helper table. This file covers the next two
//! measured blockers of the `rust-roundtrip` row in
//! `.github/workflows/conformance-matrix.yml`:
//!
//! 1. the collection constructors —
//!    `BallValue::List(BallList::from(vec![…]))`, `BallList::new()`,
//!    `BallValue::Map(BallMap::new())` — and the
//!    `{ let mut __ball_map = BallMap::new(); …inserts…; BallValue::Map(m) }`
//!    block the compiler emits for every `message_creation`;
//! 2. `pub fn __ball_register_types()` and its `ball_register_superclass`
//!    calls — the compiler's **class prologue**, whose inverse is structural (a
//!    `TypeDefinition`'s `metadata.superclass`), not one more row in
//!    `runtime_helpers.rs`.
//!
//! ## Why these assertions are shaped this way
//!
//! Each test drives the REAL pipeline — `encode` the Rust, `compile` the Ball,
//! `encode` the compiled Rust — and first asserts the compiler still emits the
//! construct under test. A stage-3 assertion alone can go green because the
//! compiler stopped emitting the shape, which would silently retire the gate
//! rather than keep it.
//!
//! The inheritance case cannot be produced from Rust source (Rust has no
//! inheritance, so `encode_item_struct` never writes a `metadata.superclass`).
//! It is therefore built by encoding two plain structs and then setting that
//! one cosmetic metadata key — the smallest honest way to make the compiler
//! emit the prologue at all. A *behavioural* `is`/`as` proof is deliberately
//! NOT attempted here: `ball_is` has no entry in `runtime_helpers.rs`, so such
//! a program stops one construct earlier, on a different gap. The behavioural
//! half of THIS slice — the re-encoded program still computing the same answer
//! — lives in `compile_reencode_roundtrip.rs`, which owns the `cargo build`
//! harness.
use ball_lang_compiler::Compiler;
use ball_lang_shared::proto::ball::v1::expression::Expr;
use ball_lang_shared::proto::ball::v1::literal::Value as LiteralValue;
use ball_lang_shared::proto::ball::v1::statement::Stmt;
use ball_lang_shared::proto::ball::v1::{Expression, MessageCreation, Program};
use ball_lang_shared::proto::google::protobuf::Value;
use ball_lang_shared::proto::google::protobuf::value::Kind;

// ════════════════════════════════════════════════════════════
// Sources
// ════════════════════════════════════════════════════════════

/// A list literal in a value position — `compile_list_literal`'s common path,
/// which emits `BallValue::List(BallList::from(vec![…]))`.
const LIST_SOURCE: &str = r#"
fn main() {
    let xs = vec![10, 20, 30];
    println!("{}", xs[1]);
}
"#;

/// A struct literal — `compile_message_creation`'s named path, which emits the
/// `{ let mut __ball_map = BallMap::new(); …; BallValue::Message(BallMessage::new(…)) }`
/// block.
const CLASS_SOURCE: &str = r#"
struct Point {
    x: i64,
    y: i64,
}

fn main() {
    let p = Point { x: 3, y: 4 };
    println!("{}", p.x);
}
"#;

/// Two plain structs; the `Dog extends Animal` relation is added to the encoded
/// Ball as `metadata.superclass` (see the module doc comment).
const INHERITANCE_SOURCE: &str = r#"
struct Animal {
    name: i64,
}

struct Dog {
    name: i64,
}

fn main() {
    let d = Dog { name: 7 };
    println!("{}", d.name);
}
"#;

// ════════════════════════════════════════════════════════════
// Walking helpers
// ════════════════════════════════════════════════════════════

/// Every expression reachable from `program`'s USER modules (a base module
/// declares bodiless functions only), in encounter order. Clones on purpose —
/// the callers filter and then assert on a handful of nodes, and the programs
/// here are a few hundred nodes at most.
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

/// Every list literal in `program`, as the integer elements it carries — enough
/// to tell `[10, 20, 30]` from an empty one.
fn list_literals(program: &Program) -> Vec<Vec<i64>> {
    all_expressions(program)
        .iter()
        .filter_map(|expr| match &expr.expr {
            Some(Expr::Literal(literal)) => match &literal.value {
                Some(LiteralValue::ListValue(list)) => Some(
                    list.elements
                        .iter()
                        .filter_map(|element| match &element.expr {
                            Some(Expr::Literal(inner)) => match &inner.value {
                                Some(LiteralValue::IntValue(value)) => Some(*value),
                                _ => None,
                            },
                            _ => None,
                        })
                        .collect(),
                ),
                _ => None,
            },
            _ => None,
        })
        .collect()
}

/// Every `message_creation` in `program`, as `(type_name, [field names])`.
fn message_creations(program: &Program) -> Vec<(String, Vec<String>)> {
    all_expressions(program)
        .iter()
        .filter_map(|expr| match &expr.expr {
            Some(Expr::MessageCreation(creation)) => Some(summarize(creation)),
            _ => None,
        })
        .collect()
}

fn summarize(creation: &MessageCreation) -> (String, Vec<String>) {
    (
        creation.type_name.clone(),
        creation.fields.iter().map(|f| f.name.clone()).collect(),
    )
}

/// Every `std.<function>` called in `program`'s user modules.
fn std_calls(program: &Program) -> Vec<String> {
    all_expressions(program)
        .iter()
        .filter_map(|expr| match &expr.expr {
            Some(Expr::Call(call)) if call.module == "std" => Some(call.function.clone()),
            _ => None,
        })
        .collect()
}

/// Every user function name in `program`'s user modules.
fn function_names(program: &Program) -> Vec<String> {
    let mut names = Vec::new();
    for module in &program.modules {
        if module.functions.iter().all(|f| f.is_base) {
            continue;
        }
        for function in &module.functions {
            names.push(function.name.clone());
        }
    }
    names
}

fn string_meta(program: &Program, type_name: &str, key: &str) -> Option<String> {
    for module in &program.modules {
        for type_def in &module.type_defs {
            if type_def.name != type_name {
                continue;
            }
            let value = type_def.metadata.as_ref()?.fields.get(key)?;
            return match &value.kind {
                Some(Kind::StringValue(text)) => Some(text.clone()),
                _ => None,
            };
        }
    }
    None
}

fn set_string_meta(program: &mut Program, type_name: &str, key: &str, text: &str) {
    for module in &mut program.modules {
        for type_def in &mut module.type_defs {
            if type_def.name != type_name {
                continue;
            }
            let metadata = type_def.metadata.get_or_insert_with(Default::default);
            metadata.fields.insert(
                key.to_string(),
                Value {
                    kind: Some(Kind::StringValue(text.to_string())),
                },
            );
            return;
        }
    }
    panic!("the encoded program must declare `{type_name}` for this test to mean anything");
}

// ════════════════════════════════════════════════════════════
// 1. Collection constructors
// ════════════════════════════════════════════════════════════

/// `BallValue::List(BallList::from(vec![…]))` — the shape EVERY non-spliced
/// Ball list literal compiles to — must read back as the list literal it is.
/// Before #692 the encoder refused it: `List` was not one of the scalar
/// variants its `BallValue::…` identity arm knew, so the call fell through to
/// the "unsupported call target" panic, and 49 corpus fixtures were
/// first-blocked there.
#[test]
fn a_compiled_list_literal_re_encodes_as_a_list_literal() {
    let stage1 = ball_lang_encoder::encode(LIST_SOURCE);
    let compiled = Compiler::new(&stage1).compile();
    assert!(
        compiled.contains("BallValue::List(BallList::from(vec!["),
        "the compiler must still emit its list constructor — otherwise this test is not \
         exercising the construct it claims to:\n{compiled}"
    );

    let stage3 = ball_lang_encoder::encode(&compiled);
    let literals = list_literals(&stage3);
    assert!(
        literals.iter().any(|elements| elements == &[10, 20, 30]),
        "the compiled list constructor must read back as the very list literal it compiles \
         from. List literals found: {literals:?}"
    );
}

/// The EMPTY collection constructors, which carry no `vec!` to fall back on:
/// `BallList::new()` is a list literal with no elements and `BallMap::new()` is
/// `std.map_create` with no entries — the same two nodes
/// `dart/encoder/lib/encoder.dart` emits for `[]` and `{}`. The compiler
/// reaches them through `field_list_or_empty` (an elementless `typed_list`),
/// `defaultList`, and `sdk_collection_creation`'s `LinkedHashMap()`.
#[test]
fn the_empty_runtime_collection_constructors_re_encode_as_empty_literals() {
    let program = ball_lang_encoder::encode(
        "fn main() {\n    let xs = BallValue::List(BallList::new());\n    \
         let m = BallValue::Map(BallMap::new());\n    println!(\"{}{}\", xs, m);\n}\n",
    );

    let literals = list_literals(&program);
    assert!(
        literals.iter().any(std::vec::Vec::is_empty),
        "`BallList::new()` must encode as an EMPTY list literal. List literals found: {literals:?}"
    );

    let calls = std_calls(&program);
    assert!(
        calls.iter().any(|name| name == "map_create"),
        "`BallMap::new()` must encode as `std.map_create`. std calls found: {calls:?}"
    );
    let creations = message_creations(&program);
    assert!(
        creations
            .iter()
            .any(|(type_name, fields)| type_name.is_empty() && fields.is_empty()),
        "…carrying an EMPTY entry list, the way `dart/encoder`'s `{{}}` does. \
         message_creations found: {creations:?}"
    );
}

/// The `message_creation` block — `{ let mut __ball_map = BallMap::new();
/// __ball_map.insert("x".to_string(), …); BallValue::Message(BallMessage::new("main:Point",
/// __ball_map)) }` — must read back as the `message_creation` it compiles from,
/// type name and field names intact. 33 corpus fixtures were first-blocked on
/// its `BallMap::new()`.
#[test]
fn a_compiled_message_creation_re_encodes_as_a_message_creation() {
    let stage1 = ball_lang_encoder::encode(CLASS_SOURCE);
    let compiled = Compiler::new(&stage1).compile();
    assert!(
        compiled.contains("let mut __ball_map = BallMap::new();"),
        "the compiler must still build a message creation through `BallMap::new()`:\n{compiled}"
    );
    assert!(
        compiled.contains("BallValue::Message(BallMessage::new(\"main:Point\","),
        "…and seal it as a `BallMessage` under the type's own name:\n{compiled}"
    );

    let stage3 = ball_lang_encoder::encode(&compiled);
    let creations = message_creations(&stage3);
    let expected = vec!["x".to_string(), "y".to_string()];
    assert!(
        creations
            .iter()
            .any(|(type_name, fields)| type_name == "main:Point" && fields == &expected),
        "the compiled block must read back as a `message_creation` for `main:Point` with its \
         own field names. message_creations found: {creations:?}"
    );
}

/// The ANONYMOUS half of the same idiom — `message_creation` with no type name,
/// which is how every multi-argument base call packs its input. It seals with
/// `BallValue::Map(__ball_map)` rather than a `BallMessage`, so it is a
/// genuinely different tail and gets its own assertion.
#[test]
fn a_compiled_anonymous_message_creation_re_encodes_with_no_type_name() {
    let program = ball_lang_encoder::encode(
        "fn main() {\n    let m = {\n        let mut __ball_map = BallMap::new();\n        \
         __ball_map.insert(\"left\".to_string(), BallValue::Int(1i64));\n        \
         __ball_map.insert(\"right\".to_string(), BallValue::Int(2i64));\n        \
         BallValue::Map(__ball_map)\n    };\n    println!(\"{}\", m);\n}\n",
    );
    let creations = message_creations(&program);
    let expected = vec!["left".to_string(), "right".to_string()];
    assert!(
        creations
            .iter()
            .any(|(type_name, fields)| type_name.is_empty() && fields == &expected),
        "a `BallValue::Map`-sealed builder block must read back as an anonymous \
         `message_creation` keyed by its inserted field names. \
         message_creations found: {creations:?}"
    );
}

// ════════════════════════════════════════════════════════════
// 2. The class-registry prologue
// ════════════════════════════════════════════════════════════

/// `ball_register_superclass("Dog", "Animal")` inside the compiler-synthesised
/// `pub fn __ball_register_types()` is the class prologue, not a base call: its
/// inverse is the `TypeDefinition`'s own `metadata.superclass`, which is
/// exactly where `dart/encoder` puts it (`tests/conformance/102_inheritance.ball.json`
/// carries `"superclass": "Animal"`). 22 corpus fixtures were first-blocked on
/// it, as an unmapped `ball_*` helper.
/// The re-encoded names are `main:main_Dog`/`main:main_Animal`, not
/// `main:Dog`/`main:Animal`: `compile_struct_def` names its emitted Rust struct
/// `sanitize_ident("main:Dog")` — `main_Dog` — and `encode_item_struct` then
/// qualifies THAT under its own module prefix. That is a pre-existing
/// round-trip infidelity of the type NAME, unrelated to this slice (the
/// instances the same program builds still carry `BallMessage::new("main:Dog",
/// …)`), and it is asserted here rather than papered over so the next reader
/// sees it stated.
#[test]
fn the_compiled_class_registry_re_encodes_as_superclass_metadata() {
    let mut stage1 = ball_lang_encoder::encode(INHERITANCE_SOURCE);
    set_string_meta(&mut stage1, "main:Dog", "superclass", "Animal");

    let compiled = Compiler::new(&stage1).compile();
    assert!(
        compiled.contains("ball_register_superclass(\"Dog\", \"Animal\");"),
        "the compiler must still emit the class-registry prologue:\n{compiled}"
    );
    assert!(
        compiled.contains("pub struct main_Dog {"),
        "…and still name the child's struct `sanitize_ident(\"main:Dog\")`, which is what the \
         registration's short `Dog` has to be resolved against:\n{compiled}"
    );

    let stage3 = ball_lang_encoder::encode(&compiled);
    assert_eq!(
        string_meta(&stage3, "main:main_Dog", "superclass").as_deref(),
        Some("Animal"),
        "the registration must read back as the child class's own `metadata.superclass`"
    );
    assert_eq!(
        string_meta(&stage3, "main:main_Animal", "superclass"),
        None,
        "…and only for the class that was actually registered"
    );
}

/// The prologue is the COMPILER's, not the program's: neither the synthesised
/// `__ball_register_types` function nor `fn main()`'s call to it may survive
/// into the re-encoded Ball. Leaving them in would emit a user function whose
/// body is a list of `ball_*` calls no Ball engine declares.
#[test]
fn the_compiled_class_registry_is_not_re_encoded_as_a_user_function() {
    let mut stage1 = ball_lang_encoder::encode(INHERITANCE_SOURCE);
    set_string_meta(&mut stage1, "main:Dog", "superclass", "Animal");
    let compiled = Compiler::new(&stage1).compile();
    assert!(
        compiled.contains("__ball_register_types();"),
        "the compiler must still CALL the prologue from `fn main()`:\n{compiled}"
    );

    let stage3 = ball_lang_encoder::encode(&compiled);
    let names = function_names(&stage3);
    assert!(
        !names.iter().any(|name| name == "__ball_register_types"),
        "the compiler's class prologue must not come back as a user function: {names:?}"
    );
    let rendered = format!("{stage3:?}");
    assert!(
        !rendered.contains("__ball_register_types"),
        "…and nothing may still CALL it either"
    );
}

/// A program with NO inheritance still gets an (empty) prologue, and it must be
/// dropped just the same — this is the shape every currently-passing fixture
/// carries, so the drop must not be conditional on there being a registration
/// to harvest.
#[test]
fn an_empty_class_registry_is_dropped_too() {
    let stage1 = ball_lang_encoder::encode(CLASS_SOURCE);
    let compiled = Compiler::new(&stage1).compile();
    assert!(
        compiled.contains("pub fn __ball_register_types() {\n}"),
        "a program with no superclass must still get an EMPTY prologue:\n{compiled}"
    );

    let stage3 = ball_lang_encoder::encode(&compiled);
    let rendered = format!("{stage3:?}");
    assert!(
        !rendered.contains("__ball_register_types"),
        "an empty class prologue must be dropped, not encoded as a no-op user function"
    );
}
