//! Assignable-target ("lvalue") resolution — shared infrastructure for
//! `assign`/`pre_increment`/`post_increment`/`pre_decrement`/`post_decrement`
//! (see `base_call.rs`) and for the mutating `std_collections` calls
//! (`list_push`, `map_set`, ...) that need a real mutable handle onto an
//! already-bound variable rather than a `.clone()`d read.
//!
//! ## Why this exists (the aliasing problem)
//!
//! Every ordinary `reference` expression compiles to `<name>.clone()`
//! ([`Compiler::compile_reference`]) — correct for *reading* a value, but
//! insufficient for anything that must **mutate the variable the caller
//! already has a handle to** (a loop counter, a list a caller later reads
//! again, ...). Dart's reference compiler can get away with a bare
//! cascade (`list..add(value)`) because Dart `List`/`Map` are reference
//! types and a plain variable read already aliases the same underlying
//! object; Rust's `BallValue::List(Vec<BallValue>)` has no such aliasing —
//! `myList.clone()` is an independent copy, so `ball_list_push(myList.clone(),
//! value)` would silently mutate a throwaway clone instead of `myList`
//! itself. [`LValue`]/[`Compiler::resolve_lvalue`]/[`Compiler::lvalue_mut_expr`]
//! sidestep this by compiling the *target* of a mutation to a real
//! `&mut BallValue` Rust place expression instead of a cloned read.
//!
//! ## Scope
//!
//! Only **one level** of `field_access`/`index` nesting rooted at a bare
//! `reference` is supported (`obj.field = x`, `list[i] = x`) — matching what
//! every hand-built #37 fixture needs (loop counters, simple struct-shaped
//! state). Deeper chains (`a.b.c = x`) fall back to
//! [`LValue::Unsupported`], which compiles to a runtime panic (never a
//! silently-wrong mutation of a clone) — full lvalue-chain support is
//! `TypeDefinition`-driven struct field access, which is #38's scope.
use ball_shared::extract_fields;
use ball_shared::proto::ball::v1::Expression;
use ball_shared::proto::ball::v1::expression::Expr;
use ball_shared::proto::ball::v1::literal::Value as LiteralValue;
use ball_shared::proto::ball::v1::statement::Stmt;

use crate::Compiler;

/// A resolved assignment target, always rooted at a bare local `reference`.
pub(crate) enum LValue {
    /// Plain variable: `name = ...`.
    Var(String),
    /// `object.field = ...`, where `object` is itself a bare reference.
    Field { object_var: String, field: String },
    /// `target[index] = ...`, where `target` is itself a bare reference.
    Index {
        target_var: String,
        index_code: String,
    },
    /// Anything deeper/unrecognized — compiles to a runtime panic rather
    /// than silently mutating a clone. Carries a human-readable reason.
    Unsupported(String),
}

