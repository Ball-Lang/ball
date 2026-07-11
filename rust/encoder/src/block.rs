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
    pub(crate) fn encode_block(&mut self, block: &syn::Block) -> Expression {
        let mut statements = Vec::new();
        let mut result: Option<Box<Expression>> = None;

        let stmt_count = block.stmts.len();
        for (index, stmt) in block.stmts.iter().enumerate() {
            let is_last = index + 1 == stmt_count;
            match stmt {
                syn::Stmt::Local(local) => {
                    statements.push(self.encode_local(local));
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

        Expression {
            expr: Some(ball_lang_shared::proto::ball::v1::expression::Expr::Block(
                Box::new(Block {
                    statements,
                    result: Some(result.unwrap_or_else(|| Box::new(null_literal()))),
                }),
            )),
        }
    }

    fn encode_local(&mut self, local: &syn::Local) -> Statement {
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
        let value = match &local.init {
            Some(init) => self.encode_expr(&init.expr),
            None => null_literal(),
        };
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
        Statement {
            stmt: Some(BallStmt::Let(LetBinding {
                name,
                value: Some(value),
                metadata,
            })),
        }
    }
}
