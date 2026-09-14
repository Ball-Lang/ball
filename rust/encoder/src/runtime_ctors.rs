//! Recognizing the Ball Rust runtime's **collection constructors** and the
//! compiler's **class-registry prologue** (issue #692).
//!
//! [`runtime_helpers`](crate::runtime_helpers) maps the `ball_*` free functions
//! `rust/compiler` emits for a base CALL. This module covers the two shapes
//! that are not calls into that table at all:
//!
//! 1. **The collection constructors.** `rust/compiler/src/base_call.rs` and
//!    `lib.rs::compile_message_creation` build every list, map and instance out
//!    of `BallList::from(vec![…])` / `BallList::new()` / `BallMap::new()` /
//!    `BallMessage::new(…)`. `BallValue::String(…)`-style scalar constructors
//!    already encode as the identity (a Ball value is dynamic, so the wrapper
//!    means nothing); these are the same kind of shape, and their inverses are
//!    the very literal nodes they compile FROM.
//!
//! 2. **The class prologue.** `lib.rs::emit_type_registrations` synthesises
//!    `pub fn __ball_register_types()`, one `ball_register_superclass(child,
//!    parent)` per user class that extends another, and `fn main()` calls it
//!    before anything else. That is not a base call and has no universal-`std`
//!    inverse: the information it carries lives in the child
//!    `TypeDefinition`'s cosmetic `metadata.superclass`, which is exactly where
//!    `dart/encoder/lib/encoder.dart` puts it and where
//!    `rust/compiler/src/type_emit.rs::superclass_of` reads it back.
//!
//! ## Why the message builder is matched as a whole BLOCK
//!
//! `compile_message_creation` does not emit a map literal — it emits an
//! imperative builder:
//!
//! ```text
//! { let mut __ball_map = BallMap::new();
//!   __ball_map.insert("x".to_string(), BallValue::Int(3i64));
//!   BallValue::Message(BallMessage::new("main:Point", __ball_map)) }
//! ```
//!
//! Encoding that statement by statement would need an inverse for
//! `BallMap::insert`, and the result would be a Ball `block` that mutates a
//! map — a *different* node from the `message_creation` it compiled from, and
//! one whose Ball-level meaning depends on `std_collections.map_set` being
//! reference-semantic. Matching the whole idiom instead gives back the exact
//! node, so the round trip is an identity rather than an approximation. The
//! match is deliberately structural (a fresh `BallMap::new()` binding, every
//! intermediate statement an `insert` on that binding, a tail that consumes
//! it) rather than keyed on the compiler's `__ball_map` spelling: the same
//! block written by hand means the same thing, and a compiler-internal name is
//! not something an encoder should depend on.
//!
//! Anything that does not match falls through to ordinary block encoding, so a
//! `BallMap` used any other way still fails loud on its unmapped `.insert()`
//! rather than degrading silently.

/// The Ball Rust runtime's list type. `BallList::new()` is an empty list and
/// `BallList::from(x)` wraps an already-built sequence.
pub(crate) const BALL_LIST_TYPE: &str = "BallList";

/// The Ball Rust runtime's insertion-ordered map type.
pub(crate) const BALL_MAP_TYPE: &str = "BallMap";

/// The Ball Rust runtime's descriptor-backed instance type.
pub(crate) const BALL_MESSAGE_TYPE: &str = "BallMessage";

/// The compiler-synthesised class prologue
/// (`rust/compiler/src/lib.rs::emit_type_registrations`).
pub(crate) const REGISTER_TYPES_FN: &str = "__ball_register_types";

/// The single runtime helper that prologue is made of.
pub(crate) const REGISTER_SUPERCLASS_FN: &str = "ball_register_superclass";

/// The `TypeDefinition` metadata key a registration inverts to — the same
/// spelling `dart/encoder` writes and `rust/compiler` reads.
pub(crate) const SUPERCLASS_META_KEY: &str = "superclass";

/// A `BallValue::<Variant>(x)` wrapper that is the IDENTITY in Ball, because
/// Ball values are dynamic and carry no separate representation for the
/// variant. `Function` and `Message` are deliberately absent: the first wraps a
/// `BallFunction::new(…)` closure (a `lambda`, not its operand) and the second
/// only ever appears as a message builder's tail, handled by
/// [`as_message_builder`].
pub(crate) fn is_identity_value_variant(variant: &str) -> bool {
    matches!(
        variant,
        "String" | "Int" | "Double" | "Bool" | "Bytes" | "List" | "Map"
    )
}

