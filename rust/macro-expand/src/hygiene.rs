//! Hygiene — what is approximated, and what is stated.
//!
//! `macro_rules!` has **mixed-site hygiene**: the Rust Reference,
//! *Macros By Example* — "Macros by example have *mixed-site hygiene*. This
//! means that loop labels, block labels, and local variables are looked up at
//! the macro definition site while other symbols are looked up at the macro
//! invocation site."
//!
//! `ra_ap_mbe` does **not** implement that on its own. Measured: the macro
//! `($e:expr) => {{ let x = 1; $e + x }}`, invoked as `mac!(x)` from a caller
//! that has its own `x`, expands to `{ let x = 1 ; x + x }` — the caller's `x`
//! is captured. Real mixed-site hygiene lives in rust-analyzer's `hir-expand`
//! `SyntaxContext` transparency chain, which needs a populated salsa database
//! of `MacroCallLoc`s that the expander alone does not give you.
//!
//! ## What this module does instead
//!
//! Every output token carries a span whose anchor says whether it was
//! transcribed out of the DEFINITION or substituted in from the CALL
//! ([`crate::bridge::Origin`]). Definition-origin identifiers are **marked**
//! on the way out of the engine — with a prefix, in the token stream itself,
//! because `proc_macro2::Span` cannot carry a flag and no side table can be
//! kept in step with a `syn` traversal order this crate cannot predict. Then,
//! once the expansion has been parsed:
//!
//! 1. every marked identifier in a **binding** position (a `let`/closure/`for`
//!    pattern binding) is collected;
//! 2. every marked identifier in a **binding or variable-read** position whose
//!    name was collected is α-renamed to a deterministic fresh name
//!    (`<name>__ball_mbe<N>`);
//! 3. every other marked identifier is simply unmarked.
//!
//! Call-origin identifiers are never marked and therefore never renamed, which
//! is exactly the property the measured counter-example needs: the
//! transcriber's `let x` becomes `x__ball_mbe0` while the caller's `x` stays
//! `x` and keeps referring to the caller's binding.
//!
//! ## Keywords and raw identifiers
//!
//! Keywords are `Leaf::Ident`s in token-tree land but not identifiers in Rust,
//! so marking them (`let` → `__ball_mbe_def_let`) would make the expansion
//! unparseable. They are left alone — a keyword is never a binding NAME, so
//! nothing is lost. Raw identifiers (`r#type`) get their own prefix so raw-ness
//! survives the round trip.

use std::collections::{BTreeMap, BTreeSet};

use proc_macro2::Ident;
use syn::visit_mut::VisitMut;

use crate::bridge::Origin;

/// The suffix every α-renamed definition-origin binding carries, before its
/// per-name index. Public so tests — and anyone reading a compiled program —
/// can recognise one.
pub const MANGLE_SUFFIX: &str = "__ball_mbe";

const DEF_PREFIX: &str = "__ball_mbe_def_";
const DEF_RAW_PREFIX: &str = "__ball_mbe_defr_";

/// Rust's keywords — strict, reserved and weak — plus `_`.
///
/// <https://doc.rust-lang.org/reference/keywords.html>
const KEYWORDS: &[&str] = &[
    "_",
    "Self",
    "abstract",
    "as",
    "async",
    "await",
    "become",
    "box",
    "break",
    "const",
    "continue",
    "crate",
    "do",
    "dyn",
    "else",
    "enum",
    "extern",
    "false",
    "final",
    "fn",
    "for",
    "gen",
    "if",
    "impl",
    "in",
    "let",
    "loop",
    "macro",
    "macro_rules",
    "match",
    "mod",
    "move",
    "mut",
    "override",
    "priv",
    "pub",
    "raw",
    "ref",
    "return",
    "safe",
    "self",
    "static",
    "struct",
    "super",
    "trait",
    "true",
    "try",
    "type",
    "typeof",
    "union",
    "unsafe",
    "unsized",
    "use",
    "virtual",
    "where",
    "while",
    "yield",
];

