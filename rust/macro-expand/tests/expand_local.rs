//! Slice 2 of issue #629 — expansion of a LOCAL `macro_rules!`, items and
//! expressions.
//!
//! These are the eight probe cases the design of record was built on, turned
//! into tests. Each one is load-bearing for a decision the driver makes:
//!
//! 1. item position produces items,
//! 2. a `bitflags!`-shaped macro (meta repetitions, doc comments, nested
//!    repetitions) works,
//! 3. expression position produces an expression,
//! 4. an arity mismatch is a returned `Err`, never a silent empty expansion,
//! 5. a self-recursive macro comes back **partly expanded**, which is why the
//!    driver must iterate to a fixed point rather than expanding once,
//! 6. hygiene is not free (see `hygiene.rs` for the resolution),
//! 7. `$crate` must be rewritten, never dropped,
//! 8. a string literal's escapes survive.

use ball_lang_macro_expand::{Expanded, Expansion, MacroError, MacroOrigin, MacroTable, Route};
use quote::ToTokens;

/// A table holding every `macro_rules!` in `source`, as local definitions.
fn table_from(source: &str) -> MacroTable {
    let file: syn::File = syn::parse_str(source).expect("the test's own source must parse");
    let mut table = MacroTable::new();
    for item in &file.items {
        if let syn::Item::Macro(item_macro) = item {
            if item_macro.ident.is_some() {
                table
                    .insert_macro_rules(
                        item_macro,
                        MacroOrigin::LocalCrate {
                            module: "main".to_owned(),
                        },
                    )
                    .expect("the test's own macro_rules must be parseable");
            }
        }
    }
    table
}

fn invocation(source: &str) -> syn::Macro {
    let item: syn::Item = syn::parse_str(source).expect("the test's own invocation must parse");
    match item {
        syn::Item::Macro(item_macro) => item_macro.mac,
        other => panic!("expected a macro invocation, got {other:?}"),
    }
}

fn expr_invocation(source: &str) -> syn::Macro {
    let expr: syn::Expr = syn::parse_str(source).expect("the test's own invocation must parse");
    match expr {
        syn::Expr::Macro(expr_macro) => expr_macro.mac,
        other => panic!("expected a macro invocation, got {other:?}"),
    }
}

fn rendered(expanded: &Expanded) -> String {
    match expanded {
        Expanded::Items(items) => items
            .iter()
            .map(|item| item.to_token_stream().to_string())
            .collect::<Vec<_>>()
            .join(" "),
        Expanded::Expr(expr) => expr.to_token_stream().to_string(),
        Expanded::Stmts(stmts) => stmts
            .iter()
            .map(|stmt| stmt.to_token_stream().to_string())
            .collect::<Vec<_>>()
            .join(" "),
        Expanded::ImplItems(items) => items
            .iter()
            .map(|item| item.to_token_stream().to_string())
            .collect::<Vec<_>>()
            .join(" "),
        Expanded::TraitItems(items) => items
            .iter()
            .map(|item| item.to_token_stream().to_string())
            .collect::<Vec<_>>()
            .join(" "),
    }
}

// ── Probe 1: a local macro_rules producing a struct + impl ───────────────────

#[test]
fn an_item_position_macro_produces_items() {
    let table = table_from(
        "macro_rules! make_point {
            ($name:ident, $field:ident) => {
                pub struct $name { pub $field: i64 }
                impl $name { pub fn get(&self) -> i64 { self.$field } }
            };
        }",
    );
    let expanded = table
        .expand(&invocation("make_point!(Point, x);"), Expansion::Items)
        .expect("make_point! must expand");
    let Expanded::Items(items) = &expanded else {
        panic!("expected items, got {expanded:?}");
    };
    assert_eq!(items.len(), 2, "expected a struct and an impl: {items:?}");
    let text = rendered(&expanded);
    assert!(text.contains("struct Point"), "{text}");
    assert!(text.contains("pub x : i64"), "{text}");
    assert!(text.contains("self . x"), "{text}");
}

// ── Probe 2: bitflags-shaped — meta repetition, doc comments, nesting ────────