impl Compiler<'_> {
    /// Resolve an assignment/mutation target expression to an [`LValue`].
    pub(crate) fn resolve_lvalue(&self, target: &Expression) -> LValue {
        match &target.expr {
            Some(Expr::Reference(reference)) => LValue::Var(crate::sanitize_ident(&reference.name)),
            Some(Expr::FieldAccess(field_access)) => match field_access.object.as_deref() {
                Some(Expression {
                    expr: Some(Expr::Reference(reference)),
                }) => LValue::Field {
                    object_var: crate::sanitize_ident(&reference.name),
                    field: field_access.field.clone(),
                },
                _ => LValue::Unsupported(
                    "nested field-access assignment target (only obj.field, where obj is a \
                     plain variable, is supported — issue #38 covers deeper lvalue chains)"
                        .to_string(),
                ),
            },
            Some(Expr::Call(call))
                if call.function == "index" && self.is_base_module(&call.module) =>
            {
                let fields = extract_fields(call);
                match fields.get("target").map(|target_expr| &target_expr.expr) {
                    Some(Some(Expr::Reference(reference))) => LValue::Index {
                        target_var: crate::sanitize_ident(&reference.name),
                        index_code: fields
                            .get("index")
                            .map(|index_expr| self.compile_expression(index_expr))
                            .unwrap_or_else(|| "BallValue::Null".to_string()),
                    },
                    _ => LValue::Unsupported(
                        "nested index assignment target (only list[i], where list is a plain \
                         variable, is supported — issue #38 covers deeper lvalue chains)"
                            .to_string(),
                    ),
                }
            }
            _ => LValue::Unsupported(
                "assignment target is not a variable, field access, or index expression"
                    .to_string(),
            ),
        }
    }

    /// Compile [`LValue`] to a Rust expression of type `&mut BallValue` — the
    /// mutable "slot" every mutation (`assign`, increment/decrement, and the
    /// mutating `std_collections` calls) writes through.
    ///
    /// [`LValue::Unsupported`] compiles to a `panic!(...)` block; Rust's
    /// diverging `!` type unifies with `&mut BallValue` (or any other
    /// expected type), so callers never need to special-case it.
    pub(crate) fn lvalue_mut_expr(&self, lvalue: &LValue) -> String {
        match lvalue {
            LValue::Var(name) => format!("(&mut {name})"),
            LValue::Field { object_var, field } => {
                format!("ball_field_get_mut(&mut {object_var}, {field:?})")
            }
            LValue::Index {
                target_var,
                index_code,
            } => format!("ball_index_get_mut(&mut {target_var}, {index_code})"),
            LValue::Unsupported(reason) => {
                format!(
                    "panic!(\"ball-compiler runtime: {}\")",
                    escape_for_panic(reason)
                )
            }
        }
    }

    /// Compile a full mutation (`assign`/increment/decrement, or a mutating
    /// `std_collections` call's target): reads the current value through
    /// [`Self::lvalue_mut_expr`], combines it with `value_code` via `op`
    /// (`combine_op`), writes the result back through the same slot, and
    /// evaluates to either the new value or the pre-mutation old value
    /// (`want_old` — `post_increment`/`post_decrement`'s Dart semantics).
    ///
    /// `op` is one of `=`, `+=`, `-=`, `*=`, `/=`, `%=`, `&=`, `|=`, `^=`,
    /// `<<=`, `>>=`, `>>>=`, `??=` (mirrors `AssignInput.op` /
    /// `dart/compiler/lib/compiler.dart`'s `_compileAssign` switch).
    pub(crate) fn emit_mutation(
        &self,
        lvalue: &LValue,
        op: &str,
        value_code: &str,
        want_old: bool,
    ) -> String {
        let slot = self.lvalue_mut_expr(lvalue);
        // The right-hand value is bound to an owned temporary (`__val`)
        // *before* the mutable slot borrow is taken, so a `value_code` that
        // reads the same variable being assigned (`x = f(x)` → `x.clone()`
        // inside `value_code`) or even mutates it (`x = list_push(x, e)`,
        // where the collection helper needs its own `&mut x`) no longer
        // overlaps the `&mut` slot borrow. Without this sequencing the two
        // borrows of the one place are simultaneous and rustc rejects them
        // (E0499 "borrow more than once" / E0502 "immutable while mutable") —
        // the self-hosted engine hits this on `fieldNames = list_push(...)`,
        // `superObj = _asMap(superObj[...])`, `instance[__super__] = {...
        // instance ...}`, etc. Every compiled expression yields an owned
        // `BallValue`, so binding it first is always valid and changes no
        // semantics for the common `value_code` that doesn't touch the target.
        let new_value = combine_op(op, "__old.clone()", "__val");
        let tail = if want_old { "__old" } else { "__new" };
        format!(
            "{{ let __val = {value_code}; let __slot = {slot}; let __old = __slot.clone(); \
             let __new = {new_value}; *__slot = __new.clone(); {tail} }}"
        )
    }

    /// Does `expr` mutate the local variable `name` anywhere in its tree —
    /// directly (`assign`/increment targeting a bare reference to `name`) or
    /// through one level of field/index nesting rooted at `name`
    /// (`name.field = ...`, `name[i] = ...`) — including the mutating
    /// `std_collections` calls (`list_push(list: name, ...)`, ...)?
    ///
    /// Used by [`Compiler::compile_block`] to decide `let` vs `let mut` for
    /// each binding: over-reporting `true` is harmless (an unused `mut` is
    /// merely a warning, and `compile()`'s preamble already emits
    /// `#![allow(unused_mut, dead_code)]`), so this recurses broadly
    /// (including into lambda bodies — Ball's shared-mutable-closure
    /// semantics aren't otherwise implemented by this crate yet, but marking
    /// the outer binding `mut` here is free insurance, not a claim that
    /// closure capture itself is fixed).
    pub(crate) fn expr_mutates_var(&self, expr: &Expression, name: &str) -> bool {
        match &expr.expr {
            Some(Expr::Call(call)) => {
                if self.is_base_module(&call.module) {
                    let target_field = match call.function.as_str() {
                        "assign" => Some("target"),
                        "pre_increment" | "post_increment" | "pre_decrement" | "post_decrement" => {
                            Some("value")
                        }
                        _ => None,
                    };
                    let fields = extract_fields(call);
                    if let Some(field_name) = target_field {
                        if let Some(target_expr) = fields.get(field_name) {
                            if lvalue_root_matches(&self.resolve_lvalue(target_expr), name) {
                                return true;
                            }
                        }
                    }
                    // Mutating std_collections calls: their first collection
                    // argument is a real mutation target too.
                    if call.module == "std_collections" {
                        let collection_field = match call.function.as_str() {
                            "list_push" | "list_pop" | "list_insert" | "list_remove_at"
                            | "list_set" => Some("list"),
                            "map_set" | "map_delete" => Some("map"),
                            "set_add" | "set_remove" => Some("set"),
                            _ => None,
                        };
                        if let Some(field_name) = collection_field {
                            if let Some(target_expr) = fields.get(field_name) {
                                if lvalue_root_matches(&self.resolve_lvalue(target_expr), name) {
                                    return true;
                                }
                            }
                        }
                    }
                    if fields
                        .values()
                        .any(|value| self.expr_mutates_var(value, name))
                    {
                        return true;
                    }
                }
                call.input
                    .as_deref()
                    .is_some_and(|input| self.expr_mutates_var(input, name))
            }
            Some(Expr::MessageCreation(message_creation)) => {
                message_creation.fields.iter().any(|field| {
                    field
                        .value
                        .as_ref()
                        .is_some_and(|v| self.expr_mutates_var(v, name))
                })
            }
            Some(Expr::Block(block)) => {
                block
                    .statements
                    .iter()
                    .any(|statement| match &statement.stmt {
                        Some(Stmt::Let(let_binding)) => let_binding
                            .value
                            .as_ref()
                            .is_some_and(|v| self.expr_mutates_var(v, name)),
                        Some(Stmt::Expression(expression)) => {
                            self.expr_mutates_var(expression, name)
                        }
                        None => false,
                    })
                    || block
                        .result
                        .as_deref()
                        .is_some_and(|result| self.expr_mutates_var(result, name))
            }
            Some(Expr::Lambda(lambda)) => lambda
                .body
                .as_deref()
                .is_some_and(|body| self.expr_mutates_var(body, name)),
            Some(Expr::FieldAccess(field_access)) => field_access
                .object
                .as_deref()
                .is_some_and(|object| self.expr_mutates_var(object, name)),
            // A list literal's elements can carry mutations too — most
            // importantly `switch`'s `cases` and `try`'s `catches`, whose
            // clause bodies (each a `MessageCreation`) live inside a
            // `literal.list_value.elements` (see `base_call.rs`'s
            // `literal_list_elements`). Without recursing here, a `let`
            // mutated only inside a `switch`/`try` branch (the self-hosted
            // engine's `items`/`self`/`selfMap` set-mutation methods) is never
            // marked `let mut`, so its later `&mut` borrow is E0596 "cannot
            // borrow as mutable".
            Some(Expr::Literal(literal)) => match &literal.value {
                Some(LiteralValue::ListValue(list)) => list
                    .elements
                    .iter()
                    .any(|element| self.expr_mutates_var(element, name)),
                _ => false,
            },
            _ => false,
        }
    }

    /// Scan every statement in `rest` plus the trailing `result` (the
    /// portion of a block visible *after* a given `let` binding) for a
    /// mutation of `name`. Used by [`Compiler::compile_block`].
    pub(crate) fn rest_mutates_var(
        &self,
        rest: &[ball_shared::proto::ball::v1::Statement],
        result: Option<&Expression>,
        name: &str,
    ) -> bool {
        rest.iter().any(|statement| match &statement.stmt {
            Some(Stmt::Let(let_binding)) => let_binding
                .value
                .as_ref()
                .is_some_and(|v| self.expr_mutates_var(v, name)),
            Some(Stmt::Expression(expression)) => self.expr_mutates_var(expression, name),
            None => false,
        }) || result.is_some_and(|r| self.expr_mutates_var(r, name))
    }
}

