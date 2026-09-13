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
//!    pattern binding, or a loop/block label) is collected;
//! 2. every marked identifier in a **binding or variable-read or label**
//!    position whose name was collected is α-renamed to a deterministic fresh
//!    name (`<name>__ball_mbe<N>`);
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
//!
//! ## Nested, not-yet-expanded macro invocations
//!
//! Their arguments are an opaque `TokenStream` that `syn` cannot classify, so
//! [`Rename::rewrite_tokens`] works on the tokens themselves, by three rules
//! that each match what Rust does rather than guessing: a MEMBER position (just
//! after a `.` or a `:`, or just before a lone `:`) is never a variable and is
//! left alone; anything else that names a binding this expansion introduced IS
//! a use of it and follows the rename; and a `stringify!`-family argument is
//! **loud**, because those macros turn the argument's spelling into program
//! data and a renamed binding would make the program's own output disagree with
//! its own variable — a behaviour change that round-trips syntactically clean,
//! which is the one failure class a structural measurement cannot see.
//!
//! That last rule is a deliberate narrowing of this feature's design record,
//! which called for a loud error on ANY binding name inside a nested
//! invocation. Measured on the pinned Tier A corpus, the blanket rule moved
//! four files' first blocker BACKWARDS — `bitflags`' `__impl_public_bitflags_consts!`
//! binds `i` and passes it through nested `__bitflags_flag!` invocations, and
//! `itertools`' `impl_tuple_collect!` does the same — so it was loud in exactly
//! the places where nothing was ambiguous.

use std::collections::{BTreeMap, BTreeSet};

use proc_macro2::{Ident, TokenStream, TokenTree};
use syn::visit_mut::VisitMut;

use crate::MacroError;
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
pub(crate) fn resolve<T>(
    macro_name: &str,
    node: &mut T,
    visit: fn(&mut dyn VisitMut, &mut T),
) -> Result<(), MacroError> {
    let mut collect = CollectBindings::default();
    visit(&mut collect, node);

    let index = |set: &BTreeSet<String>| -> BTreeMap<String, String> {
        set.iter()
            .enumerate()
            .map(|(n, name)| (name.clone(), format!("{name}{MANGLE_SUFFIX}{n}")))
            .collect()
    };
    let mut rename = Rename {
        macro_name: macro_name.to_owned(),
        variables: index(&collect.variables),
        labels: index(&collect.labels),
        error: None,
    };
    visit(&mut rename, node);
    match rename.error {
        Some(err) => Err(err),
        None => Ok(()),
    }
}

// ── Pass 1: which definition-origin names are bound? ─────────────────────────

#[derive(Default)]
struct CollectBindings {
    variables: BTreeSet<String>,
    labels: BTreeSet<String>,
}

impl VisitMut for CollectBindings {
    fn visit_pat_ident_mut(&mut self, node: &mut syn::PatIdent) {
        if let Some((base, _)) = unmark(&node.ident.to_string()) {
            self.variables.insert(base);
        }
        syn::visit_mut::visit_pat_ident_mut(self, node);
    }

    fn visit_label_mut(&mut self, node: &mut syn::Label) {
        if let Some((base, _)) = unmark(&node.name.ident.to_string()) {
            self.labels.insert(base);
        }
        syn::visit_mut::visit_label_mut(self, node);
    }
}

// ── Pass 2: rename the bound ones, unmark the rest ───────────────────────────

struct Rename {
    macro_name: String,
    variables: BTreeMap<String, String>,
    labels: BTreeMap<String, String>,
    error: Option<MacroError>,
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

