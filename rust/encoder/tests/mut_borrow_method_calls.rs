//! A **mutating METHOD CALL** through a `&mut` borrow this encoder cannot
//! model must be REFUSED — never silently encoded as a mutation of the copy
//! (issue #775).
//!
//! ## The defect class, one reach further than #693
//!
//! `mut_borrow_writes.rs` (issue #693) pins the ASSIGNMENT half: `let s = &mut
//! v[0]; *s = …;` is refused, because Ball has no references, so `s` encodes as
//! a COPY of `v[0]` and the write lands on the copy while `v[0]` never changes
//! — a structurally valid, `ball check`-clean `Program` that computes something
//! else.
//!
//! `s.push(x)` is the SAME lost write reached through `.method(…)` instead of
//! `=`. `encode_method_call`'s `"push"` arm encodes it as
//! `std_collections.list_push(list: <receiver>, value: x)`, and
//! `std_collections.list_push` mutates its `list` argument IN PLACE
//! (`dart/engine/lib/engine_std.dart`'s `list_push`: `list.add(m['value'])`).
//! With an `AliasTarget::Opaque` receiver that argument is the emitted copy, so
//! the element the Rust appends to is not the one the program then reads.
//!
//! ## What is covered, and what stays out of scope
//!
//! The guard fires for exactly the built-in arms whose encoding mutates the
//! RECEIVER in place — `RECEIVER_MUTATING_METHODS` in `src/methods.rs`, kept in
//! agreement with the arm table itself by that file's own
//! `every_built_in_method_arm_is_classified` unit test. Every other built-in
//! arm produces a NEW value from the receiver, so it is a read, and a read of a
//! borrow and a read of a copy give the same answer — those keep encoding,
//! exactly as `mut_borrow_writes.rs`'s read-only control requires.
//!
//! A USER-DECLARED instance method is deliberately not covered here: the
//! receiver is packed as a `"self"` field and `rust/compiler`'s
//! `type_emit.rs::method_prologue` extracts it from `input.clone()`, so no
//! instance method observably mutates its receiver on ANY receiver, aliased or
//! not — the boundary `types.rs`'s module doc comment already records, tracked
//! with the rest of the reference-semantics gap in issue #692.

use std::panic::{self, AssertUnwindSafe};

use ball_lang_shared::proto::ball::v1::expression::Expr;
use ball_lang_shared::proto::ball::v1::statement::Stmt;
use ball_lang_shared::proto::ball::v1::{Expression, Program};

