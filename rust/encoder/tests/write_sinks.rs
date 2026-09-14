//! `write!` / `writeln!` in the Rust encoder — issue #630, slice 5.
//!
//! ## Why these macros need no type information
//!
//! `core`'s own definition is
//! `($dst:expr, $($arg:tt)*) => { $dst.write_fmt($crate::format_args!($($arg)*)) }`
//! (`library/core/src/macros/mod.rs`) — the destination is a **method
//! receiver**, so the macro is not sink-aware at all. `writeln!` is the same
//! thing plus a newline, and `core` spells its no-argument arm literally as
//! `write!($dst, "\n")`. rustc special-cases only `format_args!` (it became
//! its own AST node in rust-lang/rust#106745), and rust-analyzer makes the
//! identical split — `format_args`/`format_args_nl` are builtin expanders,
//! `write!`/`writeln!` are left to the ordinary `macro_rules!` path in `core`.
//!
//! The encoder therefore needs **no semantic model**: the first argument of
//! `write!` **is** the sink, by construction. That matters concretely — 6 of
//! the 7 first-blocked Tier A Rust files write through an *unannotated closure
//! parameter* (`|f| write!(f, "-")`), which no amount of type inference could
//! resolve.
//!
//! ## The two arms (design record: `docs/SINK_DESIGN.md` §5)
//!
//! * **arm (b)** — any destination that is not a provably-local `String`:
//!   `std.sink_write{sink, text}` against the declared, tagged,
//!   reference-semantic text sink landed in #636.
//! * **arm (a)**, the "join sites" rule — a destination that IS a local
//!   `let mut s = String::new()`: a plain re-assignment
//!   `s = std.concat(s, text)`. Such a local is read back **as a `String`**
//!   elsewhere in the same function (`itertools::join` returns it, and tests
//!   its length), so turning it into an opaque sink would silently change
//!   every one of those reads.
//! * a destination that is a local of some **other** type — a **loud panic**
//!   naming the local and its initialiser. Never guess: silently picking arm
//!   (b) there would lose the variable's non-sink reads.
//!
//! `write!` evaluates to a `fmt::Result`, and 22 of the corpus' 25 sites
//! consume it with `?` or `.unwrap()`, so both arms are wrapped in the
//! encoder's unified `Ok(..)` outcome message.

use ball_lang_compiler::Compiler;
use ball_lang_shared::proto::ball::v1::expression::Expr;
use ball_lang_shared::proto::ball::v1::statement::Stmt;
use ball_lang_shared::proto::ball::v1::{Expression, FunctionCall, Module, Program, Reference};

use ball_lang_encoder::{encode, encode_library};

// ════════════════════════════════════════════════════════════
// Tree helpers
// ════════════════════════════════════════════════════════════

fn module<'a>(program: &'a Program, name: &str) -> &'a Module {
    program
        .modules
        .iter()
        .find(|m| m.name == name)
        .unwrap_or_else(|| {
            panic!(
                "no module `{name}` in the encoded program (modules: {:?})",
                program.modules.iter().map(|m| &m.name).collect::<Vec<_>>()
            )
        })
}

fn reference_to(name: &str) -> Option<Expr> {
    Some(Expr::Reference(Reference {
        name: name.to_string(),
    }))
}

/// Every `call` node anywhere inside `expr`, in pre-order.
fn collect_calls<'a>(expr: &'a Expression, out: &mut Vec<&'a FunctionCall>) {
    match expr.expr.as_ref() {
        Some(Expr::Call(call)) => {
            out.push(call);
            if let Some(input) = &call.input {
                collect_calls(input, out);
            }
        }
        Some(Expr::FieldAccess(access)) => {
            if let Some(object) = &access.object {
                collect_calls(object, out);
            }
        }
        Some(Expr::MessageCreation(message)) => {
            for field in &message.fields {
                if let Some(value) = &field.value {
                    collect_calls(value, out);
                }
            }
        }
        Some(Expr::Block(block)) => {
            for statement in &block.statements {
                match statement.stmt.as_ref() {
                    Some(Stmt::Expression(inner)) => collect_calls(inner, out),
                    Some(Stmt::Let(binding)) => {
                        if let Some(value) = &binding.value {
                            collect_calls(value, out);
                        }
                    }
                    None => {}
                }
            }
            if let Some(result) = &block.result {
                collect_calls(result, out);
            }
        }
        Some(Expr::Lambda(lambda)) => {
            if let Some(body) = &lambda.body {
                collect_calls(body, out);
            }
        }
        _ => {}
    }
}

