//! Method-call and macro dispatch (issue #42): Rust iterator-chain sugar
//! (`.iter().map(f).filter(g).collect()`) desugars into nested
//! `std_collections` calls; string methods (`.trim()`, `.contains()`, ...)
//! desugar into universal `std` string-manipulation calls; `.unwrap()`/
//! `.unwrap_or()` desugar against the unified Option/Result "outcome" shape
//! (see `lib.rs::option_result_message`); `println!`/`format!`/`vec!`
//! desugar into `std.print`/string-concatenation/list-literal trees.
//!
//! **No `rust_std` module**: every arm below routes through `std`/
//! `std_collections` base-function calls — there is no Rust-specific
//! runtime hook anywhere in this file.
use ball_shared::proto::ball::v1::expression::Expr;
use ball_shared::proto::ball::v1::{Expression, FunctionCall};

use crate::{
    Encoder, args_message, collections_call, field_access, if_call, let_stmt, list_literal,
    named_message, reference, std_call, string_literal,
};

impl Encoder {
    pub(crate) fn encode_method_call(&mut self, e: &syn::ExprMethodCall) -> Expression {
        let method = e.method.to_string();
        match method.as_str() {
            // ── Identity passthroughs (no Ball-level effect) ──
            "iter" | "into_iter" | "iter_mut" | "by_ref" | "as_ref" | "as_mut" | "as_str"
            | "as_slice" | "clone" | "to_owned" | "collect" | "as_bytes"
                if e.args.is_empty() =>
            {
                self.encode_expr(&e.receiver)
            }

            // ── String / universal conversions ──
            "to_string" if e.args.is_empty() => self.un_std("to_string", &e.receiver),
            "len" if e.args.is_empty() => self.un_std("length", &e.receiver),
            "trim" if e.args.is_empty() => self.un_std("string_trim", &e.receiver),
            "trim_start" if e.args.is_empty() => self.un_std("string_trim_start", &e.receiver),
            "trim_end" if e.args.is_empty() => self.un_std("string_trim_end", &e.receiver),
            "to_uppercase" | "to_ascii_uppercase" if e.args.is_empty() => {
                self.un_std("string_to_upper", &e.receiver)
            }
            "to_lowercase" | "to_ascii_lowercase" if e.args.is_empty() => {
                self.un_std("string_to_lower", &e.receiver)
            }
            "contains" if e.args.len() == 1 => {
                self.bin_std("string_contains", &e.receiver, &e.args[0])
            }
            "starts_with" if e.args.len() == 1 => {
                self.bin_std("string_starts_with", &e.receiver, &e.args[0])
            }
            "ends_with" if e.args.len() == 1 => {
                self.bin_std("string_ends_with", &e.receiver, &e.args[0])
            }
            "split" if e.args.len() == 1 => self.bin_std("string_split", &e.receiver, &e.args[0]),
            "replace" if e.args.len() == 2 => {
                // Rust's `str::replace` replaces *every* match — matches
                // `string_replace_all`, not the first-only `string_replace`.
                let value = self.encode_expr(&e.receiver);
                let from = self.encode_expr(&e.args[0]);
                let to = self.encode_expr(&e.args[1]);
                std_call(
                    "string_replace_all",
                    Some(args_message(vec![
                        ("value", value),
                        ("from", from),
                        ("to", to),
                    ])),
                )
            }
            "repeat" if e.args.len() == 1 => {
                let value = self.encode_expr(&e.receiver);
                let count = self.encode_expr(&e.args[0]);
                std_call(
                    "string_repeat",
                    Some(args_message(vec![("value", value), ("count", count)])),
                )
            }

            // ── Option/Result unwrapping (see `lib.rs::option_result_message`) ──
            "unwrap" if e.args.is_empty() => self.encode_unwrap(&e.receiver, None),
            "unwrap_or" if e.args.len() == 1 => self.encode_unwrap(&e.receiver, Some(&e.args[0])),

            // ── Iterator-chain sugar -> std_collections ──
            "map" if e.args.len() == 1 => {
                self.collections_callback("list_map", &e.receiver, &e.args[0])
            }
            "filter" if e.args.len() == 1 => {
                self.collections_callback("list_filter", &e.receiver, &e.args[0])
            }
            "find" if e.args.len() == 1 => {
                self.collections_callback("list_find", &e.receiver, &e.args[0])
            }
            "any" if e.args.len() == 1 => {
                self.collections_callback("list_any", &e.receiver, &e.args[0])
            }
            "all" if e.args.len() == 1 => {
                self.collections_callback("list_all", &e.receiver, &e.args[0])
            }
            "take" if e.args.len() == 1 => {
                self.collections_binary("list_take", "list", "value", &e.receiver, &e.args[0])
            }
            "skip" if e.args.len() == 1 => {
                self.collections_binary("list_drop", "list", "value", &e.receiver, &e.args[0])
            }
            "chain" if e.args.len() == 1 => {
                self.collections_binary("list_concat", "left", "right", &e.receiver, &e.args[0])
            }
            "push" if e.args.len() == 1 => {
                self.collections_binary("list_push", "list", "value", &e.receiver, &e.args[0])
            }

            other => panic!(
                "ball-encoder: unsupported method call `.{other}()` (issue #42's scope — see \
                 the module doc comment)"
            ),
        }
    }

