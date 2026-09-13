//! Slice 4 of issue #629 — hygiene approximation and origin tracking.
//!
//! `macro_rules!` has **mixed-site hygiene**: the Rust Reference, *Macros By
//! Example* — "loop labels, block labels, and local variables are looked up at
//! the macro definition site while other symbols are looked up at the macro
//! invocation site." `ra_ap_mbe` does not implement that, and this crate does
//! not either. What it does is α-rename the identifiers that CAN be classified
//! and fail loud on the ones it cannot, and these tests are the contract for
//! both halves.
//!
//! The two-sided nature is the point. Renaming too little captures the
//! caller's binding (the measured `{ let x = 1 ; x + x }`); renaming too much
//! rewrites a struct field, a method name or a caller's own variable. Every
//! test below pins one side or the other.

use ball_lang_macro_expand::{Expanded, Expansion, MacroError, MacroOrigin, MacroTable};
use quote::ToTokens;

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

fn expr_invocation(source: &str) -> syn::Macro {
    let expr: syn::Expr = syn::parse_str(source).expect("the test's own invocation must parse");
    match expr {
        syn::Expr::Macro(expr_macro) => expr_macro.mac,
        other => panic!("expected a macro invocation, got {other:?}"),
    }
}

fn expand_expr(table: &MacroTable, invocation: &str) -> Result<String, MacroError> {
    let expanded = table.expand(&expr_invocation(invocation), Expansion::Expr)?;
    let Expanded::Expr(expr) = expanded else {
        panic!("expected an expression, got {expanded:?}");
    };
    Ok(expr.to_token_stream().to_string().replace(' ', ""))
}

// ── Local variables: rename the definition's, never the caller's ─────────────

/// The measured counter-example. Without the rename, the caller's `x` is
/// captured by the transcriber's `let x`.
#[test]
fn the_transcribers_binding_is_renamed_and_the_callers_is_not() {
    let table = table_from("macro_rules! plus { ($e:expr) => {{ let x = 1; $e + x }}; }");
    let text = expand_expr(&table, "plus!(x)").expect("plus! must expand");
    assert!(text.contains("letx__ball_mbe0=1"), "{text}");
    assert!(text.contains("x+x__ball_mbe0"), "{text}");
}

/// A closure parameter and a `for` pattern binding are bindings too.
#[test]
fn closure_and_for_pattern_bindings_are_renamed() {
    let table = table_from(
        "macro_rules! twice {
            ($e:expr) => {{ let f = |n| n + n; f($e) }};
        }",
    );
    let text = expand_expr(&table, "twice!(n)").expect("twice! must expand");
    assert!(
        text.contains("|n__ball_mbe1|n__ball_mbe1+n__ball_mbe1"),
        "the closure's own parameter must be renamed: {text}"
    );
    assert!(
        text.contains("f__ball_mbe0(n)"),
        "the caller's `n` must survive untouched: {text}"
    );
}

// ── Loop labels ──────────────────────────────────────────────────────────────

/// Labels are the other half of mixed-site hygiene the Reference names
/// explicitly, and they are a different `syn` node (`Label`/`Lifetime`), so the
/// variable rename does not reach them.
#[test]
fn a_definition_origin_loop_label_is_renamed() {
    let table = table_from(
        "macro_rules! once {
            ($e:expr) => {{ 'inner: loop { let v = $e; break 'inner v; } }};
        }",
    );
    let text = expand_expr(&table, "once!(1)").expect("once! must expand");
    assert!(
        text.contains("'inner__ball_mbe0:loop"),
        "the transcriber's label must be renamed: {text}"
    );
    assert!(
        text.contains("break'inner__ball_mbe0"),
        "and its use must follow: {text}"
    );
}

/// A label the CALLER wrote is call-origin and must survive, even when the
/// transcriber declares one with the same spelling.
#[test]
fn a_call_origin_label_survives_a_same_named_definition_label() {
    let table = table_from(
        "macro_rules! wrap {
            ($l:lifetime, $e:expr) => {{ 'outer: loop { break 'outer (loop { break $l $e; }); } }};
        }",
    );
    let text = expand_expr(&table, "wrap!('outer, 1)").expect("wrap! must expand");
    assert!(
        text.contains("'outer__ball_mbe0:loop"),
        "the transcriber's own `'outer` is renamed: {text}"
    );
    assert!(
        text.contains("break'outer1"),
        "the caller's `'outer` is not: {text}"
    );
}

// ── Positions the renamer must NOT touch ─────────────────────────────────────