/// Every `call` node inside the named function of the `main` module.
fn calls_in<'a>(program: &'a Program, function: &str) -> Vec<&'a FunctionCall> {
    let main = module(program, "main");
    let def = main
        .functions
        .iter()
        .find(|f| f.name == function)
        .unwrap_or_else(|| {
            panic!(
                "no function `{function}` in the `main` module (functions: {:?})",
                main.functions.iter().map(|f| &f.name).collect::<Vec<_>>()
            )
        });
    let mut out = Vec::new();
    collect_calls(def.body.as_ref().expect("a body"), &mut out);
    out
}

fn count_std_calls(program: &Program, function: &str, std_fn: &str) -> usize {
    calls_in(program, function)
        .iter()
        .filter(|c| c.module == "std" && c.function == std_fn)
        .count()
}

/// The single `std.<std_fn>` call inside `function`, or a panic naming what
/// was found instead.
fn only_std_call<'a>(program: &'a Program, function: &str, std_fn: &str) -> &'a FunctionCall {
    let calls = calls_in(program, function);
    let matching: Vec<&FunctionCall> = calls
        .iter()
        .copied()
        .filter(|c| c.module == "std" && c.function == std_fn)
        .collect();
    assert_eq!(
        matching.len(),
        1,
        "expected exactly one `std.{std_fn}` call in `{function}`, found {} (all calls: {:?})",
        matching.len(),
        calls
            .iter()
            .map(|c| format!("{}.{}", c.module, c.function))
            .collect::<Vec<_>>()
    );
    matching[0]
}

/// A base-function call's named input field.
fn field<'a>(call: &'a FunctionCall, name: &str) -> &'a Expression {
    let input = call.input.as_ref().expect("a base call carries an input");
    let Some(Expr::MessageCreation(message)) = input.expr.as_ref() else {
        panic!("a base call's input must be a message_creation, got {input:?}");
    };
    message
        .fields
        .iter()
        .find(|f| f.name == name)
        .unwrap_or_else(|| {
            panic!(
                "no `{name}` field on `{}.{}` (fields: {:?})",
                call.module,
                call.function,
                message.fields.iter().map(|f| &f.name).collect::<Vec<_>>()
            )
        })
        .value
        .as_ref()
        .expect("a field carries a value")
}

/// Flatten a `std.concat` chain into the pieces it concatenates, so a test can
/// assert the exact text a `write!` builds without re-deriving the nesting.
fn text_pieces(expr: &Expression) -> Vec<String> {
    match expr.expr.as_ref() {
        Some(Expr::Call(call)) if call.module == "std" && call.function == "concat" => {
            let mut pieces = text_pieces(field(call, "left"));
            pieces.extend(text_pieces(field(call, "right")));
            pieces
        }
        Some(Expr::Call(call)) if call.module == "std" && call.function == "to_string" => {
            vec!["<to_string>".to_string()]
        }
        Some(Expr::Literal(literal)) => match &literal.value {
            Some(ball_lang_shared::proto::ball::v1::literal::Value::StringValue(s)) => {
                vec![s.clone()]
            }
            other => panic!("expected a string literal in a format chain, got {other:?}"),
        },
        Some(Expr::Reference(reference)) => vec![format!("<ref {}>", reference.name)],
        other => panic!("unexpected node in a format chain: {other:?}"),
    }
}

