//! `block` encoding — Rust `{ stmt; stmt; tail }` -> Ball `Block` (issue
//! #42). Mirrors `dart/encoder/lib/encoder.dart`'s `_encodeBlock`: every
//! statement becomes either a `LetBinding` (a `let` statement) or a bare
//! expression statement (evaluated for side effects); a **non-semicolon**
//! trailing expression becomes the block's `result` — exactly Rust's own
//! tail-expression-is-the-value rule, which this encoder gets "for free"
//! simply by reading `syn::Stmt::Expr(expr, semi)`'s `semi` presence.

use ball_lang_shared::proto::ball::v1::statement::Stmt as BallStmt;
use ball_lang_shared::proto::ball::v1::{Block, Expression, LetBinding, Statement};

use crate::{Encoder, null_literal};

impl Encoder {
    /// Encode a `syn::Block` to a Ball `block` [`Expression`].
    ///
    /// A block is a **binding scope**: its `let`s are gone at the closing
    /// brace (Rust's own rule), so it opens a frame of its own in
    /// [`Self::push_locals_frame`]'s stack. Without one, an inner
    /// `let f = String::from(..)` shadowing a `&mut fmt::Formatter` parameter
    /// `f` would still look like a local `String` AFTER the block, and issue
    /// #630's `write!` destination rule would re-assign a binding that is not
    /// in scope instead of writing to the parameter's sink. Frames nest, and
    /// lookup is innermost-first, so an enclosing body's bindings stay
    /// visible — which is what a block, unlike a `fn` item, may see.
    pub(crate) fn encode_block(&mut self, block: &syn::Block) -> Expression {
        self.push_locals_frame(&[]);
        let encoded = self.encode_block_statements(block);
        self.pop_locals_frame();
        encoded
    }

    fn encode_block_statements(&mut self, block: &syn::Block) -> Expression {
        // A `&mut` alias binding is scoped to the block that declares it, like
        // any other `let` (issue #642), so the table is saved here and restored
        // on the way out rather than leaking into the enclosing block.
        let outer_aliases = self.ref_aliases.clone();
        let mut statements = Vec::new();
        let mut result: Option<Box<Expression>> = None;

        let stmt_count = block.stmts.len();
        for (index, stmt) in block.stmts.iter().enumerate() {
            let is_last = index + 1 == stmt_count;
            match stmt {
                syn::Stmt::Local(local) => {
                    // `None` = a `&mut` alias binding, recorded rather than
                    // emitted (issue #642) — see `encode_local`.
                    if let Some(statement) = self.encode_local(local) {
                        statements.push(statement);
                    }
                }
                syn::Stmt::Expr(expr, semi) => {
                    if is_last && semi.is_none() {
                        // No trailing semicolon on the last statement — this
                        // is the block's tail/result expression, not a
                        // side-effecting statement (Rust's own rule).
                        result = Some(Box::new(self.encode_expr(expr)));
                    } else {
                        let encoded = self.encode_expr(expr);
                        statements.push(Statement {
                            stmt: Some(BallStmt::Expression(encoded)),
                        });
                    }
                }
                syn::Stmt::Macro(stmt_macro) => {
                    let encoded = self.encode_macro(&stmt_macro.mac);
                    statements.push(Statement {
                        stmt: Some(BallStmt::Expression(encoded)),
                    });
                }
                syn::Stmt::Item(_) => panic!(
                    "ball-lang-encoder: local item declarations (nested fn/struct/...) inside a block \
                     are not supported (issue #42's scope)"
                ),
            }
        }

        self.ref_aliases = outer_aliases;

        Expression {
            expr: Some(ball_lang_shared::proto::ball::v1::expression::Expr::Block(
                Box::new(Block {
                    statements,
                    result: Some(result.unwrap_or_else(|| Box::new(null_literal()))),
                }),
            )),
        }
    }

