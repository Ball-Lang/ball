//! Slice 1 of issue #629 — the token bridge, as a property test.
//!
//! Everything downstream rests on one identity: a `proc_macro2::TokenStream`
//! converted into the engine's `ra_ap_tt` representation and back must be
//! **token-identical**. An expansion that survives the engine but is mangled on
//! the way back out is indistinguishable from a miscompile, and `syn` would
//! happily parse most of the mangled forms.
//!
//! The comparison here is structural, not `to_string()` — same token kinds,
//! same delimiters, same spellings, same punct spacing, all the way down. Two
//! different token streams can print the same (`a + b` vs `a+b`), so comparing
//! rendered text would pass a bridge that silently re-spaced everything.

use proc_macro2::{Delimiter, Spacing, TokenStream, TokenTree};

use ball_lang_macro_expand::round_trip_tokens;

/// Structural token equality: kinds, spellings, delimiters and punct spacing,
/// recursively. `proc_macro2`'s own `PartialEq` compares spans too, which are
/// deliberately not preserved (the bridge stamps its own).
fn same_tokens(left: &TokenStream, right: &TokenStream) -> bool {
    let left: Vec<TokenTree> = left.clone().into_iter().collect();
    let right: Vec<TokenTree> = right.clone().into_iter().collect();
    if left.len() != right.len() {
        return false;
    }
    left.iter().zip(right.iter()).all(|(a, b)| match (a, b) {
        (TokenTree::Group(a), TokenTree::Group(b)) => {
            a.delimiter() == b.delimiter() && same_tokens(&a.stream(), &b.stream())
        }
        (TokenTree::Ident(a), TokenTree::Ident(b)) => a.to_string() == b.to_string(),
        (TokenTree::Punct(a), TokenTree::Punct(b)) => {
            a.as_char() == b.as_char() && a.spacing() == b.spacing()
        }
        (TokenTree::Literal(a), TokenTree::Literal(b)) => a.to_string() == b.to_string(),
        _ => false,
    })
}

#[track_caller]
fn assert_round_trips(source: &str) {
    let original: TokenStream = source
        .parse()
        .unwrap_or_else(|err| panic!("the test's own input does not lex: {source} ({err})"));
    let round_tripped = round_trip_tokens(original.clone())
        .unwrap_or_else(|err| panic!("round trip of `{source}` failed: {err}"));
    assert!(
        same_tokens(&original, &round_tripped),
        "round trip of `{source}` changed the tokens:\n  before: {original:?}\n  after:  {round_tripped:?}"
    );
}

#[test]
fn nested_delimiters_round_trip() {
    assert_round_trips("fn f(a: [u8; 4]) -> (i32, i32) { { let x = [1, 2]; (x[0], x[1]) } }");
}

/// `Delimiter::None` is a real delimiter `proc_macro2` can carry and
/// `ra_ap_tt` spells `DelimiterKind::Invisible`. It cannot be written in
/// source, so it is built by hand.
#[test]
fn an_invisible_group_round_trips() {
    let inner: TokenStream = "1 + 2".parse().unwrap();
    let original: TokenStream = std::iter::once(TokenTree::Group(proc_macro2::Group::new(
        Delimiter::None,
        inner,
    )))
    .collect();
    let round_tripped = round_trip_tokens(original.clone()).expect("invisible group round trip");
    assert!(
        same_tokens(&original, &round_tripped),
        "an invisible group did not survive: {round_tripped:?}"
    );
}

#[test]
fn raw_identifiers_round_trip() {
    assert_round_trips("let r#type = r#fn;");
}

/// Glued puncts: `proc_macro2` lexes `::` as two `Punct`s, the first `Joint`.
/// Losing the spacing re-lexes `a::b` as `a : : b`, which `syn` rejects.
#[test]
fn glued_puncts_keep_their_spacing() {
    assert_round_trips("a::b ..= c => d ..");
    let stream: TokenStream = "a::b".parse().unwrap();
    let trees: Vec<TokenTree> = round_trip_tokens(stream).unwrap().into_iter().collect();
    match &trees[1] {
        TokenTree::Punct(p) => assert_eq!(p.spacing(), Spacing::Joint),
        other => panic!("expected the first `:` of `::` to be a punct, got {other:?}"),
    }
}

/// The measured pitfall: `ra_ap_tt::Literal::text()` is the token text *minus*
/// its quotes and *with* its escapes intact, so rebuilding with
/// `proc_macro2::Literal::string(text)` double-escapes — `"a\nb"` comes back as
/// `"a\\nb"`, a two-character escape turned into a literal backslash.
#[test]
fn string_literals_with_escapes_are_not_double_escaped() {
    assert_round_trips(r#"let s = "a\nb"; let t = "c\td"; let u = "quote\"inside";"#);
    let round_tripped = round_trip_tokens(r#""a\nb""#.parse().unwrap()).unwrap();
    assert_eq!(round_tripped.to_string(), r#""a\nb""#);
}

#[test]
fn char_byte_and_cstring_literals_round_trip() {
    assert_round_trips(r#"let c = 'x'; let n = '\n'; let b = b'z'; let bs = b"bytes";"#);
    assert_round_trips(r#"let cs = c"cstr";"#);
}

#[test]
fn raw_string_literals_round_trip() {
    assert_round_trips("let r = r\"plain\"; let h = r#\"with \" quote\"#;");
}

#[test]
fn suffixed_numeric_literals_round_trip() {
    assert_round_trips("let a = 1u8; let b = 2_000i64; let c = 1.5f32; let d = 0xFFu32;");
}

/// A doc comment is not a token at all: `proc_macro2` lexes `/// x` into
/// `# [doc = " x"]`. That is exactly why this bridge never goes through text —
/// `ra_ap_syntax_bridge::parse_to_token_tree` panics on the source form.
#[test]
fn doc_comments_round_trip_as_doc_attributes() {
    let original: TokenStream = "/// hello\nstruct S;".parse().unwrap();
    let round_tripped = round_trip_tokens(original.clone()).expect("doc comment round trip");
    assert!(
        same_tokens(&original, &round_tripped),
        "a doc comment did not survive: {round_tripped:?}"
    );
    assert!(
        round_tripped.to_string().contains("doc"),
        "the doc attribute vanished: {round_tripped}"
    );
}

#[test]
fn a_whole_macro_rules_body_round_trips() {
    assert_round_trips(
        r#"
        ($(#[$outer:meta])* $vis:vis struct $name:ident { $($field:ident),* $(,)? }) => {
            $(#[$outer])*
            $vis struct $name { $(pub $field: i64,)* }
            impl $name { $vis fn total(&self) -> i64 { 0 $(+ self.$field)* } }
        };
        "#,
    );
}