/// `write!` returns a `fmt::Result`, so both arms are wrapped in the encoder's
/// unified `Ok(..)` outcome message (`{is_err: false, value: ..}`) — the shape
/// `encode_try_operator` / `encode_unwrap` already expect.
fn assert_ok_wrapped(expr: &Expression) -> &Expression {
    let Some(Expr::MessageCreation(message)) = expr.expr.as_ref() else {
        panic!("a `write!` must encode as the unified `Ok(..)` outcome message, got {expr:?}");
    };
    assert_eq!(
        message.type_name, "Result",
        "the outcome message must be the encoder's unified `Result` shape"
    );
    let is_err = message
        .fields
        .iter()
        .find(|f| f.name == "is_err")
        .expect("an outcome message carries `is_err`");
    assert_eq!(
        is_err.value.as_ref().unwrap().expr,
        Some(Expr::Literal(ball_lang_shared::proto::ball::v1::Literal {
            value: Some(ball_lang_shared::proto::ball::v1::literal::Value::BoolValue(false)),
        })),
        "`write!` is the success outcome"
    );
    message
        .fields
        .iter()
        .find(|f| f.name == "value")
        .expect("an outcome message carries `value`")
        .value
        .as_ref()
        .expect("a field carries a value")
}

/// The tail (result) expression of the named `main`-module function's body.
fn tail_of<'a>(program: &'a Program, function: &str) -> &'a Expression {
    let main = module(program, "main");
    let def = main
        .functions
        .iter()
        .find(|f| f.name == function)
        .unwrap_or_else(|| panic!("no function `{function}`"));
    let body = def.body.as_ref().expect("a body");
    let Some(Expr::Block(block)) = body.expr.as_ref() else {
        panic!("a fn body encodes as a block");
    };
    block.result.as_ref().expect("a block result")
}

// ════════════════════════════════════════════════════════════
// (i) a `&mut fmt::Formatter` parameter — 22 of the corpus' 25 sites
// ════════════════════════════════════════════════════════════

#[test]
fn write_to_a_formatter_parameter_encodes_as_sink_write() {
    const SOURCE: &str = r#"
pub fn dash(f: &mut fmt::Formatter) -> fmt::Result {
    write!(f, "-")
}
"#;
    let program = encode_library(SOURCE);
    let call = only_std_call(&program, "dash", "sink_write");
    assert_eq!(
        field(call, "sink").expr,
        reference_to("f"),
        "the FIRST argument of `write!` is the sink, by `core`'s own definition"
    );
    assert_eq!(text_pieces(field(call, "text")), vec!["-".to_string()]);
}

#[test]
fn a_borrowed_formatter_reaches_the_same_sink() {
    const SOURCE: &str = r#"
pub fn dash(f: &mut fmt::Formatter) -> fmt::Result {
    write!(&mut f, "-")
}
"#;
    let program = encode_library(SOURCE);
    let call = only_std_call(&program, "dash", "sink_write");
    assert_eq!(
        field(call, "sink").expr,
        reference_to("f"),
        "`&mut f` and `f` name the same sink"
    );
}

#[test]
fn write_with_placeholders_builds_the_same_text_format_does() {
    const SOURCE: &str = r#"
pub fn render(f: &mut fmt::Formatter, value: i64) -> fmt::Result {
    write!(f, "n={}!", value)
}
"#;
    let program = encode_library(SOURCE);
    let call = only_std_call(&program, "render", "sink_write");
    assert_eq!(
        text_pieces(field(call, "text")),
        vec!["n=".to_string(), "<to_string>".to_string(), "!".to_string()],
        "the text argument reuses `format!`'s own lowering, unchanged"
    );
}

#[test]
fn a_write_is_wrapped_in_the_ok_outcome() {
    const SOURCE: &str = r#"
pub fn dash(f: &mut fmt::Formatter) -> fmt::Result {
    write!(f, "-")
}
"#;
    let program = encode_library(SOURCE);
    let value = assert_ok_wrapped(tail_of(&program, "dash"));
    let Some(Expr::Call(call)) = value.expr.as_ref() else {
        panic!("the outcome's value is the sink_write call itself, got {value:?}");
    };
    assert_eq!(
        (call.module.as_str(), call.function.as_str()),
        ("std", "sink_write")
    );
}