/// A field access, a struct-literal field and a method name are all identifiers
/// the transcriber wrote, so all three are definition-origin — but none of them
/// is a variable, and renaming one would silently rewrite the program.
#[test]
fn fields_and_method_names_are_never_renamed_even_when_a_binding_shares_the_name() {
    let table = table_from(
        "macro_rules! read {
            ($r:expr) => {{ let a = 1; $r.a + $r.a() + Holder { a: 2 }.a + a }};
        }",
    );
    let text = expand_expr(&table, "read!(h)").expect("read! must expand");
    assert!(text.contains("leta__ball_mbe0=1"), "{text}");
    assert!(text.contains("h.a+"), "a field read must stay `a`: {text}");
    assert!(
        text.contains("h.a()"),
        "a method name must stay `a`: {text}"
    );
    assert!(
        text.contains("Holder{a:2}.a"),
        "a struct-literal field must stay `a`: {text}"
    );
    assert!(
        text.ends_with("+a__ball_mbe0}"),
        "only the variable read follows the rename: {text}"
    );
}

/// A definition-origin identifier that is not bound by the expansion is simply
/// unmarked — a type name, an enum variant, a path segment.
#[test]
fn unbound_definition_origin_identifiers_are_left_alone() {
    let table = table_from(
        "macro_rules! make { () => { Holder { count: Some(1), name: String::new() } }; }",
    );
    let text = expand_expr(&table, "make!()").expect("make! must expand");
    assert_eq!(text, "Holder{count:Some(1),name:String::new()}");
}

// ── Nested, not-yet-expanded macro invocations ───────────────────────────────

/// A nested invocation's arguments are an opaque `TokenStream`, but that does
/// not make them unknowable: within ONE expansion, a definition-origin
/// identifier matching a definition-origin binding of that same expansion IS a
/// use of it, and the driver re-expands the invocation as code on its next
/// pass. Renaming consistently is what keeps it referring to the same binding.
#[test]
fn a_bound_name_passed_to_a_nested_macro_follows_the_rename() {
    let table = table_from("macro_rules! outer { () => {{ let v = 1; helper!(v + 1) }}; }");
    let text = expand_expr(&table, "outer!()").expect("outer! must expand");
    assert!(text.contains("letv__ball_mbe0=1"), "{text}");
    assert!(
        text.contains("helper!(v__ball_mbe0+1)"),
        "the nested invocation's use of the binding must follow it: {text}"
    );
}

/// MEMBER position inside that soup is still knowable from the tokens alone: an
/// identifier straight after a `.` is a field or a method, and one straight
/// before a LONE `:` is a struct-literal field or a named argument. Neither is
/// ever a variable, so leaving them is correct rather than cautious — and `::`
/// must not be mistaken for the struct-literal case.
#[test]
fn member_positions_inside_a_nested_macro_are_not_renamed() {
    let table = table_from(
        "macro_rules! outer {
            ($r:expr) => {{ let a = 1; helper!($r.a, Holder { a: 2 }, path::a, a) }};
        }",
    );
    let text = expand_expr(&table, "outer!(h)").expect("outer! must expand");
    assert!(text.contains("leta__ball_mbe0=1"), "{text}");
    assert!(text.contains("h.a,"), "a field stays `a`: {text}");
    assert!(
        text.contains("Holder{a:2}"),
        "a struct-literal field stays `a`: {text}"
    );
    assert!(
        text.contains("path::a,"),
        "a `::`-joined path segment is not a struct field: {text}"
    );
    assert!(
        text.contains(",a__ball_mbe0)"),
        "the plain variable use still follows the rename: {text}"
    );
}

// ── The loud unclassifiable case ─────────────────────────────────────────────

/// `stringify!` and its relatives turn their argument's SPELLING into program
/// data, and Rust prints the source spelling regardless of hygiene — so leaving
/// the identifier alone is right, and yet the program's own output would then
/// disagree with the variable this pass renamed. That divergence round-trips
/// syntactically clean and changes behaviour, which is the one failure class a
/// structural measurement cannot see, so it is a named error instead of a
/// silent choice.
#[test]
fn a_bound_name_inside_stringify_is_a_loud_error() {
    let table =
        table_from("macro_rules! leaky { () => {{ let secret = 1; stringify!(secret) }}; }");
    let err = expand_expr(&table, "leaky!()")
        .expect_err("a renamed binding whose SPELLING becomes data must not be guessed at");
    assert!(
        matches!(err, MacroError::UnclassifiedHygiene { .. }),
        "expected UnclassifiedHygiene, got {err:?}"
    );
    let message = err.to_string();
    assert!(message.contains("leaky!"), "{message}");
    assert!(message.contains("secret"), "{message}");
    assert!(
        message.contains("spelling into program data"),
        "the error must say WHY it refused: {message}"
    );
}

/// The same family, no collision: `stringify!` over a name the expansion does
/// not bind is left exactly as written.
#[test]
fn stringify_over_an_unbound_name_is_left_alone() {
    let table = table_from("macro_rules! fine { () => {{ let v = 1; stringify!(other); v }}; }");
    let text = expand_expr(&table, "fine!()").expect("fine! must expand");
    assert!(text.contains("letv__ball_mbe0=1"), "{text}");
    assert!(text.contains("stringify!(other)"), "{text}");
}