    fn collections_callback(
        &mut self,
        function: &str,
        list: &syn::Expr,
        callback: &syn::Expr,
    ) -> Expression {
        self.uses_collections = true;
        let list_expr = self.encode_expr(list);
        let callback_expr = self.encode_expr(callback);
        collections_call(
            function,
            Some(args_message(vec![
                ("list", list_expr),
                ("callback", callback_expr),
            ])),
        )
    }

    fn collections_binary(
        &mut self,
        function: &str,
        left_field: &str,
        right_field: &str,
        left: &syn::Expr,
        right: &syn::Expr,
    ) -> Expression {
        self.uses_collections = true;
        let left_expr = self.encode_expr(left);
        let right_expr = self.encode_expr(right);
        collections_call(
            function,
            Some(args_message(vec![
                (left_field, left_expr),
                (right_field, right_expr),
            ])),
        )
    }

    /// `.unwrap()` / `.unwrap_or(default)` against the unified Option/Result
    /// outcome shape: unwraps `.value` on success, or throws (`.unwrap()`)
    /// / evaluates `default` (`.unwrap_or()`) on failure.
    fn encode_unwrap(
        &mut self,
        receiver: &syn::Expr,
        or_default: Option<&syn::Expr>,
    ) -> Expression {
        let target = self.encode_expr(receiver);
        let tmp = "__ball_unwrap";
        let is_err = field_access(reference(tmp), "is_err");
        let value = field_access(reference(tmp), "value");
        let failure_branch = match or_default {
            Some(default_expr) => self.encode_expr(default_expr),
            None => std_call(
                "throw",
                Some(args_message(vec![(
                    "value",
                    string_literal("called `.unwrap()` on a `None`/`Err` value"),
                )])),
            ),
        };
        crate::block_expr(
            vec![let_stmt(tmp, target)],
            if_call(is_err, failure_branch, value),
        )
    }

    // ════════════════════════════════════════════════════════════
    // Macros — println! / format! / vec!
    // ════════════════════════════════════════════════════════════

    pub(crate) fn encode_macro(&mut self, mac: &syn::Macro) -> Expression {
        let name = mac
            .path
            .get_ident()
            .map(std::string::ToString::to_string)
            .unwrap_or_default();
        match name.as_str() {
            "println" => {
                let message = self.build_format_expr(mac);
                std_call(
                    "print",
                    Some(named_message("PrintInput", vec![("message", message)])),
                )
            }
            "format" => self.build_format_expr(mac),
            "vec" => self.encode_vec_macro(mac),
            other => panic!(
                "ball-encoder: unsupported macro invocation `{other}!` (only `println!`/\
                 `format!`/`vec!` are supported — issue #42's scope)"
            ),
        }
    }

    fn encode_vec_macro(&mut self, mac: &syn::Macro) -> Expression {
        let exprs = mac
            .parse_body_with(
                syn::punctuated::Punctuated::<syn::Expr, syn::Token![,]>::parse_terminated,
            )
            .unwrap_or_else(|err| {
                panic!(
                    "ball-encoder: failed to parse `vec!` arguments (the `vec![elem; n]` repeat \
                     form is not supported — issue #42's scope): {err}"
                )
            });
        let elements = exprs.iter().map(|e| self.encode_expr(e)).collect();
        list_literal(elements)
    }