#[test]
fn a_write_consumed_by_the_question_mark_operator_encodes() {
    // The shape 22 of the 25 corpus sites use. `?` only works against the
    // unified outcome message, which is why the `Ok(..)` wrap is not cosmetic.
    const SOURCE: &str = r#"
pub fn dash(f: &mut fmt::Formatter) -> fmt::Result {
    write!(f, "-")?;
    write!(f, "-")
}
"#;
    let program = encode_library(SOURCE);
    assert_eq!(
        count_std_calls(&program, "dash", "sink_write"),
        2,
        "both `write!`s encode; the `?` wraps the first"
    );
}

// ════════════════════════════════════════════════════════════
// (ii) an UNANNOTATED closure parameter — the `heck` shape,
//      6 of the 7 first-blocked Tier A files
// ════════════════════════════════════════════════════════════

#[test]
fn write_to_an_unannotated_closure_parameter_encodes_as_sink_write() {
    const SOURCE: &str = r#"
pub fn dashed(f: &mut fmt::Formatter) -> fmt::Result {
    let render = |f| write!(f, "-");
    render(f)
}
"#;
    let program = encode_library(SOURCE);
    let call = only_std_call(&program, "dashed", "sink_write");
    assert_eq!(
        field(call, "sink").expr,
        reference_to("f"),
        "a closure parameter with no type annotation is still the sink — no inference needed"
    );
}

// ════════════════════════════════════════════════════════════
// (iii) `writeln!` = `write!` + "\n" — `core`'s own rule
// ════════════════════════════════════════════════════════════

#[test]
fn writeln_appends_a_newline() {
    const SOURCE: &str = r#"
pub fn line(f: &mut fmt::Formatter) -> fmt::Result {
    writeln!(f, "x")
}
"#;
    let program = encode_library(SOURCE);
    let call = only_std_call(&program, "line", "sink_write");
    assert_eq!(
        text_pieces(field(call, "text")),
        vec!["x".to_string(), "\n".to_string()]
    );
}

#[test]
fn writeln_with_no_arguments_writes_just_a_newline() {
    const SOURCE: &str = r#"
pub fn blank(f: &mut fmt::Formatter) -> fmt::Result {
    writeln!(f)
}
"#;
    let program = encode_library(SOURCE);
    let call = only_std_call(&program, "blank", "sink_write");
    assert_eq!(
        text_pieces(field(call, "text")),
        vec!["\n".to_string()],
        "`core` defines `writeln!($dst)` as literally `write!($dst, \"\\n\")`"
    );
}

// ════════════════════════════════════════════════════════════
// (iv) the JOIN-SITES case — a provably-local `String` that is ALSO
//      read back as a `String` in the same function (`itertools::join`)
// ════════════════════════════════════════════════════════════

#[test]
fn write_into_a_local_string_re_assigns_it_instead_of_making_it_a_sink() {
    // `itertools/lib.rs::join`'s shape: `result` accumulates through `write!`,
    // is ALSO read as a `String` (its length is tested) and is the function's
    // `String` return value. Encoding it as an opaque sink would silently
    // change both of those reads.
    const SOURCE: &str = r#"
pub fn join(sep: &str, value: i64) -> String {
    let mut result = String::with_capacity(16);
    write!(&mut result, "{}", value).unwrap();
    if result.is_empty() {
        return String::from(sep);
    }
    result
}
"#;
    let program = encode_library(SOURCE);
    assert_eq!(
        count_std_calls(&program, "join", "sink_write"),
        0,
        "a provably-local `String` is NOT a sink — it stays a `String`"
    );
    let assign = only_std_call(&program, "join", "assign");
    assert_eq!(field(assign, "target").expr, reference_to("result"));
    assert_eq!(
        text_pieces(field(assign, "value")),
        vec!["<ref result>".to_string(), "<to_string>".to_string()],
        "the local is re-assigned to `concat(result, <text>)`"
    );
    assert_eq!(
        count_std_calls(&program, "join", "length"),
        1,
        "the non-sink read of the same local must survive untouched"
    );
}

