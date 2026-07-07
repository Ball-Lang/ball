//! Control-flow encoding (issue #42): `if`/`if let` -> `std.if`, `match` ->
//! `std.switch` (or an if/else-chain — see below), `while`/`loop` ->
//! `std.while`, `for` -> `std.for`/`std.for_in`, `break`/`continue`/
//! `return`, loop labels, and the `?` try-operator's error-propagation
//! desugaring.
//!
//! **Laziness (invariant #4):** every branch here is built as a Ball
//! **sub-expression** operand of the relevant `std` control-flow call
//! (`then`/`else`/`body`/...), never pre-evaluated by the encoder — the
//! encoder only ever *builds trees*, it doesn't execute anything, so this
//! falls out naturally as long as branches are threaded through as
//! `Expression` values (which they are, throughout this file) rather than
//! ever being collapsed to a single chosen branch here.
//!
//! ## `match`'s two encodings
//!
//! `std.switch` only expresses **equality** comparisons (`ball_equals(subject,
//! case.value)` — see `rust/compiler/src/base_call.rs::compile_switch`), so
//! it's the right target for a literal-value `match` (ints/strings/bools,
//! `_`, `|`-combinations of literals). Matching `Some`/`Ok`/`Err`/`None`
//! needs a **discriminant field check** instead
//! (`field_access(subject,"is_err")`), which the generic `switch` can't
//! express — so a `match` containing any such pattern is desugared to a
//! right-nested `std.if`/`std.else` chain instead (mirroring `if let`'s own
//! desugaring, which needs the exact same discriminant-check shape). See
//! `lib.rs::option_result_message`'s doc comment for the unified
//! Option/Result "outcome" representation both share.
use ball_shared::proto::ball::v1::Expression;

use crate::{
    Encoder, args_message, block_expr, bool_literal, field_access, for_init_block, if_call,
    let_stmt, list_literal, named_message, null_literal, reference, std_call, string_literal,
};