/// Does `lvalue`'s root variable (after sanitization) match `name`?
fn lvalue_root_matches(lvalue: &LValue, name: &str) -> bool {
    let sanitized = crate::sanitize_ident(name);
    match lvalue {
        LValue::Var(var) => *var == sanitized,
        LValue::Field { object_var, .. } => *object_var == sanitized,
        LValue::Index { target_var, .. } => *target_var == sanitized,
        LValue::Unsupported(_) => false,
    }
}

/// Combine a read (`left`, a Rust expression string) with `right` per the
/// `AssignInput.op` compound-assignment operator, via the `ball_shared`
/// runtime helpers (see `rust/shared/src/runtime.rs`). `"="` (simple
/// assignment) just returns `right` — the read is discarded.
pub(crate) fn combine_op(op: &str, left: &str, right: &str) -> String {
    match op {
        "=" | "" => right.to_string(),
        "+=" => format!("ball_add({left}, {right})"),
        "-=" => format!("ball_subtract({left}, {right})"),
        "*=" => format!("ball_multiply({left}, {right})"),
        "/=" => format!("ball_divide({left}, {right})"),
        "~/=" => format!("ball_divide({left}, {right})"),
        "%=" => format!("ball_modulo({left}, {right})"),
        "&=" => format!("ball_bitwise_and({left}, {right})"),
        "|=" => format!("ball_bitwise_or({left}, {right})"),
        "^=" => format!("ball_bitwise_xor({left}, {right})"),
        "<<=" => format!("ball_left_shift({left}, {right})"),
        ">>=" => format!("ball_right_shift({left}, {right})"),
        ">>>=" => format!("ball_unsigned_right_shift({left}, {right})"),
        "??=" => format!("ball_null_coalesce({left}, {right})"),
        _ => right.to_string(),
    }
}

/// Escape a diagnostic string for embedding inside a generated `panic!("...")`
/// literal (only `"` / `\` need escaping — [`LValue::Unsupported`] reasons
/// are hand-authored ASCII).
fn escape_for_panic(reason: &str) -> String {
    reason.replace('\\', "\\\\").replace('"', "\\\"")
}