#[test]
fn every_string_constructor_initialiser_is_recognised_as_a_local_string() {
    for initialiser in [
        "String::new()",
        "String::with_capacity(8)",
        "String::from(\"seed\")",
        "\"seed\".to_string()",
        "\"seed\".to_owned()",
        "format!(\"seed\")",
    ] {
        let source = format!(
            r#"
pub fn build() -> String {{
    let mut out = {initialiser};
    write!(&mut out, "x").unwrap();
    out
}}
"#
        );
        let program = encode_library(&source);
        assert_eq!(
            count_std_calls(&program, "build", "sink_write"),
            0,
            "`{initialiser}` makes `out` a local String, not a sink"
        );
        let assign = only_std_call(&program, "build", "assign");
        assert_eq!(field(assign, "target").expr, reference_to("out"));
    }
}

#[test]
fn string_new_and_with_capacity_encode_as_the_empty_string() {
    // The enabler arm (a) needs: both were in the encoder's "unsupported call
    // target" bucket, so a `let mut s = String::new();` could not be encoded
    // at all — the local-`String` arm would have been unreachable. Capacity is
    // an allocation hint with no observable effect, so both are `""`.
    const SOURCE: &str = r#"
pub fn empties() -> String {
    let a = String::new();
    let b = String::with_capacity(32);
    a + &b
}
"#;
    let program = encode_library(SOURCE);
    let main = module(&program, "main");
    let def = main
        .functions
        .iter()
        .find(|f| f.name == "empties")
        .expect("`empties`");
    let Some(Expr::Block(block)) = def.body.as_ref().expect("a body").expr.as_ref() else {
        panic!("a fn body encodes as a block");
    };
    for statement in &block.statements {
        let Some(Stmt::Let(binding)) = statement.stmt.as_ref() else {
            panic!("both statements are `let` bindings");
        };
        assert_eq!(
            binding.value.as_ref().unwrap().expr,
            Some(Expr::Literal(ball_lang_shared::proto::ball::v1::Literal {
                value: Some(
                    ball_lang_shared::proto::ball::v1::literal::Value::StringValue(String::new())
                ),
            })),
            "`{}` must encode as the empty string",
            binding.name
        );
    }
}

#[test]
fn a_closure_parameter_shadows_an_enclosing_local_string() {
    // The shadowing trap: an enclosing local `String` named `f` must not make
    // a closure's own `f` parameter look like a local String, and vice versa.
    const SOURCE: &str = r#"
pub fn shadowed() -> String {
    let mut f = String::new();
    let render = |f| write!(f, "-");
    write!(&mut f, "x").unwrap();
    f
}
"#;
    let program = encode_library(SOURCE);
    assert_eq!(
        count_std_calls(&program, "shadowed", "sink_write"),
        1,
        "the closure's own parameter is a sink"
    );
    let assign = only_std_call(&program, "shadowed", "assign");
    assert_eq!(
        field(assign, "target").expr,
        reference_to("f"),
        "the enclosing local `String` is still re-assigned, not written through a sink"
    );
}

// ════════════════════════════════════════════════════════════
// block scoping — an inner `let` dies at its closing brace
// ════════════════════════════════════════════════════════════