/// Encode `source`, expecting the encoder to REFUSE it, and return the
/// fail-loud message. A successful encode is the failure: it means the
/// mutation was silently redirected onto the copy.
fn refusal_message(source: &str) -> String {
    let previous_hook = panic::take_hook();
    panic::set_hook(Box::new(|_| {}));
    let result = panic::catch_unwind(AssertUnwindSafe(|| ball_lang_encoder::encode(source)));
    panic::set_hook(previous_hook);

    match result {
        Ok(program) => panic!(
            "the encoder ACCEPTED a MUTATING METHOD CALL through a `&mut` borrow it cannot model \
             — `std_collections.list_push` mutates the emitted COPY and the borrowed place never \
             changes, so the program type-checks and computes something else (issue #775). \
             Receivers of the emitted `list_push` calls: {:?}",
            list_push_receivers(&program)
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

/// Every refusal must name the alias, the borrowed place, the METHOD that
/// reached it, and the issue that tracks the wider gap.
fn assert_names_the_place(message: &str, alias: &str, place_fragment: &str, method: &str) {
    for needle in [alias, place_fragment, method, "#692"] {
        assert!(
            message.contains(needle),
            "the refusal must mention `{needle}`, got: {message}"
        );
    }
}

// ── The refusals ────────────────────────────────────────────────────────────

/// `let s = &mut v[0]; s.push(…);` — the append must reach `v[0]`, and this
/// encoder cannot express that, so it must refuse rather than append to a copy.
#[test]
fn a_mutating_method_call_through_a_mut_borrow_of_an_index_is_refused() {
    let message = refusal_message(
        "fn main() { let mut v = make(); let s = &mut v[0]; s.push(9i64); \
         println!(\"{}\", v); } \
         fn make() -> i64 { 1 }",
    );
    assert_names_the_place(&message, "s", "v [0]", "push");
}

/// The same for a FIELD place: `let s = &mut p.items; s.push(…);`.
#[test]
fn a_mutating_method_call_through_a_mut_borrow_of_a_field_is_refused() {
    let message = refusal_message(
        "fn main() { let mut p = make(); let s = &mut p.items; s.push(9i64); \
         println!(\"{}\", p); } \
         fn make() -> i64 { 1 }",
    );
    assert_names_the_place(&message, "s", "p . items", "push");
}

/// A borrow of a variable that is ITSELF opaque inherits the opaqueness on the
/// method-call path too — `let a = &mut p.items; let b = &mut a; b.push(…);`
/// appends to the very same copy, so it is refused under the borrowed place's
/// name, exactly as the assignment path already does.
#[test]
fn a_mutating_method_call_through_an_inherited_opaque_alias_is_refused() {
    let message = refusal_message(
        "fn main() { let mut p = make(); let a = &mut p.items; let b = &mut a; b.push(9i64); \
         println!(\"{}\", p); } \
         fn make() -> i64 { 1 }",
    );
    assert_names_the_place(&message, "b", "p . items", "push");
}

// ── The controls: the refusal must stay NARROW ──────────────────────────────

/// A READ-ONLY method call through an unmodellable `&mut` borrow still
/// encodes. `.len()` produces a new value from the receiver, and a read of a
/// borrow and a read of a copy give the same answer, so there is nothing to
/// lose — refusing it would reject a large amount of ordinary Rust for no
/// correctness gain.
#[test]
fn a_read_only_method_call_through_an_unmodellable_borrow_still_encodes() {
    let program = ball_lang_encoder::encode(
        "fn main() { let p = make(); let s = &mut p.items; let n = s.len(); \
         println!(\"{}\", n); } \
         fn make() -> i64 { 1 }",
    );
    assert!(
        declared_let_names(&program).iter().any(|n| n == "s"),
        "a read-only method call on a `&mut <field>` binding must still encode: {:?}",
        declared_let_names(&program)
    );
}

/// The MODELLED shape keeps working: a `&mut` alias of a plain VARIABLE
/// resolves the receiver back to that variable, so the append targets the
/// borrowed variable and is never refused.
#[test]
fn a_mutating_method_call_through_a_modelled_alias_targets_the_borrowed_variable() {
    let program = ball_lang_encoder::encode(
        "fn main() { let mut v = make(); let s: &mut Vec<i64> = (&mut v); s.push(9i64); \
         println!(\"{}\", v); } \
         fn make() -> i64 { 1 }",
    );
    assert!(
        !declared_let_names(&program).iter().any(|n| n == "s"),
        "the `&mut` alias of a plain variable must not be emitted as a value binding: {:?}",
        declared_let_names(&program)
    );
    let receivers = list_push_receivers(&program);
    assert_eq!(
        receivers,
        vec!["v".to_string()],
        "the append must target the borrowed variable: {receivers:?}"
    );
}

/// A mutating method call on an ORDINARY binding — no borrow anywhere — is
/// untouched by the guard.
#[test]
fn a_mutating_method_call_on_an_ordinary_binding_still_encodes() {
    let program = ball_lang_encoder::encode(
        "fn main() { let mut v = make(); v.push(9i64); println!(\"{}\", v); } \
         fn make() -> i64 { 1 }",
    );
    let receivers = list_push_receivers(&program);
    assert_eq!(
        receivers,
        vec!["v".to_string()],
        "an ordinary receiver must still be encoded: {receivers:?}"
    );
}

/// A later `let` of the same name SHADOWS the unmodellable borrow on the
/// method-call path exactly as it does for a bare assignment — after
/// `let mut s = make();` an `s.push(…)` is an ordinary append to an ordinary
/// binding and must not be refused.
#[test]
fn a_later_let_of_the_same_name_shadows_the_unmodellable_borrow_for_method_calls() {
    let program = ball_lang_encoder::encode(
        "fn main() { let mut p = make(); let s = &mut p.items; let mut s = make(); \
         s.push(9i64); println!(\"{}\", s); } \
         fn make() -> i64 { 1 }",
    );
    let receivers = list_push_receivers(&program);
    assert_eq!(
        receivers,
        vec!["s".to_string()],
        "the append targets the shadowing binding, not the shadowed borrow: {receivers:?}"
    );
}

// ── Tree walkers ────────────────────────────────────────────────────────────
// The same shapes `mut_borrow_writes.rs` uses; each cargo integration test is
// its own crate, so there is nothing to share between them.

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

/// The `list` argument of every `std_collections.list_push` call, as a bare
/// reference name — i.e. which binding the append actually mutates.
fn list_push_receivers(program: &Program) -> Vec<String> {
    let mut found = Vec::new();
    for module in &program.modules {
        for function in &module.functions {
            if let Some(body) = &function.body {
                collect_list_push_receivers(body, &mut found);
            }
        }
    }
    found
}

fn collect_list_push_receivers(expr: &Expression, out: &mut Vec<String>) {
    match expr.expr.as_ref() {
        Some(Expr::Call(call)) => {
            if call.function == "list_push" {
                if let Some(input) = &call.input {
                    if let Some(Expr::MessageCreation(message)) = input.expr.as_ref() {
                        for field in &message.fields {
                            if field.name == "list" {
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
                collect_list_push_receivers(input, out);
            }
        }
        Some(Expr::Block(block)) => {
            for statement in &block.statements {
                match statement.stmt.as_ref() {
                    Some(Stmt::Expression(inner)) => collect_list_push_receivers(inner, out),
                    Some(Stmt::Let(binding)) => {
                        if let Some(value) = &binding.value {
                            collect_list_push_receivers(value, out);
                        }
                    }
                    _ => {}
                }
            }
            if let Some(result) = &block.result {
                collect_list_push_receivers(result, out);
            }
        }
        Some(Expr::Lambda(lambda)) => {
            if let Some(body) = &lambda.body {
                collect_list_push_receivers(body, out);
            }
        }
        Some(Expr::MessageCreation(message)) => {
            for field in &message.fields {
                if let Some(value) = &field.value {
                    collect_list_push_receivers(value, out);
                }
            }
        }
        _ => {}
    }
}