#[test]
fn a_bitflags_shaped_macro_expands() {
    let table = table_from(
        r#"macro_rules! flags {
            (
                $(#[$outer:meta])*
                $vis:vis struct $name:ident {
                    $( $(#[$inner:meta])* $flag:ident = $value:expr; )*
                }
            ) => {
                $(#[$outer])*
                $vis struct $name { pub bits: u8 }
                impl $name {
                    $( $(#[$inner])* $vis fn $flag(&self) -> u8 { $value } )*
                }
            };
        }"#,
    );
    let expanded = table
        .expand(
            &invocation(
                "flags! {
                    /// Permission bits.
                    pub struct Perms {
                        /// Read.
                        read = 1;
                        /// Write.
                        write = (1 << 1);
                    }
                }",
            ),
            Expansion::Items,
        )
        .expect("flags! must expand");
    let text = rendered(&expanded);
    assert!(text.contains("pub struct Perms"), "{text}");
    assert!(text.contains("fn read"), "{text}");
    assert!(text.contains("fn write"), "{text}");
    assert!(
        text.contains("doc = \" Permission bits.\""),
        "the outer doc comment must survive as a `#[doc]` attribute: {text}"
    );
    assert!(
        text.contains("doc = \" Read.\""),
        "the inner doc comment must survive: {text}"
    );
}

// ── Probe 3: expression position ─────────────────────────────────────────────

#[test]
fn an_expression_position_macro_produces_an_expression() {
    let table = table_from("macro_rules! twice { ($e:expr) => { ($e) * 2 }; }");
    let expanded = table
        .expand(&expr_invocation("twice!(3 + 4)"), Expansion::Expr)
        .expect("twice! must expand");
    assert!(matches!(expanded, Expanded::Expr(_)), "{expanded:?}");
    assert_eq!(rendered(&expanded).replace(' ', ""), "((3+4))*2");
}

// ── Probe 4: an arity mismatch is a returned error ───────────────────────────

#[test]
fn an_arity_mismatch_is_a_loud_error_not_an_empty_expansion() {
    let table = table_from("macro_rules! one { ($a:ident) => { struct $a; }; }");
    let err = table
        .expand(&invocation("one!(A, B);"), Expansion::Items)
        .expect_err("two arguments must not match a one-argument rule");
    assert!(
        matches!(err, MacroError::NoExpansion { .. }),
        "expected NoExpansion, got {err:?}"
    );
    let message = err.to_string();
    assert!(message.contains("one!"), "{message}");
    assert!(
        message.contains("Arguments were: A , B") || message.contains("Arguments were: A, B"),
        "the error must quote the arguments: {message}"
    );
}

// ── Probe 5: a self-recursive macro needs a FIXED POINT, not one pass ────────

#[test]
fn a_self_recursive_macro_is_not_fully_expanded_in_one_pass() {
    let table = table_from(
        "macro_rules! sum {
            ($a:expr) => { $a };
            ($a:expr, $($rest:expr),+) => { $a + sum!($($rest),+) };
        }",
    );
    let expanded = table
        .expand(&expr_invocation("sum!(1, 2, 3)"), Expansion::Expr)
        .expect("sum! must expand");
    let text = rendered(&expanded);
    assert!(
        text.contains("sum !"),
        "one pass must leave the inner invocation in place — that is why the driver iterates: \
         {text}"
    );
}

// ── Probe 6: hygiene (see hygiene.rs for the resolution this enables) ────────

#[test]
fn a_definition_origin_binding_does_not_capture_the_callers_name() {
    let table = table_from("macro_rules! plus { ($e:expr) => {{ let x = 1; $e + x }}; }");
    let expanded = table
        .expand(&expr_invocation("plus!(x)"), Expansion::Expr)
        .expect("plus! must expand");
    let text = rendered(&expanded).replace(' ', "");
    assert!(
        text.contains("letx__ball_mbe0=1"),
        "the transcriber's own binding must be renamed: {text}"
    );
    assert!(
        text.contains("x+x__ball_mbe0"),
        "the caller's `x` must stay `x` and the transcriber's use must follow the rename: {text}"
    );
}

// ── Probe 7: `$crate` is rewritten, never dropped ────────────────────────────

#[test]
fn dollar_crate_is_rewritten_for_a_local_definition() {
    let table = table_from("macro_rules! call { () => { $crate::helper() }; }");
    let expanded = table
        .expand(&expr_invocation("call!()"), Expansion::Expr)
        .expect("call! must expand");
    let text = rendered(&expanded).replace(' ', "");
    assert_eq!(text, "crate::helper()");
}

// ── Probe 8: string literal escapes survive the engine ───────────────────────

#[test]
fn string_literal_escapes_survive_expansion() {
    let table = table_from(r#"macro_rules! two { () => { join("a\nb", "c\td") }; }"#);
    let expanded = table
        .expand(&expr_invocation("two!()"), Expansion::Expr)
        .expect("two! must expand");
    let text = rendered(&expanded).replace(' ', "");
    assert_eq!(text, r#"join("a\nb","c\td")"#);
}

// ── Resolution: builtins are never expanded, unknowns are loud ───────────────

#[test]
fn a_builtin_macro_is_never_routed_through_the_expander() {
    let table = table_from("macro_rules! unused { () => {}; }");
    for source in [
        "println!(\"x\")",
        "vec![1]",
        "assert!(true)",
        "write!(f, \"x\")",
    ] {
        assert_eq!(
            table.route(&expr_invocation(source)),
            Route::Builtin,
            "`{source}` must be left to the encoder's own semantic lowering"
        );
    }
    assert_eq!(
        table.route(&expr_invocation("alloc::vec![1]")),
        Route::Builtin,
        "an `alloc::`/`core::`/`std::`-qualified builtin is still a builtin"
    );
}

/// The three routes are deliberately distinct: a name nothing defines is the
/// proc-macro boundary the encoder reports better, while a name that SHOULD
/// have been reachable is a named failure that must not be flattened into
/// "unsupported".
#[test]
fn an_unknown_name_and_an_unreachable_dependency_route_differently() {
    let mut table = table_from("macro_rules! known { () => { 1 }; }");
    assert_eq!(table.route(&expr_invocation("known!()")), Route::Expand);
    assert_eq!(
        table.route(&expr_invocation("some_proc_macro!()")),
        Route::Unknown
    );
    table.set_dependencies_unavailable("no manifest was read".to_owned());
    let Route::Failed(err) = table.route(&expr_invocation("dep::thing!()")) else {
        panic!("a dependency-path macro with no dependency graph must be a named failure");
    };
    assert!(
        matches!(err, MacroError::DependenciesUnavailable { .. }),
        "{err:?}"
    );
    assert!(err.to_string().contains("no manifest was read"), "{err}");
}

#[test]
fn an_unresolvable_macro_names_what_was_in_scope() {
    let table = table_from("macro_rules! known { () => { 1 }; }");
    let err = table
        .expand(&expr_invocation("unknown!()"), Expansion::Expr)
        .expect_err("an undefined macro must not expand");
    let message = err.to_string();
    assert!(
        message.contains("cannot resolve the macro `unknown!`"),
        "{message}"
    );
    assert!(
        message.contains("known"),
        "the error must list what WAS in scope: {message}"
    );
}

/// Textual scope is approximated by a crate-wide lookup; the ambiguity check is
/// what keeps that approximation honest. Two definitions with the *same* rules
/// (heck defines `t!` once per test module) are not an ambiguity.
#[test]
fn two_definitions_with_differing_rules_are_ambiguous() {
    let mut table = table_from("macro_rules! dup { () => { 1 }; }");
    let other: syn::File = syn::parse_str("macro_rules! dup { () => { 2 }; }").unwrap();
    let syn::Item::Macro(item) = &other.items[0] else {
        unreachable!()
    };
    table
        .insert_macro_rules(
            item,
            MacroOrigin::LocalCrate {
                module: "other".to_owned(),
            },
        )
        .unwrap();
    let err = table
        .expand(&expr_invocation("dup!()"), Expansion::Expr)
        .expect_err("two differing definitions must not silently pick one");
    assert!(
        matches!(err, MacroError::Ambiguous { .. }),
        "expected Ambiguous, got {err:?}"
    );
}

#[test]
fn an_identical_redefinition_is_not_an_ambiguity() {
    let mut table = table_from("macro_rules! same { () => { 1 }; }");
    let other: syn::File = syn::parse_str("macro_rules! same { () => { 1 }; }").unwrap();
    let syn::Item::Macro(item) = &other.items[0] else {
        unreachable!()
    };
    table
        .insert_macro_rules(
            item,
            MacroOrigin::LocalCrate {
                module: "other".to_owned(),
            },
        )
        .unwrap();
    let expanded = table
        .expand(&expr_invocation("same!()"), Expansion::Expr)
        .expect("an identical redefinition must still resolve");
    assert_eq!(rendered(&expanded), "1");
}

// ── Statement position ───────────────────────────────────────────────────────

#[test]
fn a_statement_position_macro_produces_statements() {
    let table =
        table_from("macro_rules! declare { ($n:ident) => { let $n = 1; let _unused = $n; }; }");
    let expanded = table
        .expand(&invocation("declare!(a);"), Expansion::Stmts)
        .expect("declare! must expand");
    let Expanded::Stmts(stmts) = &expanded else {
        panic!("expected statements, got {expanded:?}");
    };
    assert_eq!(stmts.len(), 2, "{stmts:?}");
}