#[test]
fn a_string_let_inside_a_nested_block_does_not_outlive_it() {
    // Rust's own rule: the inner `f` is gone at the closing brace, so the
    // `write!` below names the PARAMETER. A binding frame that is only
    // per-function leaks that inner `let` past its scope and re-assigns a
    // `String` that is not in scope any more — a SILENT miscompile, exactly
    // the class `Encoder::local_scopes` exists to prevent.
    const SOURCE: &str = r#"
pub fn dash(f: &mut fmt::Formatter) -> fmt::Result {
    {
        let f = String::from("scratch");
        println!("{}", f);
    }
    write!(f, "-")
}
"#;
    let program = encode_library(SOURCE);
    let call = only_std_call(&program, "dash", "sink_write");
    assert_eq!(
        field(call, "sink").expr,
        reference_to("f"),
        "the inner block's `let f` is out of scope; `f` here is the sink parameter"
    );
    assert_eq!(
        count_std_calls(&program, "dash", "assign"),
        0,
        "nothing is re-assigned — there is no local `String` in scope at the `write!`"
    );
}

#[test]
fn a_non_string_let_inside_a_nested_block_does_not_refuse_an_outer_sink() {
    // The same leak in its loud direction: if the inner `let out` survived
    // its block, the `write!` below would be refused as "a local whose
    // initialiser is not a `String` constructor" — a false refusal of a
    // perfectly ordinary sink parameter.
    const SOURCE: &str = r#"
pub fn dash(out: &mut fmt::Formatter) -> fmt::Result {
    {
        let out = 1;
        println!("{}", out);
    }
    write!(out, "-")
}
"#;
    let program = encode_library(SOURCE);
    let call = only_std_call(&program, "dash", "sink_write");
    assert_eq!(field(call, "sink").expr, reference_to("out"));
}

// ════════════════════════════════════════════════════════════
// `&mut` alias bindings (issue #642) as a `write!` destination
// ════════════════════════════════════════════════════════════

#[test]
fn a_write_through_a_mut_alias_re_assigns_the_local_string_it_borrows() {
    // `let slot = &mut result;` is an ALIAS binding: issue #642's rule records
    // it and emits no `let` at all, because Ball has no references — every
    // later READ of `slot` resolves to `result` (`lib.rs::encode_path_expr`).
    // A `write!` destination is a read like any other, so this must take the
    // same arm `write!(&mut result, ..)` takes: a re-assignment of the local
    // `String`. Classifying the alias NAME instead leaves it unrecorded in
    // `local_scopes`, which reads as "not a local" and emits `std.sink_write`
    // against a plain `String` — a value every engine and runtime rejects at
    // run time (`rust/shared/src/runtime.rs::sink_backing` panics), turning an
    // encode-time answer into a run-time failure.
    const SOURCE: &str = r#"
pub fn join(value: i64) -> String {
    let mut result = String::new();
    let slot = &mut result;
    write!(slot, "{}", value).unwrap();
    result
}
"#;
    let program = encode_library(SOURCE);
    assert_eq!(
        count_std_calls(&program, "join", "sink_write"),
        0,
        "an alias of a provably-local `String` IS that `String`, not a sink"
    );
    let assign = only_std_call(&program, "join", "assign");
    assert_eq!(
        field(assign, "target").expr,
        reference_to("result"),
        "the re-assignment names the BORROWED variable, never the alias"
    );
    assert_eq!(
        text_pieces(field(assign, "value")),
        vec!["<ref result>".to_string(), "<to_string>".to_string()],
    );
}

#[test]
fn a_write_through_a_mut_alias_of_a_sink_parameter_stays_a_sink_write() {
    // The same resolution in its other direction: the alias borrows a sink
    // PARAMETER, so the write stays `std.sink_write` — and names the
    // parameter, the only binding the encoded program has.
    const SOURCE: &str = r#"
pub fn dash(f: &mut fmt::Formatter) -> fmt::Result {
    let out = &mut f;
    write!(out, "-")
}
"#;
    let program = encode_library(SOURCE);
    let call = only_std_call(&program, "dash", "sink_write");
    assert_eq!(
        field(call, "sink").expr,
        reference_to("f"),
        "the alias resolves to the sink parameter it borrows"
    );
    assert_eq!(
        count_std_calls(&program, "dash", "assign"),
        0,
        "a parameter is never re-assigned in place"
    );
}