/// For a pattern like `Some(x)`/`Ok(x)`/`None`/`Err(e)` matched against the
/// unified Option/Result "outcome" representation, returns `(is_err_when_matched,
/// binding_name)`. Fails loud on any other pattern shape (destructuring
/// beyond a single identifier binding, or a variant other than
/// Some/Ok/Err/None — real enum-variant matching needs #43's
/// `TypeDefinition`-aware resolution).
fn pattern_outcome_shape(pat: &syn::Pat) -> (bool, Option<String>) {
    match pat {
        syn::Pat::TupleStruct(ts) => {
            let last = ts
                .path
                .segments
                .last()
                .expect("a path pattern always has at least one segment")
                .ident
                .to_string();
            let is_err = match last.as_str() {
                "Some" | "Ok" => false,
                "Err" => true,
                other => panic!(
                    "ball-encoder: unsupported if-let/match pattern `{other}(...)` (only \
                     Some/Ok/Err are supported — real enum-variant patterns need #43)"
                ),
            };
            if ts.elems.len() != 1 {
                panic!(
                    "ball-encoder: only a single-binding pattern is supported, e.g. `Some(x)` \
                     (got {} bindings)",
                    ts.elems.len()
                );
            }
            let name = match &ts.elems[0] {
                syn::Pat::Ident(syn::PatIdent {
                    ident,
                    subpat: None,
                    ..
                }) => Some(ident.to_string()),
                syn::Pat::Wild(_) => None,
                other => panic!(
                    "ball-encoder: only a simple identifier or `_` binding is supported inside \
                     Some/Ok/Err(...): {}",
                    quote::quote!(#other)
                ),
            };
            (is_err, name)
        }
        syn::Pat::Path(p) => {
            let last = p
                .path
                .segments
                .last()
                .expect("a path pattern always has at least one segment")
                .ident
                .to_string();
            if last == "None" {
                (true, None)
            } else {
                panic!(
                    "ball-encoder: unsupported if-let/match pattern `{last}` (only `None` is \
                     supported as a bare path pattern)"
                );
            }
        }
        other => panic!(
            "ball-encoder: unsupported if-let/match pattern (only Some(x)/Ok(x)/Err(e)/None are \
             supported): {}",
            quote::quote!(#other)
        ),
    }
}

/// Does `pat` match the `Some`/`Ok`/`Err`/`None` shape [`pattern_outcome_shape`]
/// handles? Used by [`Encoder::encode_match`] to pick which of `match`'s two
/// encodings applies.
fn is_option_result_pattern(pat: &syn::Pat) -> bool {
    match pat {
        syn::Pat::TupleStruct(ts) => matches!(
            ts.path
                .segments
                .last()
                .map(|s| s.ident.to_string())
                .as_deref(),
            Some("Some" | "Ok" | "Err")
        ),
        syn::Pat::Path(p) => matches!(
            p.path
                .segments
                .last()
                .map(|s| s.ident.to_string())
                .as_deref(),
            Some("None")
        ),
        _ => false,
    }
}

/// Discriminant-check condition for the unified outcome shape: `is_err`
/// directly when the matched pattern represents the "failure" arm (`Err`/
/// `None`), or its negation (`std.not`) for the "success" arm (`Ok`/`Some`).
fn outcome_condition(subject: Expression, is_err_when_matched: bool) -> Expression {
    let is_err = field_access(subject, "is_err");
    if is_err_when_matched {
        is_err
    } else {
        std_call("not", Some(args_message(vec![("value", is_err)])))
    }
}

impl Encoder {
    // ════════════════════════════════════════════════════════════
    // if / if let
    // ════════════════════════════════════════════════════════════

    pub(crate) fn encode_if(&mut self, e: &syn::ExprIf) -> Expression {
        if let syn::Expr::Let(let_expr) = e.cond.as_ref() {
            return self.encode_if_let(let_expr, &e.then_branch, e.else_branch.as_ref());
        }
        let condition = self.encode_expr(&e.cond);
        let then = self.encode_block(&e.then_branch);
        let else_branch = match &e.else_branch {
            // `else_expr` is itself either `Expr::If` (an `else if` chain)
            // or `Expr::Block` (a plain `else { ... }`) — `encode_expr`
            // already dispatches both correctly.
            Some((_, else_expr)) => self.encode_expr(else_expr),
            None => null_literal(),
        };
        if_call(condition, then, else_branch)
    }

    fn encode_if_let(
        &mut self,
        let_expr: &syn::ExprLet,
        then_branch: &syn::Block,
        else_branch: Option<&(syn::token::Else, Box<syn::Expr>)>,
    ) -> Expression {
        let (is_err_when_matched, bind_name) = pattern_outcome_shape(&let_expr.pat);
        let subject = self.encode_expr(&let_expr.expr);
        let tmp = "__ball_if_let";
        let condition = outcome_condition(reference(tmp), is_err_when_matched);

        let then_inner = self.encode_block(then_branch);
        let then = match bind_name {
            Some(name) => block_expr(
                vec![let_stmt(name, field_access(reference(tmp), "value"))],
                then_inner,
            ),
            None => then_inner,
        };
        let else_expr = match else_branch {
            Some((_, expr)) => self.encode_expr(expr),
            None => null_literal(),
        };

        block_expr(
            vec![let_stmt(tmp, subject)],
            if_call(condition, then, else_expr),
        )
    }

    // ════════════════════════════════════════════════════════════
    // match
    // ════════════════════════════════════════════════════════════

    pub(crate) fn encode_match(&mut self, e: &syn::ExprMatch) -> Expression {
        if e.arms.iter().any(|arm| is_option_result_pattern(&arm.pat)) {
            self.encode_outcome_match(e)
        } else {
            self.encode_literal_switch_match(e)
        }
    }

    /// A `match` on the unified Option/Result outcome shape — desugars to a
    /// right-nested `std.if`/`else` chain (see the module doc comment for
    /// why `std.switch`'s equality semantics can't express this).
    fn encode_outcome_match(&mut self, e: &syn::ExprMatch) -> Expression {
        let subject = self.encode_expr(&e.expr);
        let tmp = "__ball_match_subject";

        let mut default_body: Option<Expression> = None;
        let mut branches: Vec<(Expression, Expression)> = Vec::new();
        for arm in &e.arms {
            assert!(
                arm.guard.is_none(),
                "ball-encoder: match arm guards (`pat if cond => ...`) are not supported \
                 (issue #42's scope)"
            );
            match &arm.pat {
                syn::Pat::Wild(_) => {
                    default_body = Some(self.encode_expr(&arm.body));
                }
                syn::Pat::Ident(syn::PatIdent {
                    ident,
                    subpat: None,
                    ..
                }) => {
                    let body_inner = self.encode_expr(&arm.body);
                    default_body = Some(block_expr(
                        vec![let_stmt(ident.to_string(), reference(tmp))],
                        body_inner,
                    ));
                }
                pat => {
                    let (is_err, bind_name) = pattern_outcome_shape(pat);
                    let condition = outcome_condition(reference(tmp), is_err);
                    let body_inner = self.encode_expr(&arm.body);
                    let body = match bind_name {
                        Some(name) => block_expr(
                            vec![let_stmt(name, field_access(reference(tmp), "value"))],
                            body_inner,
                        ),
                        None => body_inner,
                    };
                    branches.push((condition, body));
                }
            }
        }

        let mut chain = default_body.unwrap_or_else(null_literal);
        for (condition, body) in branches.into_iter().rev() {
            chain = if_call(condition, body, chain);
        }
        block_expr(vec![let_stmt(tmp, subject)], chain)
    }

    /// A `match` over literal values (ints/strings/bools) — `std.switch`
    /// with each arm as a `SwitchCase` sub-expression.
    fn encode_literal_switch_match(&mut self, e: &syn::ExprMatch) -> Expression {
        let subject = self.encode_expr(&e.expr);
        let tmp = "__ball_switch_subject";
        let mut cases = Vec::new();
        for arm in &e.arms {
            assert!(
                arm.guard.is_none(),
                "ball-encoder: match arm guards (`pat if cond => ...`) are not supported \
                 (issue #42's scope)"
            );
            self.encode_switch_arm(arm, tmp, &mut cases);
        }
        let switch = std_call(
            "switch",
            Some(args_message(vec![
                ("subject", reference(tmp)),
                ("cases", list_literal(cases)),
            ])),
        );
        block_expr(vec![let_stmt(tmp, subject)], switch)
    }

    fn encode_switch_arm(&mut self, arm: &syn::Arm, tmp: &str, cases: &mut Vec<Expression>) {
        match &arm.pat {
            syn::Pat::Wild(_) => {
                let body = self.encode_expr(&arm.body);
                cases.push(switch_case_message(None, true, body));
            }
            syn::Pat::Ident(syn::PatIdent {
                ident,
                subpat: None,
                ..
            }) => {
                // A catch-all binding arm (`other => ...`) — no equivalent
                // in `std.switch`'s comparison model, so the arm body is
                // wrapped to alias the subject under the arm's own name via
                // the pre-`let`-bound subject temp (`tmp`).
                let body_inner = self.encode_expr(&arm.body);
                let body = block_expr(
                    vec![let_stmt(ident.to_string(), reference(tmp))],
                    body_inner,
                );
                cases.push(switch_case_message(None, true, body));
            }
            syn::Pat::Lit(pat_lit) => {
                let value = self.encode_lit(&pat_lit.lit);
                let body = self.encode_expr(&arm.body);
                cases.push(switch_case_message(Some(value), false, body));
            }
            syn::Pat::Or(pat_or) => {
                // `A | B => body` expands to one `SwitchCase` per literal,
                // each independently compiling the (side-effect-free to
                // re-encode) same arm body.
                for case_pat in &pat_or.cases {
                    match case_pat {
                        syn::Pat::Lit(pat_lit) => {
                            let value = self.encode_lit(&pat_lit.lit);
                            let body = self.encode_expr(&arm.body);
                            cases.push(switch_case_message(Some(value), false, body));
                        }
                        other => panic!(
                            "ball-encoder: only literal patterns are supported inside a \
                             `|`-combination: {}",
                            quote::quote!(#other)
                        ),
                    }
                }
            }
            other => panic!(
                "ball-encoder: unsupported match pattern (only literals, `_`, a catch-all \
                 identifier binding, and `|`-combinations of literals are supported for a \
                 value match — enum/struct patterns need #43): {}",
                quote::quote!(#other)
            ),
        }
    }

    // ════════════════════════════════════════════════════════════
    // Loops
    // ════════════════════════════════════════════════════════════

    pub(crate) fn encode_while(&mut self, e: &syn::ExprWhile) -> Expression {
        let condition = self.encode_expr(&e.cond);
        let body = self.encode_block(&e.body);
        let call = std_call(
            "while",
            Some(args_message(vec![("condition", condition), ("body", body)])),
        );
        self.wrap_label(&e.label, call)
    }

    /// `loop { body }` -> `std.while(true, body)` (the issue's own
    /// "loop -> std.while(true)-style encoding" instruction).
    pub(crate) fn encode_loop(&mut self, e: &syn::ExprLoop) -> Expression {
        let body = self.encode_block(&e.body);
        let call = std_call(
            "while",
            Some(args_message(vec![
                ("condition", bool_literal(true)),
                ("body", body),
            ])),
        );
        self.wrap_label(&e.label, call)
    }

    pub(crate) fn encode_for_loop(&mut self, e: &syn::ExprForLoop) -> Expression {
        let var_name = match e.pat.as_ref() {
            syn::Pat::Ident(syn::PatIdent {
                ident,
                subpat: None,
                ..
            }) => ident.to_string(),
            syn::Pat::Wild(_) => "_".to_string(),
            other => panic!(
                "ball-encoder: unsupported for-loop pattern (only a simple identifier or `_` is \
                 supported): {}",
                quote::quote!(#other)
            ),
        };

        let call = match e.expr.as_ref() {
            // `for i in a..b { ... }` / `for i in a..=b { ... }` — desugars
            // to a C-style `std.for` counting loop (Ball has no native
            // Range type — see the module doc comment).
            syn::Expr::Range(range) if range.start.is_some() && range.end.is_some() => {
                let start = self.encode_expr(range.start.as_deref().expect("checked above"));
                let end = self.encode_expr(range.end.as_deref().expect("checked above"));
                let comparison = if matches!(range.limits, syn::RangeLimits::Closed(_)) {
                    "lte"
                } else {
                    "less_than"
                };
                let body = self.encode_block(&e.body);
                let init = for_init_block(vec![(var_name.clone(), start)]);
                let condition = std_call(
                    comparison,
                    Some(args_message(vec![
                        ("left", reference(var_name.clone())),
                        ("right", end),
                    ])),
                );
                let update = std_call(
                    "assign",
                    Some(args_message(vec![
                        ("target", reference(var_name.clone())),
                        ("value", crate::int_literal(1)),
                        ("op", string_literal("+=")),
                    ])),
                );
                std_call(
                    "for",
                    Some(args_message(vec![
                        ("init", init),
                        ("condition", condition),
                        ("update", update),
                        ("body", body),
                    ])),
                )
            }
            // `for x in iterable { ... }` — a real collection, iterated
            // element-by-element via `std.for_in`.
            other => {
                let iterable = self.encode_expr(other);
                let body = self.encode_block(&e.body);
                std_call(
                    "for_in",
                    Some(args_message(vec![
                        ("variable", string_literal(var_name)),
                        ("iterable", iterable),
                        ("body", body),
                    ])),
                )
            }
        };
        self.wrap_label(&e.label, call)
    }

    /// Wraps a loop's compiled `std.for`/`std.for_in`/`std.while` call in
    /// `std.label(name, body)` when the source loop carries a Rust loop
    /// label (`'outer: for ...`), so labeled `break`/`continue` resolve —
    /// mirrors `rust/compiler/src/base_call.rs::compile_label`'s directly-
    /// nested-loop fast path.
    fn wrap_label(&self, label: &Option<syn::Label>, call: Expression) -> Expression {
        match label {
            Some(label) => std_call(
                "label",
                Some(args_message(vec![
                    ("name", string_literal(label.name.ident.to_string())),
                    ("body", call),
                ])),
            ),
            None => call,
        }
    }

    // ════════════════════════════════════════════════════════════
    // Flow signals
    // ════════════════════════════════════════════════════════════

    pub(crate) fn encode_return(&mut self, e: &syn::ExprReturn) -> Expression {
        let value = match &e.expr {
            Some(expr) => self.encode_expr(expr),
            None => null_literal(),
        };
        std_call("return", Some(args_message(vec![("value", value)])))
    }

    pub(crate) fn encode_break(&mut self, e: &syn::ExprBreak) -> Expression {
        assert!(
            e.expr.is_none(),
            "ball-encoder: `break <value>` (breaking a loop with a value) is not supported \
             (issue #42's scope)"
        );
        match &e.label {
            Some(lifetime) => std_call(
                "break",
                Some(args_message(vec![(
                    "label",
                    string_literal(lifetime.ident.to_string()),
                )])),
            ),
            None => std_call("break", None),
        }
    }

    pub(crate) fn encode_continue(&mut self, e: &syn::ExprContinue) -> Expression {
        match &e.label {
            Some(lifetime) => std_call(
                "continue",
                Some(args_message(vec![(
                    "label",
                    string_literal(lifetime.ident.to_string()),
                )])),
            ),
            None => std_call("continue", None),
        }
    }

    // ════════════════════════════════════════════════════════════
    // `?` — error propagation
    // ════════════════════════════════════════════════════════════

    /// `expr?` -> evaluate `expr` once into a temp, `return` it whole when
    /// it's the "failure" outcome (`is_err`), otherwise unwrap `.value`.
    /// See the module doc comment / `lib.rs::option_result_message` for the
    /// unified Option/Result "outcome" shape this (and `if let`/`match`)
    /// all share.
    pub(crate) fn encode_try_operator(&mut self, e: &syn::ExprTry) -> Expression {
        let target = self.encode_expr(&e.expr);
        let tmp = "__ball_try";
        let propagate = std_call(
            "return",
            Some(args_message(vec![("value", reference(tmp))])),
        );
        let unwrapped = field_access(reference(tmp), "value");
        block_expr(
            vec![let_stmt(tmp, target)],
            if_call(field_access(reference(tmp), "is_err"), propagate, unwrapped),
        )
    }
}

fn switch_case_message(
    value: Option<Expression>,
    is_default: bool,
    body: Expression,
) -> Expression {
    let mut fields = vec![("is_default", bool_literal(is_default)), ("body", body)];
    if let Some(v) = value {
        fields.insert(0, ("value", v));
    }
    named_message("SwitchCase", fields)
}
