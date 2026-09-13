//! The token bridge: `proc_macro2::TokenStream` ⇄ `ra_ap_tt::TopSubtree`.
//!
//! ## Why not go through text
//!
//! The obvious route — print the invocation, hand the text to
//! `ra_ap_syntax_bridge::parse_to_token_tree`, expand, print the result, hand
//! *that* to `syn::parse_str` — is broken at both ends, measured:
//!
//! - `parse_to_token_tree` **panics** on a doc comment: it routes them through
//!   `ra_ap_syntax::ast::make::tokens::doc_comment`, which `unwrap()`s a parse
//!   that fails. Doc comments are everywhere in the code this encoder is
//!   pointed at.
//! - `SyntaxNode::to_string()` on an expansion emits **no whitespace at all**
//!   (`pubstructPoint{pubx:i64…`), which then fails `syn::parse_file` with
//!   `expected \`!\``.
//!
//! `syn` already holds the tokens — `syn::ItemMacro.mac.tokens` for a
//! definition's rules, `syn::Macro.tokens` for an invocation's arguments — so
//! this walks those directly and never constructs or parses text.
//!
//! ## The two fixed span anchors
//!
//! Every token of a DEFINITION is stamped with anchor file 0, every token of an
//! INVOCATION with anchor file 1. That is all `ra_ap_mbe` needs from a span,
//! and it makes `span.anchor.file_id.file_id().index()` a reliable
//! **def-origin vs call-origin** discriminator on every OUTPUT token — which is
//! what [`crate::hygiene`] needs and what `ra_ap_mbe` alone does not otherwise
//! give you (it is not hygienic on its own).
//!
//! ## Measured pitfalls, both load-bearing
//!
//! - **String literals must be rebuilt with their quotes.** For
//!   `LitKind::Str`, `Literal::text()` returns the token text *without* its
//!   quotes and *with* its escapes intact, so
//!   `proc_macro2::Literal::string(l.text())` double-escapes (`"a\nb"` comes
//!   back as `"a\\nb"`). The correct reconstruction is
//!   `format!("\"{}\"{}", text, suffix).parse::<Literal>()`.
//! - **`Spacing::JointHidden` maps to `proc_macro2::Spacing::Joint`.**
//!   `ra_ap_tt` distinguishes a joint punct that had no source text between it
//!   and the next token from one that did; `proc_macro2` does not.

use proc_macro2::{
    Delimiter as PmDelimiter, Group, Ident as PmIdent, Literal as PmLiteral, Punct as PmPunct,
    Spacing as PmSpacing, TokenStream, TokenTree as PmTokenTree,
};
use ra_ap_intern::Symbol;
use ra_ap_span::{
    Edition, EditionedFileId, FileId, ROOT_ERASED_FILE_AST_ID, SpanAnchor, SyntaxContext,
};
use ra_ap_tt::iter::TtElement;
use ra_ap_tt::{
    Delimiter, DelimiterKind, Ident, IdentIsRaw, Leaf, LitKind, Punct, Spacing, Span, TextRange,
    TextSize, TopSubtree, TopSubtreeBuilder, token_to_literal,
};

use crate::MacroError;

/// The span anchor every token of a macro DEFINITION carries.
pub(crate) const DEF_FILE: u32 = 0;
/// The span anchor every token of a macro INVOCATION carries.
pub(crate) const CALL_FILE: u32 = 1;

/// Where a token in an expansion came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Origin {
    /// Transcribed literally out of the macro's definition.
    Definition,
    /// Substituted in from the invocation's arguments.
    Call,
}

/// A span anchored at `file`, with an empty range and the root syntax context.
///
/// `EditionedFileId::new` is `#[deprecated]` upstream (rust-analyzer routes
/// file ids through its salsa database) but is the only constructor reachable
/// from outside that database, and rust-analyzer's own `mbe` tests build spans
/// exactly this way.
pub(crate) fn span(file: u32) -> Span {
    #[allow(deprecated)]
    let file_id = EditionedFileId::new(FileId::from_raw(file), Edition::CURRENT);
    Span {
        range: TextRange::empty(TextSize::new(0)),
        anchor: SpanAnchor {
            file_id,
            ast_id: ROOT_ERASED_FILE_AST_ID,
        },
        ctx: SyntaxContext::root(Edition::CURRENT),
    }
}

/// Which anchor a span carries.
pub(crate) fn origin_of(span: Span) -> Origin {
    if span.anchor.file_id.file_id().index() == DEF_FILE {
        Origin::Definition
    } else {
        Origin::Call
    }
}

// ════════════════════════════════════════════════════════════
// proc_macro2 -> ra_ap_tt
// ════════════════════════════════════════════════════════════

/// Convert a `proc_macro2` token stream into a `ra_ap_tt` top-level subtree,
/// stamping every token with `span`.
pub(crate) fn to_subtree(stream: TokenStream, sp: Span) -> TopSubtree {
    let mut builder = TopSubtreeBuilder::new(Delimiter {
        open: sp,
        close: sp,
        kind: DelimiterKind::Invisible,
    });
    push_stream(&mut builder, stream, sp);
    builder.build()
}

fn push_stream(builder: &mut TopSubtreeBuilder, stream: TokenStream, sp: Span) {
    for tree in stream {
        match tree {
            PmTokenTree::Group(group) => {
                builder.open(delimiter_kind(group.delimiter()), sp);
                push_stream(builder, group.stream(), sp);
                builder.close(sp);
            }
            PmTokenTree::Ident(ident) => {
                let text = ident.to_string();
                let (is_raw, sym) = IdentIsRaw::split_from_symbol(&text);
                builder.push(Leaf::Ident(Ident {
                    sym: Symbol::intern(sym),
                    span: sp,
                    is_raw,
                }));
            }
            PmTokenTree::Punct(punct) => {
                builder.push(Leaf::Punct(Punct {
                    char: punct.as_char(),
                    spacing: match punct.spacing() {
                        PmSpacing::Alone => Spacing::Alone,
                        PmSpacing::Joint => Spacing::Joint,
                    },
                    span: sp,
                }));
            }
            PmTokenTree::Literal(literal) => {
                builder.push(Leaf::Literal(token_to_literal(&literal.to_string(), sp)));
            }
        }
    }
}