// ════════════════════════════════════════════════════════════
// (v) a local of some OTHER type — a loud panic, never a guess
// ════════════════════════════════════════════════════════════

const NON_STRING_LOCAL: &str = r#"
pub fn build() -> Vec<u8> {
    let mut out = vec![];
    write!(&mut out, "x").unwrap();
    out
}
"#;

#[test]
#[should_panic(expected = "`out`")]
fn write_into_a_local_that_is_not_a_string_names_the_local() {
    encode_library(NON_STRING_LOCAL);
}

#[test]
#[should_panic(expected = "is not a `String` constructor")]
fn write_into_a_local_that_is_not_a_string_says_why() {
    encode_library(NON_STRING_LOCAL);
}

#[test]
#[should_panic(expected = "requires a destination")]
fn write_with_no_arguments_fails_loud() {
    const SOURCE: &str = r#"
pub fn broken(f: &mut fmt::Formatter) -> fmt::Result {
    write!()
}
"#;
    encode_library(SOURCE);
}

// ════════════════════════════════════════════════════════════
// (vi) compile-back — encode -> compile_library -> real `cargo build`
// ════════════════════════════════════════════════════════════

/// Tier A's stage 2 ("compiled back") for the sink arm: the encoded `Program`
/// must compile to Rust that `cargo` accepts as a library, calling the
/// runtime sink helper #636 landed.
///
/// Deliberately NOT asserted here: a *re-encode* of that compiled output
/// (Tier A's stage 3). Every `MessageCreation` — which the unified `Ok(..)`
/// outcome is, and which a plain `Ok(x)` in hand-written source has always
/// been — compiles to `{ let mut __ball_map = BallMap::new(); ... }`, and
/// `BallMap::new()` is an associated function on a foreign type, which
/// `rust/encoder/src/lib.rs` documents as a permanent gap. That is a
/// pre-existing round-trip-closure defect of exactly issue #632's class (the
/// Rust compiler emitting a construct its own encoder cannot read back), it
/// predates this work, and folding a fix for it into #630 would hide it.
#[test]
fn a_sink_write_compiles_back_into_a_real_rust_library() {
    const SOURCE: &str = r#"
pub fn dash(f: &mut fmt::Formatter) -> fmt::Result {
    write!(f, "-")
}

pub fn line(f: &mut fmt::Formatter, value: i64) -> fmt::Result {
    writeln!(f, "n={}", value)
}
"#;
    let program = encode_library(SOURCE);
    let rust_source = Compiler::new(&program).compile_library();
    assert!(
        rust_source.contains("ball_sink_write"),
        "the compiled library must call the runtime sink helper (#636), got:\n{rust_source}"
    );
    harness::compile_as_library("write_sinks_lib", &rust_source);
}

// ════════════════════════════════════════════════════════════
// arm (a), end to end: a local-String `write!` really runs
// ════════════════════════════════════════════════════════════

#[test]
fn a_local_string_write_compiles_and_runs() {
    const SOURCE: &str = r#"
fn main() {
    let mut s = String::with_capacity(8);
    write!(&mut s, "a").unwrap();
    write!(&mut s, "{}", 7).unwrap();
    writeln!(&mut s, "!").unwrap();
    println!("{}", s);
}
"#;
    let program = encode(SOURCE);
    let rust_source = Compiler::new(&program).compile();
    assert!(
        !rust_source.contains("ball_sink_write"),
        "arm (a) must not reach the sink runtime:\n{rust_source}"
    );
    assert_eq!(
        harness::compile_and_run("write_sinks_local", &rust_source),
        "a7!\n\n"
    );
}

mod harness {
    use std::fs;
    use std::path::PathBuf;
    use std::process::Command;
    use std::sync::atomic::{AtomicU64, Ordering};

    static FIXTURE_COUNTER: AtomicU64 = AtomicU64::new(0);