    /// Encode one `let` statement, or record it and return `None` when it is a
    /// `&mut` ALIAS binding (`let slot: &mut T = &mut place;`) — see
    /// [`Encoder::ref_aliases`].
    fn encode_local(&mut self, local: &syn::Local) -> Option<Statement> {
        if let Some(init) = &local.init {
            if init.diverge.is_some() {
                panic!(
                    "ball-lang-encoder: `let ... else {{ ... }}` (let-else) is not supported (issue \
                     #42's scope)"
                );
            }
        }
        let (name, is_mut) = match &local.pat {
            syn::Pat::Ident(syn::PatIdent {
                ident,
                subpat: None,
                mutability,
                ..
            }) => (ident.to_string(), mutability.is_some()),
            // `let _ = expr;` — the common "evaluate for a side effect,
            // discard the value" idiom. `"_"` is itself a valid Ball/Rust
            // binding name (the compiled Rust becomes `let _ = ...;`,
            // which discards without even reserving a real local).
            syn::Pat::Wild(_) => ("_".to_string(), false),
            syn::Pat::Type(pat_type) => match pat_type.pat.as_ref() {
                syn::Pat::Ident(syn::PatIdent {
                    ident,
                    subpat: None,
                    mutability,
                    ..
                }) => (ident.to_string(), mutability.is_some()),
                syn::Pat::Wild(_) => ("_".to_string(), false),
                _ => panic!(
                    "ball-lang-encoder: only simple identifier `let` bindings are supported \
                     (destructuring `let` patterns are deferred)"
                ),
            },
            other => panic!(
                "ball-lang-encoder: only simple identifier `let` bindings are supported \
                 (destructuring `let` patterns are deferred): {}",
                quote::quote!(#other)
            ),
        };
        // `let __slot: &mut BallValue = (&mut i);` — the shape
        // `ball-lang-compiler`'s `lvalue.rs::emit_mutation` emits for every Ball
        // `assign`, and an ordinary idiom in hand-written Rust too. Ball has no
        // references, so binding it as a VALUE silently turns every subsequent
        // `*__slot = ...` into a write to a copy: the borrowed variable never
        // changes, and a loop whose counter is mutated that way never
        // terminates. (Measured: 28 of the corpus's loop fixtures re-encoded
        // "cleanly" and then hung on the Dart reference engine — issue #642.)
        // Record the alias and emit no binding; a read of it resolves to the
        // borrowed variable, which is what the Rust actually means.
        if let Some(init) = &local.init {
            if let Some(target) = borrowed_variable(&init.expr) {
                let resolved = self
                    .ref_aliases
                    .get(&target)
                    .cloned()
                    .unwrap_or_else(|| target.clone());
                self.ref_aliases.insert(name, resolved);
                return None;
            }
        }
        let value = match &local.init {
            Some(init) => self.encode_expr(&init.expr),
            None => null_literal(),
        };
        // Record the binding AFTER its initialiser is encoded, so a shadowing
        // `let s = s;` still reads the OUTER `s` (Rust's own rule). Issue
        // #630's `write!` destination rule is the only consumer — see
        // `Encoder::push_locals_frame`.
        self.record_local(&name, local.init.as_ref().map(|init| init.expr.as_ref()));
        // Not an alias binding: this `let` SHADOWS any alias of the same name
        // that is still in scope (`let r = &mut y; ... let r = 5; ... r` reads
        // the 5, not `y`). Dropping the entry is what makes a later read of the
        // name resolve to this binding instead of silently to the borrowed
        // variable. The block that declared the alias restores it on exit.
        //
        // AFTER the initializer is encoded, never before: in `let r = r + 1;`
        // the right-hand `r` is the OLD binding, so it must still resolve
        // through the alias.
        self.ref_aliases.remove(&name);
        // Cosmetic mutability round-trip (issue #43): `let mut x = ...;` ->
        // `metadata.is_mut = true`; a plain `let x = ...;` (Rust's default,
        // conceptually Dart's `final`) carries no metadata at all — matches
        // every other boolean cosmetic flag's "absence means false"
        // convention in this crate (see `MetaBuilder::set_bool_if_true`).
        // `ball-lang-compiler` never reads a `LetBinding`'s metadata for anything
        // (see `rust/compiler/src/lib.rs::compile_expression`'s `Block`
        // arm), so this can never change a compiled program's output.
        let metadata = is_mut.then(|| {
            let mut fields = std::collections::HashMap::new();
            fields.insert("is_mut".to_string(), crate::bool_value(true));
            ball_lang_shared::proto::google::protobuf::Struct { fields }
        });
        Some(Statement {
            stmt: Some(BallStmt::Let(LetBinding {
                name,
                value: Some(value),
                metadata,
            })),
        })
    }
}

/// The variable a `&mut <ident>` (or `&<ident>`) initializer borrows, if the
/// initializer is exactly that and nothing else.
///
/// Deliberately narrow: only a borrow of a plain NAMED variable, through any
/// number of parentheses. A borrow of a field, an index, a call result or any
/// other place (`&mut v[0]`, `&mut p.x`) is NOT an alias this encoder can model,
/// and is left to encode the way it always has — widening it would be guessing
/// at which place a later write lands on.
fn borrowed_variable(expr: &syn::Expr) -> Option<String> {
    match expr {
        syn::Expr::Paren(paren) => borrowed_variable(&paren.expr),
        syn::Expr::Group(group) => borrowed_variable(&group.expr),
        syn::Expr::Reference(reference) => match strip_parens(&reference.expr) {
            syn::Expr::Path(path) => path.path.get_ident().map(|i| i.to_string()),
            _ => None,
        },
        _ => None,
    }
}

fn strip_parens(expr: &syn::Expr) -> &syn::Expr {
    match expr {
        syn::Expr::Paren(paren) => strip_parens(&paren.expr),
        syn::Expr::Group(group) => strip_parens(&group.expr),
        other => other,
    }
}
