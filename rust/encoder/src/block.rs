//! `block` encoding — Rust `{ stmt; stmt; tail }` -> Ball `Block` (issue
//! #42). Mirrors `dart/encoder/lib/encoder.dart`'s `_encodeBlock`: every
//! statement becomes either a `LetBinding` (a `let` statement) or a bare
//! expression statement (evaluated for side effects); a **non-semicolon**
//! trailing expression becomes the block's `result` — exactly Rust's own
//! tail-expression-is-the-value rule, which this encoder gets "for free"
//! simply by reading `syn::Stmt::Expr(expr, semi)`'s `semi` presence.

use ball_shared::proto::ball::v1::statement::Stmt as BallStmt;
use ball_shared::proto::ball::v1::{Block, Expression, LetBinding, Statement};

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
                    "ball-encoder: local item declarations (nested fn/struct/...) inside a block \
                     are not supported (issue #42's scope)"
                ),
            }
        }

        Expression {
            expr: Some(ball_shared::proto::ball::v1::expression::Expr::Block(
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
                    "ball-encoder: `let ... else {{ ... }}` (let-else) is not supported (issue \
                     #42's scope)"
                );
            }
        }
        let name = match &local.pat {
            syn::Pat::Ident(syn::PatIdent {
                ident,
                subpat: None,
                ..
            }) => ident.to_string(),
            // `let _ = expr;` — the common "evaluate for a side effect,
            // discard the value" idiom. `"_"` is itself a valid Ball/Rust
            // binding name (the compiled Rust becomes `let _ = ...;`,
            // which discards without even reserving a real local).
            syn::Pat::Wild(_) => "_".to_string(),
            syn::Pat::Type(pat_type) => match pat_type.pat.as_ref() {
                syn::Pat::Ident(syn::PatIdent {
                    ident,
                    subpat: None,
                    ..
                }) => ident.to_string(),
                syn::Pat::Wild(_) => "_".to_string(),
                _ => panic!(
                    "ball-encoder: only simple identifier `let` bindings are supported \
                     (destructuring `let` patterns are deferred)"
                ),
            },
            other => panic!(
                "ball-encoder: only simple identifier `let` bindings are supported \
                 (destructuring `let` patterns are deferred): {}",
                quote::quote!(#other)
            ),
        };
        let value = match &local.init {
            Some(init) => self.encode_expr(&init.expr),
            None => null_literal(),
        };
        Statement {
            stmt: Some(BallStmt::Let(LetBinding {
                name,
                value: Some(value),
                metadata: None,
            })),
        }
    }
}