    fn workspace_root() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("rust/encoder must have a parent directory")
            .to_path_buf()
    }

    /// Build and run `rust_src` in a scratch cargo package — the same harness
    /// `end_to_end.rs`/`method_sugar.rs` use.
    pub fn compile_and_run(fixture_name: &str, rust_src: &str) -> String {
        let workspace_root = workspace_root();
        let target_dir = workspace_root.join("target");
        let unique = FIXTURE_COUNTER.fetch_add(1, Ordering::Relaxed);
        let slug = format!("{fixture_name}_{}_{unique}", std::process::id());
        let fixture_dir = std::env::temp_dir().join(format!("ball_encoder_fixture_{slug}"));
        fs::create_dir_all(&fixture_dir).unwrap_or_else(|err| {
            panic!(
                "failed to create fixture dir {}: {err}",
                fixture_dir.display()
            )
        });

        let shared_path = workspace_root.join("shared");
        let bin_name = format!("ball_encoder_fixture_{slug}");
        let manifest = format!(
            "[package]\nname = \"{bin_name}\"\nversion = \"0.0.0\"\nedition = \"2024\"\npublish = false\n\n\
             [[bin]]\nname = \"{bin_name}\"\npath = \"main.rs\"\n\n\
             [dependencies]\nball-lang-shared = {{ path = {:?} }}\n",
            shared_path
        );
        fs::write(fixture_dir.join("Cargo.toml"), manifest).expect("write Cargo.toml");
        fs::write(fixture_dir.join("main.rs"), rust_src).expect("write main.rs");

        let output = Command::new(env!("CARGO"))
            .current_dir(&fixture_dir)
            .env("CARGO_TARGET_DIR", &target_dir)
            .args(["run", "--quiet", "--bin", &bin_name])
            .output()
            .expect("cargo run");
        let _ = fs::remove_dir_all(&fixture_dir);
        assert!(
            output.status.success(),
            "compiled program failed to build/run:\n{}\n--- source ---\n{rust_src}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout)
            .expect("stdout is utf-8")
            .replace("\r\n", "\n")
    }

    /// Build `rust_src` as a **library** crate in a scratch cargo package —
    /// the same harness `library_mode.rs` uses. A library has nothing to run;
    /// the proof is that `cargo` accepts the compiled output.
    pub fn compile_as_library(fixture_name: &str, rust_src: &str) {
        let workspace_root = workspace_root();
        let target_dir = workspace_root.join("target");
        let unique = FIXTURE_COUNTER.fetch_add(1, Ordering::Relaxed);
        let slug = format!("{fixture_name}_{}_{unique}", std::process::id());
        let fixture_dir = std::env::temp_dir().join(format!("ball_encoder_lib_fixture_{slug}"));
        fs::create_dir_all(&fixture_dir).unwrap_or_else(|err| {
            panic!(
                "failed to create fixture dir {}: {err}",
                fixture_dir.display()
            )
        });

        let shared_path = workspace_root.join("shared");
        let lib_name = format!("ball_encoder_lib_fixture_{slug}");
        let manifest = format!(
            "[package]\nname = \"{lib_name}\"\nversion = \"0.0.0\"\nedition = \"2024\"\npublish = false\n\n\
             [lib]\nname = \"{lib_name}\"\npath = \"lib.rs\"\n\n\
             [dependencies]\nball-lang-shared = {{ path = {:?} }}\n",
            shared_path
        );
        fs::write(fixture_dir.join("Cargo.toml"), manifest).expect("write Cargo.toml");
        fs::write(fixture_dir.join("lib.rs"), rust_src).expect("write lib.rs");

        let output = Command::new(env!("CARGO"))
            .current_dir(&fixture_dir)
            .env("CARGO_TARGET_DIR", &target_dir)
            .args(["build", "--quiet", "--lib"])
            .output()
            .expect("cargo build");
        let _ = fs::remove_dir_all(&fixture_dir);
        assert!(
            output.status.success(),
            "the compiled library failed to build:\n{}\n--- source ---\n{rust_src}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
}