    /// Rewrite an identifier that sits in a *label/lifetime* position.
    fn label(&self, ident: &mut Ident) {
        let text = ident.to_string();
        let Some((base, was_raw)) = unmark(&text) else {
            return;
        };
        match self.labels.get(&base) {
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

    fn visit_lifetime_mut(&mut self, node: &mut syn::Lifetime) {
        self.label(&mut node.ident);
    }

    /// A nested, not-yet-expanded macro invocation. Its arguments are an opaque
    /// `TokenStream` — `syn` cannot say whether an identifier in there is a
    /// variable, a field or a spelling — so this walks the tokens directly; see
    /// [`Rename::rewrite_tokens`] for the three rules and why each is what Rust
    /// itself does.
    fn visit_macro_mut(&mut self, node: &mut syn::Macro) {
        let text_consuming = consumes_arguments_as_text(&node.path);
        for segment in &mut node.path.segments {
            self.visit_path_segment_mut(segment);
        }
        node.tokens = self.rewrite_tokens(std::mem::take(&mut node.tokens), text_consuming);
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

impl Rename {
    /// Rewrite the opaque token soup of a nested macro invocation.
    ///
    /// Three rules, each matching what Rust itself does rather than guessing:
    ///
    /// 1. **A `stringify!`-family argument is left alone, and is LOUD when it
    ///    names a binding this expansion introduced.** Those macros turn their
    ///    argument's *spelling* into program data, and Rust prints the source
    ///    spelling regardless of hygiene — so leaving it is right, but the
    ///    program's own output would then disagree with the variable this pass
    ///    renamed. That divergence round-trips syntactically clean and changes
    ///    behaviour, which is the one failure class a structural measurement
    ///    cannot see, so it is a named error instead.
    /// 2. **An identifier in MEMBER position — immediately after a `.`, or
    ///    immediately before a lone `:` — is left alone.** After a `.` it is a
    ///    field or a method; before a lone `:` it is a struct-literal field or a
    ///    named argument. Neither is ever a variable, so not renaming is
    ///    correct rather than cautious.
    /// 3. **Everything else is renamed like any other definition-origin use.**
    ///    Within ONE expansion, a definition-origin identifier that matches a
    ///    definition-origin binding of that same expansion *is* a use of it —
    ///    that is exactly what the rename rule asserts everywhere `syn` can see
    ///    the position, and the nested invocation is re-expanded as code on the
    ///    driver's next pass, so renaming consistently is what keeps it
    ///    referring to the same binding.
    ///
    /// Rule 3 is a deliberate narrowing of the design record's blanket
    /// "loud on anything inside a nested invocation": measured on the pinned
    /// Tier A corpus, the blanket rule moved four files' first blocker
    /// BACKWARDS (`bitflags`' `__impl_public_bitflags_consts!` binds `i` and
    /// passes it through nested `__bitflags_flag!` invocations; `itertools`'
    /// `impl_tuple_collect!` does the same) — it was loud where nothing was
    /// actually ambiguous.
    fn rewrite_tokens(&mut self, stream: TokenStream, text_consuming: bool) -> TokenStream {
        let trees: Vec<TokenTree> = stream.into_iter().collect();
        let mut out = Vec::with_capacity(trees.len());
        for (index, tree) in trees.iter().enumerate() {
            match tree {
                TokenTree::Group(group) => {
                    let inner = self.rewrite_tokens(group.stream(), text_consuming);
                    let mut rebuilt = proc_macro2::Group::new(group.delimiter(), inner);
                    rebuilt.set_span(group.span());
                    out.push(TokenTree::Group(rebuilt));
                }
                TokenTree::Ident(ident) => {
                    let text = ident.to_string();
                    let Some((base, was_raw)) = unmark(&text) else {
                        out.push(tree.clone());
                        continue;
                    };
                    let bound = self.variables.get(&base).cloned();
                    let member = is_member_position(&trees, index);
                    let rebuilt = match (&bound, text_consuming, member) {
                        (Some(_), true, _) => {
                            if self.error.is_none() {
                                self.error = Some(MacroError::UnclassifiedHygiene {
                                    name: self.macro_name.clone(),
                                    binding: base.clone(),
                                    position: "inside a nested macro invocation that turns its \
                                               argument's spelling into program data \
                                               (`stringify!` and relatives)"
                                        .to_owned(),
                                });
                            }
                            make_ident(&base, was_raw, ident.span())
                        }
                        (Some(fresh), false, false) => make_ident(fresh, false, ident.span()),
                        _ => make_ident(&base, was_raw, ident.span()),
                    };
                    out.push(TokenTree::Ident(rebuilt));
                }
                other => out.push(other.clone()),
            }
        }
        out.into_iter().collect()
    }
}

fn make_ident(text: &str, raw: bool, span: proc_macro2::Span) -> Ident {
    if raw {
        Ident::new_raw(text, span)
    } else {
        Ident::new(text, span)
    }
}

/// Is the identifier at `index` a struct field, a tuple index, a method name or
/// a path segment rather than a variable? See [`Rename::rewrite_tokens`] rule 2.
fn is_member_position(trees: &[TokenTree], index: usize) -> bool {
    // Straight after a `.` (a field or a method) or after a `:` (the tail
    // segment of a `::`-joined path, which is resolved by name, not by scope).
    let after_separator = index.checked_sub(1).and_then(|i| trees.get(i)).is_some_and(
        |t| matches!(t, TokenTree::Punct(p) if p.as_char() == '.' || p.as_char() == ':'),
    );
    // Straight before a LONE `:` — `Spacing::Alone` — so a struct-literal field
    // is caught while `a::b`'s joint `::` is not mistaken for one.
    let before_colon = trees.get(index + 1).is_some_and(|t| {
        matches!(t, TokenTree::Punct(p)
            if p.as_char() == ':' && p.spacing() == proc_macro2::Spacing::Alone)
    });
    after_separator || before_colon
}

/// Does this macro turn its argument's SPELLING into program data?
///
/// <https://doc.rust-lang.org/std/macro.stringify.html> — "Stringifies its
/// arguments" — and its relatives, which take tokens or a path rather than an
/// evaluated expression. Renaming inside one changes what the program prints,
/// reads or compiles against.
fn consumes_arguments_as_text(path: &syn::Path) -> bool {
    const TEXTUAL: &[&str] = &[
        "cfg",
        "compile_error",
        "concat",
        "env",
        "include",
        "include_bytes",
        "include_str",
        "option_env",
        "stringify",
    ];
    // The path's own segments may still be MARKED at this point (a macro name
    // the transcriber wrote is definition-origin like any other identifier), so
    // compare the base name, not the marked spelling.
    path.segments.last().is_some_and(|segment| {
        let text = segment.ident.to_string();
        let base = unmark(&text).map_or(text, |(base, _)| base);
        TEXTUAL.contains(&base.as_str())
    })
}