/// What a recognized collection constructor encodes to.
pub(crate) enum CollectionCtor {
    /// `BallList::new()` / `BallMap::new()` — an empty literal of that kind.
    EmptyList,
    EmptyMap,
    /// `BallList::from(x)` — the identity: `x` is already the sequence.
    Passthrough,
}

/// Classify `<Owner>::<method>(…)` as one of the Ball runtime's collection
/// constructors, or `None` when it is anything else. `argc` is the call's
/// argument count, which is what separates `BallList::new()` from a
/// same-named associated function taking arguments.
pub(crate) fn collection_ctor(owner: &str, method: &str, argc: usize) -> Option<CollectionCtor> {
    match (owner, method, argc) {
        (BALL_LIST_TYPE, "new", 0) => Some(CollectionCtor::EmptyList),
        (BALL_MAP_TYPE, "new", 0) => Some(CollectionCtor::EmptyMap),
        (BALL_LIST_TYPE, "from", 1) => Some(CollectionCtor::Passthrough),
        _ => None,
    }
}

/// A matched message-builder block: the `message_creation` it is the emission
/// of. `type_name` is empty for the anonymous (`BallValue::Map`-sealed) form.
pub(crate) struct MessageBuilder<'a> {
    pub(crate) type_name: String,
    pub(crate) fields: Vec<(String, &'a syn::Expr)>,
}

/// Match the whole `{ let mut m = BallMap::new(); m.insert(…); …; <seal> }`
/// idiom — see the module doc comment for why this is matched as one block.
/// Returns `None` (never a partial match) for anything else, so the caller
/// falls back to ordinary block encoding.
pub(crate) fn as_message_builder(block: &syn::Block) -> Option<MessageBuilder<'_>> {
    let (first, rest) = block.stmts.split_first()?;
    let binding = fresh_map_binding(first)?;
    let (tail, inserts) = rest.split_last()?;

    let mut fields = Vec::with_capacity(inserts.len());
    for stmt in inserts {
        let syn::Stmt::Expr(expr, semi) = stmt else {
            return None;
        };
        if semi.is_none() {
            return None;
        }
        let syn::Expr::MethodCall(call) = expr else {
            return None;
        };
        if call.method != "insert" || call.args.len() != 2 || !is_ident(&call.receiver, &binding) {
            return None;
        }
        let key = string_operand(&call.args[0])?;
        fields.push((key, &call.args[1]));
    }

    let syn::Stmt::Expr(tail_expr, semi) = tail else {
        return None;
    };
    if semi.is_some() {
        return None;
    }
    let type_name = sealed_type_name(tail_expr, &binding)?;
    Some(MessageBuilder { type_name, fields })
}

/// `let mut <ident> = BallMap::new();` -> `<ident>`. The `mut` is required: an
/// immutable binding could never be the target of the inserts that follow, so
/// its absence means this is not the builder idiom.
fn fresh_map_binding(stmt: &syn::Stmt) -> Option<String> {
    let syn::Stmt::Local(local) = stmt else {
        return None;
    };
    let name = match &local.pat {
        syn::Pat::Ident(pat) if pat.subpat.is_none() && pat.mutability.is_some() => {
            pat.ident.to_string()
        }
        syn::Pat::Type(pat_type) => match pat_type.pat.as_ref() {
            syn::Pat::Ident(pat) if pat.subpat.is_none() && pat.mutability.is_some() => {
                pat.ident.to_string()
            }
            _ => return None,
        },
        _ => return None,
    };
    let init = local.init.as_ref()?;
    if init.diverge.is_some() {
        return None;
    }
    is_zero_arg_associated_call(&init.expr, BALL_MAP_TYPE, "new").then_some(name)
}

/// The builder's tail: `BallValue::Map(<binding>)` (anonymous) or
/// `BallValue::Message(BallMessage::new("<type>", <binding>))` (typed). The
/// tail must consume the very binding the block opened with — a tail naming
/// anything else is not this idiom.
fn sealed_type_name(expr: &syn::Expr, binding: &str) -> Option<String> {
    let (variant, args) = associated_call(expr, crate::BALL_VALUE_TYPE)?;
    if args.len() != 1 {
        return None;
    }
    match variant.as_str() {
        "Map" => is_ident(args[0], binding).then(String::new),
        "Message" => {
            let (method, inner) = associated_call(args[0], BALL_MESSAGE_TYPE)?;
            if method != "new" || inner.len() != 2 || !is_ident(inner[1], binding) {
                return None;
            }
            string_literal_value(inner[0])
        }
        _ => None,
    }
}