/// The `on_ident` callback the bridge calls for every identifier leaf on the
/// way out of the engine. `dollar_crate` is what a `$crate` metavariable
/// resolves to — never dropped, always rewritten.
pub(crate) fn mark(text: &str, is_raw: bool, origin: Origin, dollar_crate: &str) -> (String, bool) {
    if text == "$crate" {
        return (dollar_crate.to_owned(), false);
    }
    if origin == Origin::Call || KEYWORDS.contains(&text) {
        return (text.to_owned(), is_raw);
    }
    if is_raw {
        (format!("{DEF_RAW_PREFIX}{text}"), false)
    } else {
        (format!("{DEF_PREFIX}{text}"), false)
    }
}

/// The base name behind a mark, and whether it was a raw identifier.
fn unmark(text: &str) -> Option<(String, bool)> {
    if let Some(base) = text.strip_prefix(DEF_RAW_PREFIX) {
        Some((base.to_owned(), true))
    } else {
        text.strip_prefix(DEF_PREFIX)
            .map(|base| (base.to_owned(), false))
    }
}

/// Resolve hygiene over a parsed expansion: collect definition-origin
/// bindings, α-rename them and their definition-origin uses, and unmark
/// everything else.
///
/// `visit` is the caller-supplied traversal — one line per expansion position,
/// because `syn`'s visitor is typed per node kind.
pub(crate) fn resolve<T>(node: &mut T, visit: fn(&mut dyn VisitMut, &mut T)) {
    let mut collect = CollectBindings::default();
    visit(&mut collect, node);

    let mut rename = Rename {
        variables: index(&collect.variables),
    };
    visit(&mut rename, node);
}

/// A deterministic fresh name per collected base name: sorted order, so the
/// same expansion always renames to the same thing.
fn index(names: &BTreeSet<String>) -> BTreeMap<String, String> {
    names
        .iter()
        .enumerate()
        .map(|(n, name)| (name.clone(), format!("{name}{MANGLE_SUFFIX}{n}")))
        .collect()
}

// ── Pass 1: which definition-origin names are bound? ─────────────────────────

#[derive(Default)]
struct CollectBindings {
    variables: BTreeSet<String>,
}

impl VisitMut for CollectBindings {
    fn visit_pat_ident_mut(&mut self, node: &mut syn::PatIdent) {
        if let Some((base, _)) = unmark(&node.ident.to_string()) {
            self.variables.insert(base);
        }
        syn::visit_mut::visit_pat_ident_mut(self, node);
    }
}

// ── Pass 2: rename the bound ones, unmark the rest ───────────────────────────

struct Rename {
    variables: BTreeMap<String, String>,
}

impl Rename {
    /// Rewrite an identifier that sits in a *variable* position.
    fn variable(&self, ident: &mut Ident) {
        let text = ident.to_string();
        let Some((base, was_raw)) = unmark(&text) else {
            return;
        };
        match self.variables.get(&base) {
            Some(fresh) => *ident = Ident::new(fresh, ident.span()),
            None => restore(ident, &base, was_raw),
        }
    }
}

fn restore(ident: &mut Ident, base: &str, was_raw: bool) {
    *ident = if was_raw {
        Ident::new_raw(base, ident.span())
    } else {
        Ident::new(base, ident.span())
    };
}

impl VisitMut for Rename {
    fn visit_pat_ident_mut(&mut self, node: &mut syn::PatIdent) {
        self.variable(&mut node.ident);
        for attr in &mut node.attrs {
            self.visit_attribute_mut(attr);
        }
        if let Some((_, sub)) = &mut node.subpat {
            self.visit_pat_mut(sub);
        }
    }

    fn visit_expr_path_mut(&mut self, node: &mut syn::ExprPath) {
        let bare = node.qself.is_none()
            && node.path.leading_colon.is_none()
            && node.path.segments.len() == 1
            && node.path.segments[0].arguments.is_none();
        if bare {
            self.variable(&mut node.path.segments[0].ident);
            for attr in &mut node.attrs {
                self.visit_attribute_mut(attr);
            }
            return;
        }
        syn::visit_mut::visit_expr_path_mut(self, node);
    }

    /// Everything not handled above: unmark, never rename. Struct fields,
    /// method names, type names and multi-segment path segments all land here.
    fn visit_ident_mut(&mut self, node: &mut Ident) {
        let text = node.to_string();
        if let Some((base, was_raw)) = unmark(&text) {
            restore(node, &base, was_raw);
        }
    }
}
