//! `block` encoding — Rust `{ stmt; stmt; tail }` -> Ball `Block` (issue
//! #42). Mirrors `dart/encoder/lib/encoder.dart`'s `_encodeBlock`: every
//! statement becomes either a `LetBinding` (a `let` statement) or a bare
//! expression statement (evaluated for side effects); a **non-semicolon**
//! trailing expression becomes the block's `result` — exactly Rust's own
//! tail-expression-is-the-value rule, which this encoder gets "for free"
//! simply by reading `syn::Stmt::Expr(expr, semi)`'s `semi` presence.

use ball_lang_shared::proto::ball::v1::expression::Expr as BallExpr;
use ball_lang_shared::proto::ball::v1::statement::Stmt as BallStmt;
use ball_lang_shared::proto::ball::v1::{
    Block, Expression, FieldValuePair, LetBinding, MessageCreation, Statement,
};

use crate::{AliasTarget, Encoder, expr_stmt, null_literal, runtime_ctors};

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
        // The frame opens ahead of BOTH paths below: the message-builder idiom
        // declares its `let mut` map inside this block whether or not the whole
        // idiom matches, so a fall-through must not have skipped the scope.
        self.push_locals_frame(&[]);
        // `{ let mut m = BallMap::new(); m.insert("x", …); BallValue::Map(m) }`
        // is not a block at all — it is `rust/compiler`'s emission for a Ball
        // `message_creation` (issue #692), and its inverse is that very node.
        // Matched here, ahead of statement-by-statement encoding, because
        // taking it apart would need an inverse for `BallMap::insert` and would
        // produce a DIFFERENT node from the one it compiled from. Anything that
        // is not the whole idiom falls through unchanged — see
        // `runtime_ctors::as_message_builder`.
        let encoded = match self.encode_message_builder(block) {
            Some(creation) => creation,
            None => self.encode_block_statements(block),
        };
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
                    // `__ball_register_types();` — the first statement of every
                    // compiled `fn main()` (issue #692). It is the COMPILER's
                    // class prologue, inverted into each class's
                    // `metadata.superclass` and dropped here; keeping it would
                    // call a function this encoder deliberately does not emit.
                    if semi.is_some() && is_register_types_call(expr) {
                        continue;
                    }
                    if is_last && semi.is_none() {
                        // No trailing semicolon on the last statement — this
                        // is the block's tail/result expression, not a
                        // side-effecting statement (Rust's own rule).
                        result = Some(Box::new(self.encode_expr(expr)));
                    } else {
                        let encoded = self.encode_expr(expr);
                        statements.push(expr_stmt(encoded));
                    }
                }
                syn::Stmt::Macro(stmt_macro) => {
                    let encoded = self.encode_macro(&stmt_macro.mac);
                    statements.push(expr_stmt(encoded));
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

    /// The Ball `message_creation` a `BallMap` builder block is the emission
    /// of, or `None` when `block` is not that idiom (see
    /// [`crate::runtime_ctors::as_message_builder`] for the exact shape and why
    /// it is matched whole).
    ///
    /// A file that declares its own `BallMap`/`BallValue`/`BallMessage` wins,
    /// the same way `enum_names` guards the `BallValue::…` arm in
    /// [`Encoder::encode_call`]: its `BallMap::new()` is that type's own
    /// associated function, not the runtime's.
    fn encode_message_builder(&mut self, block: &syn::Block) -> Option<Expression> {
        for shadowed in [
            runtime_ctors::BALL_MAP_TYPE,
            runtime_ctors::BALL_MESSAGE_TYPE,
            crate::BALL_VALUE_TYPE,
        ] {
            if self.local_type_names.contains(shadowed) {
                return None;
            }
        }
        let builder = runtime_ctors::as_message_builder(block)?;
        let fields = builder
            .fields
            .into_iter()
            .map(|(name, value)| FieldValuePair {
                name,
                value: Some(self.encode_expr(value)),
            })
            .collect();
        Some(Expression {
            expr: Some(BallExpr::MessageCreation(MessageCreation {
                type_name: builder.type_name,
                fields,
                metadata: None,
            })),
        })
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
        //
        // A borrow of any OTHER place (`&mut p.x`, `&mut v[0]`) is classified
        // as `AliasTarget::Opaque` a few lines down: the binding is still
        // emitted, because a read of a borrow and a read of a copy give the
        // same answer, but a WRITE through it is refused rather than silently
        // dropped (issue #693 — see `lib.rs`'s
        // `refuse_write_through_an_unmodellable_borrow`).
        // A borrow of a variable that is ITSELF an alias (`let a = &mut i;
        // let b = &mut a;`) collapses to whatever `a` resolves to — including
        // its OPAQUENESS: `let a = &mut p.x; let b = &mut a;` makes a write
        // through `b` land on the same copy, so `b` inherits the refusal
        // rather than becoming a modelled alias of the copy.
        let alias = match local.init.as_ref().and_then(|init| borrowed(&init.expr)) {
            Some(Borrow::Variable(target)) => match self.ref_aliases.get(&target) {
                Some(AliasTarget::Variable(inner)) => Some(AliasTarget::Variable(inner.clone())),
                Some(AliasTarget::Opaque(place)) => Some(AliasTarget::Opaque(place.clone())),
                None => Some(AliasTarget::Variable(target)),
            },
            Some(Borrow::Opaque(place)) => Some(AliasTarget::Opaque(place)),
            None => None,
        };
        let opaque_place = match alias {
            Some(AliasTarget::Variable(resolved)) => {
                self.ref_aliases
                    .insert(name, AliasTarget::Variable(resolved));
                return None;
            }
            Some(AliasTarget::Opaque(place)) => Some(place),
            None => None,
        };
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
        // ...and only THEN is the unmodellable borrow recorded, so it replaces
        // whatever this name meant before rather than being wiped by the
        // shadowing `remove` above (issue #693). The binding itself is still
        // emitted — reads of it are correct — but a write through it now fails
        // loud in `lib.rs`'s `refuse_write_through_an_unmodellable_borrow`
        // instead of landing on the copy.
        if let Some(place) = opaque_place {
            self.ref_aliases
                .insert(name.clone(), AliasTarget::Opaque(place));
        }
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

/// Is `expr` a bare `__ball_register_types()` call — the compiler's class
/// prologue, invoked from every compiled `fn main()` (issue #692)?
fn is_register_types_call(expr: &syn::Expr) -> bool {
    let syn::Expr::Call(call) = expr else {
        return false;
    };
    if !call.args.is_empty() {
        return false;
    }
    match call.func.as_ref() {
        syn::Expr::Path(path) => path
            .path
            .get_ident()
            .is_some_and(|ident| ident == runtime_ctors::REGISTER_TYPES_FN),
        _ => false,
    }
}

/// What a `let`'s borrow initializer borrows (issues #642/#693).
enum Borrow {
    /// `&mut <ident>` (or `&<ident>`) — a plain NAMED variable, the one place
    /// this encoder can model.
    Variable(String),
    /// `&mut <place>` where `<place>` is a field, an index, a call result or
    /// anything else this encoder cannot resolve — carried as the place
    /// rendered back to Rust, purely so a refused write can name it.
    Opaque(String),
}

/// Classify a `let`'s initializer as a [`Borrow`], or `None` when it is not a
/// borrow at all.
///
/// A SHARED borrow of a non-variable place (`&p.x`) is deliberately `None`, not
/// `Opaque`: Rust cannot write through a `&T`, so encoding it as a copy can
/// never lose a write and there is nothing to refuse. Only `&mut` of an
/// unresolvable place is `Opaque`. (A shared borrow of a plain variable stays
/// `Variable`, exactly as before — resolving a read of it to the variable is
/// correct either way.)
fn borrowed(expr: &syn::Expr) -> Option<Borrow> {
    match expr {
        syn::Expr::Paren(paren) => borrowed(&paren.expr),
        syn::Expr::Group(group) => borrowed(&group.expr),
        syn::Expr::Reference(reference) => match strip_parens(&reference.expr) {
            syn::Expr::Path(path) => path
                .path
                .get_ident()
                .map(|ident| Borrow::Variable(ident.to_string())),
            other if reference.mutability.is_some() => {
                Some(Borrow::Opaque(quote::quote!(#other).to_string()))
            }
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