    /// Shared by `println!`/`format!`: parses the leading string-literal
    /// format string plus its interpolation arguments, and builds a
    /// `std.concat`/`std.to_string` chain equivalent to the formatted
    /// string. Only the empty `{}` placeholder is supported (no `{:?}`/
    /// `{name}`/positional `{0}` — issue #42's scope).
    fn build_format_expr(&mut self, mac: &syn::Macro) -> Expression {
        let exprs = mac
            .parse_body_with(
                syn::punctuated::Punctuated::<syn::Expr, syn::Token![,]>::parse_terminated,
            )
            .unwrap_or_else(|err| {
                panic!("ball-encoder: failed to parse format-macro arguments: {err}")
            });
        if exprs.is_empty() {
            return string_literal("");
        }
        let format_str = match &exprs[0] {
            syn::Expr::Lit(syn::ExprLit {
                lit: syn::Lit::Str(s),
                ..
            }) => s.value(),
            other => panic!(
                "ball-encoder: the first argument to a format macro must be a string literal \
                 (issue #42's scope — no format-string variables): {}",
                quote::quote!(#other)
            ),
        };
        let args: Vec<&syn::Expr> = exprs.iter().skip(1).collect();
        let segments = split_format_string(&format_str);
        let placeholder_count = segments
            .iter()
            .filter(|s| matches!(s, FormatPart::Placeholder))
            .count();
        assert_eq!(
            placeholder_count,
            args.len(),
            "ball-encoder: format string {format_str:?} has {placeholder_count} `{{}}` \
             placeholders but {} argument(s) were given",
            args.len()
        );

        let mut parts: Vec<Expression> = Vec::new();
        let mut arg_iter = args.into_iter();
        for segment in segments {
            match segment {
                FormatPart::Literal(text) => {
                    if !text.is_empty() {
                        parts.push(string_literal(text));
                    }
                }
                FormatPart::Placeholder => {
                    let arg = arg_iter.next().expect("count checked above");
                    let value = self.encode_expr(arg);
                    parts.push(std_call(
                        "to_string",
                        Some(args_message(vec![("value", value)])),
                    ));
                }
            }
        }
        if parts.is_empty() {
            return string_literal("");
        }
        let mut result = parts.remove(0);
        for part in parts {
            result = Expression {
                expr: Some(Expr::Call(Box::new(FunctionCall {
                    module: "std".to_string(),
                    function: "concat".to_string(),
                    input: Some(Box::new(args_message(vec![
                        ("left", result),
                        ("right", part),
                    ]))),
                    type_args: vec![],
                }))),
            };
        }
        result
    }
}

enum FormatPart {
    Literal(String),
    Placeholder,
}

/// Split a Rust format string into literal text segments and `{}`
/// placeholders. `{{`/`}}` are unescaped to literal `{`/`}` (Rust's own
/// format-string escaping rule). Any placeholder with a non-empty spec
/// (`{:?}`, `{0}`, `{name}`, ...) fails loud — only the plain `{}` form is
/// supported (issue #42's scope).
fn split_format_string(s: &str) -> Vec<FormatPart> {
    let mut parts = Vec::new();
    let mut current = String::new();
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '{' => {
                if chars.peek() == Some(&'{') {
                    chars.next();
                    current.push('{');
                    continue;
                }
                let mut spec = String::new();
                loop {
                    match chars.next() {
                        Some('}') => break,
                        Some(other) => spec.push(other),
                        None => panic!("ball-encoder: unterminated `{{` in format string: {s:?}"),
                    }
                }
                if !spec.is_empty() {
                    panic!(
                        "ball-encoder: only the empty `{{}}` format placeholder is supported \
                         (got `{{{spec}}}` in {s:?}) — issue #42's scope"
                    );
                }
                if !current.is_empty() {
                    parts.push(FormatPart::Literal(std::mem::take(&mut current)));
                }
                parts.push(FormatPart::Placeholder);
            }
            '}' => {
                if chars.peek() == Some(&'}') {
                    chars.next();
                    current.push('}');
                    continue;
                }
                panic!("ball-encoder: unmatched `}}` in format string: {s:?}");
            }
            other => current.push(other),
        }
    }
    if !current.is_empty() {
        parts.push(FormatPart::Literal(current));
    }
    parts
}