fn delimiter_kind(delimiter: PmDelimiter) -> DelimiterKind {
    match delimiter {
        PmDelimiter::Parenthesis => DelimiterKind::Parenthesis,
        PmDelimiter::Brace => DelimiterKind::Brace,
        PmDelimiter::Bracket => DelimiterKind::Bracket,
        PmDelimiter::None => DelimiterKind::Invisible,
    }
}

// ════════════════════════════════════════════════════════════
// ra_ap_tt -> proc_macro2
// ════════════════════════════════════════════════════════════

/// Convert a `ra_ap_tt` subtree back into a `proc_macro2` token stream.
///
/// `on_ident` is called for every identifier leaf with its raw text and its
/// [`Origin`], and returns the text to emit plus whether it is a raw
/// identifier — which is how [`crate::hygiene`] marks definition-origin
/// identifiers without a side table that would have to be kept in step with a
/// `syn` traversal order it cannot predict.
pub(crate) fn from_subtree(
    subtree: &TopSubtree,
    on_ident: &mut dyn FnMut(&str, bool, Origin) -> (String, bool),
) -> Result<TokenStream, MacroError> {
    let mut iter = subtree.iter();
    collect(&mut iter, on_ident)
}

fn collect(
    iter: &mut ra_ap_tt::iter::TtIter<'_>,
    on_ident: &mut dyn FnMut(&str, bool, Origin) -> (String, bool),
) -> Result<TokenStream, MacroError> {
    let mut out = TokenStream::new();
    for element in iter.by_ref() {
        match element {
            TtElement::Leaf(leaf) => out.extend(std::iter::once(leaf_to_token(&leaf, on_ident)?)),
            TtElement::Subtree(subtree, mut inner) => {
                let stream = collect(&mut inner, on_ident)?;
                let delimiter = match subtree.delimiter.kind {
                    DelimiterKind::Parenthesis => PmDelimiter::Parenthesis,
                    DelimiterKind::Brace => PmDelimiter::Brace,
                    DelimiterKind::Bracket => PmDelimiter::Bracket,
                    DelimiterKind::Invisible => PmDelimiter::None,
                };
                out.extend(std::iter::once(PmTokenTree::Group(Group::new(
                    delimiter, stream,
                ))));
            }
        }
    }
    Ok(out)
}

fn leaf_to_token(
    leaf: &Leaf,
    on_ident: &mut dyn FnMut(&str, bool, Origin) -> (String, bool),
) -> Result<PmTokenTree, MacroError> {
    Ok(match leaf {
        Leaf::Ident(ident) => {
            let raw_in = matches!(ident.is_raw, IdentIsRaw::Yes);
            let (text, raw_out) = on_ident(ident.sym.as_str(), raw_in, origin_of(ident.span));
            PmTokenTree::Ident(if raw_out {
                PmIdent::new_raw(&text, proc_macro2::Span::call_site())
            } else {
                PmIdent::new(&text, proc_macro2::Span::call_site())
            })
        }
        Leaf::Punct(punct) => PmTokenTree::Punct(PmPunct::new(
            punct.char,
            match punct.spacing {
                Spacing::Alone => PmSpacing::Alone,
                // `proc_macro2` has no "joint, but there was no source text
                // between the two tokens" distinction — both are Joint.
                Spacing::Joint | Spacing::JointHidden => PmSpacing::Joint,
            },
        )),
        Leaf::Literal(literal) => PmTokenTree::Literal(rebuild_literal(literal)?),
    })
}

/// Rebuild a `proc_macro2::Literal` from a `ra_ap_tt::Literal`.
///
/// See this module's doc comment: `Literal::text()` is the token text *minus*
/// its quotes and *with* its escapes intact, so the quoted kinds have to be
/// re-quoted and re-parsed rather than re-escaped by
/// `Literal::string`/`byte_string`/`character`.
fn rebuild_literal(literal: &ra_ap_tt::Literal) -> Result<PmLiteral, MacroError> {
    let (text, suffix) = literal.text_and_suffix();
    let spelled = match literal.kind {
        LitKind::Str => format!("\"{text}\"{suffix}"),
        LitKind::ByteStr => format!("b\"{text}\"{suffix}"),
        LitKind::CStr => format!("c\"{text}\"{suffix}"),
        LitKind::Char => format!("'{text}'{suffix}"),
        LitKind::Byte => format!("b'{text}'{suffix}"),
        LitKind::StrRaw(hashes) => {
            let h = "#".repeat(hashes as usize);
            format!("r{h}\"{text}\"{h}{suffix}")
        }
        LitKind::ByteStrRaw(hashes) => {
            let h = "#".repeat(hashes as usize);
            format!("br{h}\"{text}\"{h}{suffix}")
        }
        LitKind::CStrRaw(hashes) => {
            let h = "#".repeat(hashes as usize);
            format!("cr{h}\"{text}\"{h}{suffix}")
        }
        LitKind::Integer | LitKind::Float | LitKind::Err(_) => format!("{text}{suffix}"),
    };
    spelled
        .parse::<PmLiteral>()
        .map_err(|_| MacroError::LiteralNotRebuildable {
            spelled: spelled.clone(),
        })
}
