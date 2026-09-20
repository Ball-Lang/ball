//! A `&mut` borrow this encoder cannot model must be REFUSED at the first
//! **write** through it — never silently encoded as a write to a copy
//! (issue #693).
//!
//! ## The defect class
//!
//! Ball has no references. A Rust `let` of a `&mut` borrow therefore has no
//! Ball counterpart: encoding `let s = &mut place;` as an ordinary binding
//! makes it a **copy**, and every later `*s = …` lands on that copy while the
//! borrowed place never changes.
//!
//! That is strictly worse than a refusal: the emitted `Program` is
//! structurally valid, `ball check` accepts it, and the only symptom is that
//! the program computes something else — or, when the borrowed place is a loop
//! counter, never terminates. Measured on run 34755669293: **28 of the
//! corpus's loop fixtures re-encoded "clean" and then hung** on the Dart
//! reference engine, each killed by the round-trip leg's 60-second per-fixture
//! budget. Every one of them was a loop fixture; no non-loop fixture timed out.
//!
//! ## What is modelled, and what is refused
//!
//! `block.rs` models exactly one shape: a borrow of a **plain named variable**
//! (`let s: &mut T = &mut i;`), recorded as an alias so a read of `s` resolves
//! back to `i` and a write through it targets `i`. That is #646's fix, pinned
//! by `compiler_output.rs`'s
//! `mutation_through_a_mut_alias_targets_the_borrowed_variable` and by
//! `a_write_through_a_mut_alias_of_a_plain_variable_is_still_modelled` below.
//!
//! A `&mut` borrow of anything else — a field (`&mut p.x`), an index
//! (`&mut v[0]`), a call result — is a place this encoder cannot resolve. It is
//! still encoded as a value, which is CORRECT for a read (a read of a borrow
//! and a read of a copy give the same answer) and WRONG for a write. So the
//! read keeps working and the write is refused, loudly, naming the place.
//!
//! The wider reference-semantics gap — a `&mut` handed to a callee
//! (`f(&mut x)`), whose mutation this encoder also cannot carry — is a
//! different mechanism and is tracked with the rest of the Rust round-trip gap
//! in issue #692.

use std::panic::{self, AssertUnwindSafe};

use ball_lang_shared::proto::ball::v1::expression::Expr;
use ball_lang_shared::proto::ball::v1::statement::Stmt;
use ball_lang_shared::proto::ball::v1::{Expression, Program};

/// Encode `source`, expecting the encoder to REFUSE it, and return the
/// fail-loud message. A successful encode is the failure: it means the write
/// was silently absorbed.
fn refusal_message(source: &str) -> String {
    let previous_hook = panic::take_hook();
    panic::set_hook(Box::new(|_| {}));
    let result = panic::catch_unwind(AssertUnwindSafe(|| ball_lang_encoder::encode(source)));
    panic::set_hook(previous_hook);

    match result {
        Ok(program) => panic!(
            "the encoder ACCEPTED a write through a `&mut` borrow it cannot model — the write is \
             silently lost and the program computes something else (issue #693). Encoded: \
             {program:?}"
        ),
        Err(payload) => {
            if let Some(s) = (*payload).downcast_ref::<&str>() {
                (*s).to_string()
            } else if let Some(s) = (*payload).downcast_ref::<String>() {
                s.clone()
            } else {
                panic!(
                    "the encoder panicked without a string payload — a refusal must NAME the place \
                     it refused"
                )
            }
        }
    }
}

/// Every refusal must name the alias, the borrowed place, and the issue that
/// tracks the wider gap — a bare "unsupported" tells the reader nothing about
/// which line to change.
fn assert_names_the_place(message: &str, alias: &str, place_fragment: &str) {
    for needle in [alias, place_fragment, "#692"] {
        assert!(
            message.contains(needle),
            "the refusal must mention `{needle}`, got: {message}"
        );
    }
}

// ── The refusals ────────────────────────────────────────────────────────────

/// `let s = &mut p.field; *s = …;` — the write must reach `p.field`, and this
/// encoder cannot express that, so it must refuse rather than write to a copy.
#[test]
fn a_write_through_a_mut_borrow_of_a_field_is_refused_not_silently_lost() {
    let message = refusal_message(
        "fn main() { let mut p = make(); let s = &mut p.field; *s = BallValue::Int(5i64); \
         println!(\"{}\", p); } \
         fn make() -> i64 { 1 }",
    );
    assert_names_the_place(&message, "s", "p . field");
}

/// The same for an INDEX place: `let s = &mut v[0]; *s = …;`.
#[test]
fn a_write_through_a_mut_borrow_of_an_index_is_refused_not_silently_lost() {
    let message = refusal_message(
        "fn main() { let mut v = make(); let s = &mut v[0]; *s = BallValue::Int(5i64); \
         println!(\"{}\", v); } \
         fn make() -> i64 { 1 }",
    );
    assert_names_the_place(&message, "s", "v [0]");
}