/// `<Owner>::<method>(args…)` -> `(method, args)`, or `None` when `expr` is not
/// a two-segment associated call on `owner`.
fn associated_call<'a>(expr: &'a syn::Expr, owner: &str) -> Option<(String, Vec<&'a syn::Expr>)> {
    let syn::Expr::Call(call) = expr else {
        return None;
    };
    let syn::Expr::Path(path_expr) = call.func.as_ref() else {
        return None;
    };
    let segments = &path_expr.path.segments;
    if segments.len() != 2 || segments[0].ident != owner {
        return None;
    }
    Some((
        segments[1].ident.to_string(),
        call.args.iter().collect::<Vec<_>>(),
    ))
}

fn is_zero_arg_associated_call(expr: &syn::Expr, owner: &str, method: &str) -> bool {
    match associated_call(expr, owner) {
        Some((found, args)) => found == method && args.is_empty(),
        None => false,
    }
}

/// Is `call` a call to the free function `name`?
fn is_call_to(call: &syn::ExprCall, name: &str) -> bool {
    match call.func.as_ref() {
        syn::Expr::Path(path) => path.path.get_ident().is_some_and(|ident| ident == name),
        _ => false,
    }
}

/// A map key as the compiler spells it (`"x".to_string()`) or as hand-written
/// Rust might (`"x"`). Anything computed is not a literal message field and
/// makes the whole match fail.
fn string_operand(expr: &syn::Expr) -> Option<String> {
    match expr {
        syn::Expr::MethodCall(call) if call.method == "to_string" && call.args.is_empty() => {
            string_literal_value(&call.receiver)
        }
        other => string_literal_value(other),
    }
}

fn string_literal_value(expr: &syn::Expr) -> Option<String> {
    match expr {
        syn::Expr::Paren(paren) => string_literal_value(&paren.expr),
        syn::Expr::Group(group) => string_literal_value(&group.expr),
        syn::Expr::Lit(lit) => match &lit.lit {
            syn::Lit::Str(text) => Some(text.value()),
            _ => None,
        },
        _ => None,
    }
}

fn is_ident(expr: &syn::Expr, name: &str) -> bool {
    match expr {
        syn::Expr::Paren(paren) => is_ident(&paren.expr, name),
        syn::Expr::Group(group) => is_ident(&group.expr, name),
        syn::Expr::Path(path) => path.path.get_ident().is_some_and(|ident| ident == name),
        _ => false,
    }
}

/// Harvest `(child, parent)` from the compiler's `__ball_register_types` body.
///
/// Fails loud on any statement that is not a `ball_register_superclass` call
/// with two string literals: the whole function is DROPPED from the encoded
/// Program, so anything else in it would be silently lost — exactly the
/// degradation issue #55's fail-loud doctrine exists to prevent. A function
/// this encoder cannot fully account for must stop the encode, not be trimmed.
pub(crate) fn superclass_registrations(item_fn: &syn::ItemFn) -> Vec<(String, String)> {
    assert!(
        item_fn.sig.inputs.is_empty(),
        "ball-lang-encoder: `{REGISTER_TYPES_FN}` is the compiler's class prologue and takes no \
         parameters; this one declares {}",
        item_fn.sig.inputs.len()
    );
    let mut out = Vec::new();
    for stmt in &item_fn.block.stmts {
        let syn::Stmt::Expr(syn::Expr::Call(call), Some(_)) = stmt else {
            panic!(
                "ball-lang-encoder: `{REGISTER_TYPES_FN}` may contain only \
                 `{REGISTER_SUPERCLASS_FN}(child, parent);` statements — it is the compiler's \
                 class prologue and is dropped from the encoded Program, so anything else in it \
                 would be silently lost: {}",
                quote::quote!(#stmt)
            )
        };
        assert!(
            is_call_to(call, REGISTER_SUPERCLASS_FN) && call.args.len() == 2,
            "ball-lang-encoder: `{REGISTER_TYPES_FN}` may contain only \
             `{REGISTER_SUPERCLASS_FN}(child, parent);` statements: {}",
            quote::quote!(#stmt)
        );
        let child = string_literal_value(&call.args[0]).unwrap_or_else(|| {
            panic!(
                "ball-lang-encoder: `{REGISTER_SUPERCLASS_FN}`'s child argument must be a string \
                 literal: {}",
                quote::quote!(#call)
            )
        });
        let parent = string_literal_value(&call.args[1]).unwrap_or_else(|| {
            panic!(
                "ball-lang-encoder: `{REGISTER_SUPERCLASS_FN}`'s parent argument must be a string \
                 literal: {}",
                quote::quote!(#call)
            )
        });
        out.push((child, parent));
    }
    out
}