/// A COMPOUND write (`*s += 1`) is the same lost write — `encode_assign` is the
/// single choke point for both, and this pins that it really is.
#[test]
fn a_compound_write_through_a_mut_borrow_of_a_field_is_refused_too() {
    let message = refusal_message(
        "fn main() { let mut p = make(); let s = &mut p.field; *s += BallValue::Int(1i64); \
         println!(\"{}\", p); } \
         fn make() -> i64 { 1 }",
    );
    assert_names_the_place(&message, "s", "p . field");
}

/// A write to a FIELD OF the alias (`s.inner = …`) lands on the same borrowed
/// place and is just as lost — the refusal must look through the projection to
/// the root the write is rooted at, not only at a bare `*s`.
#[test]
fn a_write_to_a_field_of_a_mut_borrow_is_refused_too() {
    let message = refusal_message(
        "fn main() { let mut p = make(); let s = &mut p.field; s.inner = BallValue::Int(5i64); \
         println!(\"{}\", p); } \
         fn make() -> i64 { 1 }",
    );
    assert_names_the_place(&message, "s", "p . field");
}

// ── The controls: the refusal must stay NARROW ──────────────────────────────

/// A READ through an unmodellable `&mut` borrow is still encoded. A read of a
/// borrow and a read of a copy give the same answer, so there is nothing to
/// refuse — and refusing it would reject a large amount of ordinary Rust for no
/// correctness gain. (This is the shape `compiler_output.rs`'s
/// `a_borrow_of_a_non_variable_place_is_not_treated_as_an_alias` pins.)
#[test]
fn a_read_only_mut_borrow_of_a_field_still_encodes() {
    let program = ball_lang_encoder::encode(
        "fn main() { let p = make(); let s = &mut p.field; println!(\"{}\", s); } \
         fn make() -> i64 { 1 }",
    );
    assert!(
        declared_let_names(&program).iter().any(|n| n == "s"),
        "a read-only `&mut <field>` binding must still be emitted: {:?}",
        declared_let_names(&program)
    );
}

/// A SHARED borrow (`&p.field`) can never be written through in Rust at all, so
/// it is never refused.
#[test]
fn a_shared_borrow_of_a_field_still_encodes() {
    let program = ball_lang_encoder::encode(
        "fn main() { let p = make(); let s = &p.field; println!(\"{}\", s); } \
         fn make() -> i64 { 1 }",
    );
    assert!(
        declared_let_names(&program).iter().any(|n| n == "s"),
        "a shared `&<field>` binding must still be emitted: {:?}",
        declared_let_names(&program)
    );
}

/// The modelled shape keeps working: a `&mut` alias of a plain VARIABLE
/// resolves its write back to that variable, emits no binding of its own, and
/// is never refused. This is #646's fix; pinning it here means a change to the
/// refusal above cannot quietly swallow the one case that IS handled.
#[test]
fn a_write_through_a_mut_alias_of_a_plain_variable_is_still_modelled() {
    let program = ball_lang_encoder::encode(
        "fn main() { let mut i = BallValue::Int(0i64); let s: &mut BallValue = (&mut i); \
         *s = BallValue::Int(5i64); println!(\"{}\", i); }",
    );
    assert!(
        !declared_let_names(&program).iter().any(|n| n == "s"),
        "the `&mut` alias of a plain variable must not be emitted as a value binding: {:?}",
        declared_let_names(&program)
    );
    let targets = assign_targets(&program);
    assert_eq!(
        targets,
        vec!["i".to_string()],
        "the write must target the borrowed variable: {targets:?}"
    );
}

/// A later `let` of the same name SHADOWS the unmodellable borrow, exactly as
/// it shadows a modelled alias — after `let mut s = 9;` a write to `s` is an
/// ordinary write to an ordinary binding and must not be refused.
#[test]
fn a_later_let_of_the_same_name_shadows_the_unmodellable_borrow() {
    let program = ball_lang_encoder::encode(
        "fn main() { let mut p = make(); let s = &mut p.field; let mut s = BallValue::Int(9i64); \
         s = BallValue::Int(5i64); println!(\"{}\", s); } \
         fn make() -> i64 { 1 }",
    );
    let targets = assign_targets(&program);
    assert_eq!(
        targets,
        vec!["s".to_string()],
        "the write targets the shadowing binding, not the shadowed borrow: {targets:?}"
    );
}

// ── Tree walkers ────────────────────────────────────────────────────────────
// The same shapes `compiler_output.rs` uses; each cargo integration test is its
// own crate, so there is nothing to share between them.

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
        Some(Expr::Lambda(lambda)) => {
            if let Some(body) = &lambda.body {
                collect_let_names(body, out);
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

/// The `target` of every `std.assign` call, as a bare reference name.
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
        Some(Expr::Lambda(lambda)) => {
            if let Some(body) = &lambda.body {
                collect_assign_targets(body, out);
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
