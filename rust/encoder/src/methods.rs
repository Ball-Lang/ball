//! Method-call and macro dispatch (issue #42): Rust iterator-chain sugar
//! (`.iter().map(f).filter(g).collect()`) desugars into nested
//! `std_collections` calls; string methods (`.trim()`, `.contains()`, ...)
//! desugar into universal `std` string-manipulation calls; `.unwrap()`/
//! `.unwrap_or()` desugar against the unified Option/Result "outcome" shape
//! (see `lib.rs::option_result_message`); `println!`/`format!`/`vec!`/
//! `panic!`/`unreachable!` desugar into `std.print`/string-concatenation/
//! list-literal/`std.throw` trees.
//!
//! ## The compiler↔encoder round trip (issue #632)
//!
//! `panic!` and `unreachable!` are here because **this crate must be able to
//! read back everything `ball-lang-compiler` emits**. The compiler's own method
//! dispatchers (`type_emit.rs::compile_method_dispatchers`) end in a `panic!`
//! fallback arm, so without that arm every library whose compiled output
//! carries a dispatcher — i.e. every library with a struct and a method —
//! failed Tier A's stage 3 (re-encode) with
//! ``unsupported macro invocation `panic!` ``.
//!
//! **Enumerate the emitted set, do not assume it is one.** The same sweep over
//! what the compiler emits found `unreachable!`
//! (`base_call.rs::flow_propagation`, a `break`/`continue` inside a `try` with
//! no enclosing loop) and, in `base_call.rs::compile_list_literal`'s imperative
//! lowering, both `Vec::new()` and `matches!(__sp, BallValue::Null)`.
//!
//! `unreachable!` is mapped below — it is `panic!` with a fixed prefix, so it
//! has a faithful shape. The list-literal pair is NOT, and must not be widened
//! into: `matches!` is a pattern match over a runtime-crate enum variant and
//! `Vec::new()` an associated function on a foreign type, so an arm for either
//! would encode a compiler-internal spelling while still refusing every
//! real-world occurrence — which is what Tier A actually measures. That pair is
//! pinned fail-loud as
//! `documented_gaps.rs::compiled_spliced_list_literal_is_a_documented_gap` (plus
//! `the_matches_macro_is_a_documented_gap` for the second refusal, which one
//! `#[should_panic]` cannot reach) and filed as issue #712, whose fix is
//! compiler-side: emit plain helper calls, the vocabulary the neighbouring
//! `ball_truthy`/`ball_iterate`/`ball_spread_iter` already use.
//!
//! The gate that keeps the two halves in agreement is
//! `rust/encoder/tests/compile_reencode_roundtrip.rs`: it runs Tier A's three
//! library-mode stages, and proves the thrown MESSAGE behaviourally by
//! compiling and RUNNING the construct with a hand-written driver.
//!
//! **No `rust_std` module**: every arm below routes through `std`/
//! `std_collections` base-function calls — there is no Rust-specific
//! runtime hook anywhere in this file.
//!
//! ## Permanent carve-outs (issue #491, slice 6)
//!
//! The catch-all panic at the bottom of [`Encoder::encode_method_call`] is a
//! deliberate boundary, not an unbounded TODO bucket. These methods are named
//! here as **permanent** carve-outs — a syntactic (no semantic-model) encoder
//! cannot encode them correctly, so nothing should "just add one more arm":
//!
//! - `.next()` — needs stateful-iterator semantics (a cursor that advances,
//!   and an `Option` distinguishing exhaustion from a real `None` element).
//!   Ball's collections are values, not stateful iterators.
//! - `.unwrap_or_default()` — needs the receiver's `Default` impl, which is a
//!   type-specific value no syntax tree carries (`0`? `""`? `vec![]`? a
//!   user struct's own `Default`?).
//! - `.spilled()` (`SmallVec`), `.iter_names()` (`bitflags`) — type-specific
//!   behaviour of a foreign type, with no universal `std` equivalent at all.
//! - `.serialize_seq()`, `.is_human_readable()` (serde) — trait-object
//!   dispatch against a caller-supplied `Serializer`; there is no receiver
//!   value to encode against.
//! - `.ok_or()` — maps `Option` → `Result` with a caller-supplied error, and
//!   Ball's unified outcome shape (`lib.rs::option_result_message`) has no
//!   distinct error channel to map onto.
//! - `.value()`, `.multiunzip()` — resolvable only once the receiver's
//!   concrete type is known (which `.value()` it is depends entirely on the
//!   trait in scope).
//!
//! `.fuse()` and `.is_empty()` used to sit in that same bucket and were
//! closed by slice 6 precisely because neither needs type information: see
//! their arms below and `rust/encoder/tests/method_sugar.rs`.
//!
//! ## Shadowing: a same-file user method wins over the two new arms
//!
//! Every built-in arm above is matched on the method's NAME alone, so a
//! user-declared `fn len(&self)` is encoded as `std.length` rather than as its
//! own method — an inherent, pre-existing bias of a syntactic encoder with no
//! type information, mirroring the `_looksLikeTypeName` caveat documented in
//! `.claude/rules/dart.md`.
//!
//! Slice 6 deliberately does **not** widen that bias: `.fuse()` and
//! `.is_empty()` each carry a `!self.method_params.contains_key(..)` guard, so
//! an `impl` block in this very file declaring `fn is_empty(&self)` still
//! dispatches to the user's method. A `Vec`-backed struct's own `is_empty`
//! lowered to `std.length(struct) == 0` would be silently wrong output — the
//! one failure mode this crate's fail-loud posture exists to prevent — and
//! adding a new instance of a known hazard is not justified by consistency
//! with the older arms. Pinned by
//! `method_sugar.rs::user_declared_is_empty_wins_over_the_builtin_arm`.
use ball_lang_shared::proto::ball::v1::expression::Expr;
use ball_lang_shared::proto::ball::v1::{Expression, FunctionCall};

use crate::{
    Encoder, args_message, collections_call, field_access, if_call, int_literal, let_stmt,
    list_literal, named_message, reference, std_call, string_literal,
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

            // `.fuse()` is the same identity passthrough (issue #491, slice 6):
            // a Ball `List` has no "already exhausted" state for a fused
            // iterator to preserve. Unlike the arm above, it DEFERS to a
            // same-file user method of that name — see this file's module doc
            // comment, "Shadowing".
            "fuse" if e.args.is_empty() && !self.method_params.contains_key("fuse") => {
                self.encode_expr(&e.receiver)
            }

            // ── String / universal conversions ──
            "to_string" if e.args.is_empty() => self.un_std("to_string", &e.receiver),
            "len" if e.args.is_empty() => self.un_std("length", &e.receiver),
            // `.is_empty()` reuses the very same universal `std.length`
            // dispatch `.len()` routes through, so it stays correct whether
            // the receiver turns out to be a `String` or a `List` at runtime
            // — no new base function, no type inference (issue #491, slice 6).
            // DEFERS to a same-file user method of that name — see this file's
            // module doc comment, "Shadowing".
            "is_empty" if e.args.is_empty() && !self.method_params.contains_key("is_empty") => {
                let length = self.un_std("length", &e.receiver);
                std_call(
                    "equals",
                    Some(args_message(vec![
                        ("left", length),
                        ("right", int_literal(0)),
                    ])),
                )
            }
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

            // A user-defined instance method (issue #43 — see `types.rs`'s
            // module doc comment): `receiver.method(args)` packs the
            // receiver as a `"self"` field alongside `args` (keyed by the
            // method's *real* declared parameter names, from the
            // `collect_impl_method_params` pre-pass — falling back to
            // positional `arg0`/`arg1` the same way a same-file free-function
            // call already does when its signature isn't known) — the exact
            // shape `ball-lang-compiler`'s `compile_method_dispatchers` /
            // `method_prologue` expect (`rust/compiler/src/type_emit.rs`).
            // Only recognized when `method` was actually seen as an `impl`
            // block's own method name in the pre-pass; anything else still
            // falls through to the loud panic below (a syntactic encoder has
            // no static type info to otherwise disambiguate a genuine typo
            // from an unsupported built-in — mirrors the `_looksLikeTypeName`
            // caveat documented in `.claude/rules/dart.md`).
            other if self.method_params.contains_key(other) => {
                self.encode_user_method_call(other, &e.receiver, &e.args)
            }

            other => panic!(
                "ball-lang-encoder: unsupported method call `.{other}()` (see the module doc \
                 comment — a user-defined instance method must be declared in an `impl` block \
                 this file also encodes, or, under `encode_crate`, anywhere in the same crate)"
            ),
        }
    }

    /// Packs `receiver` under a `"self"` field, then `args` under the
    /// callee's own real parameter names (or a positional `argN` fallback
    /// when the count doesn't match what the pre-pass recorded — the exact
    /// same fallback [`Encoder::encode_user_call`] uses for a free-function
    /// call whose signature isn't known).
    fn encode_user_method_call(
        &mut self,
        method: &str,
        receiver: &syn::Expr,
        args: &syn::punctuated::Punctuated<syn::Expr, syn::Token![,]>,
    ) -> Expression {
        // Crate mode (issue #491): when the method is declared in ANOTHER
        // file of this crate, the call names that module, so the compiler
        // emits `<mod>::<method>(…)` — reaching the polymorphic dispatcher
        // `compile_method_dispatchers` emits inside that module. Empty
        // (unqualified, exactly as before) for a same-module method and for
        // every single-file encode.
        let module = self.resolve_crate_method(method).unwrap_or_default();
        let self_value = self.encode_expr(receiver);
        let mut fields: Vec<(String, Expression)> = vec![("self".to_string(), self_value)];
        let param_names: Vec<String> = self
            .method_params
            .get(method)
            .filter(|params| params.len() == args.len())
            .cloned()
            .unwrap_or_else(|| (0..args.len()).map(|i| format!("arg{i}")).collect());
        for (name, arg) in param_names.into_iter().zip(args.iter()) {
            fields.push((name, self.encode_expr(arg)));
        }
        let field_pairs: Vec<(&str, Expression)> = fields
            .iter()
            .map(|(n, v)| (n.as_str(), v.clone()))
            .collect();
        Expression {
            expr: Some(Expr::Call(Box::new(FunctionCall {
                module,
                function: method.to_string(),
                input: Some(Box::new(args_message(field_pairs))),
                type_args: vec![],
            }))),
        }
    }

    fn collections_callback(
        &mut self,
        function: &str,
        list: &syn::Expr,
        callback: &syn::Expr,
    ) -> Expression {
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
            // `panic!` is Rust's spelling of Ball's `std.throw`, and the two are
            // the SAME mechanism on this target: `runtime.rs::ball_throw` is
            // literally `std::panic::panic_any`, and `ball_catch_payload` — the
            // helper every compiled `try` runs on the unwound payload — already
            // re-wraps a non-Ball panic payload (a `&str`/`String`, i.e. exactly
            // what `panic!` carries) as `BallValue::String(message)`. So a Ball
            // `catch` around a `panic!` and around a `throw '<that message>'`
            // bind the identical value; encoding one as the other preserves the
            // observable the #616/#641 error-rendering contract governs, rather
            // than approximating it.
            //
            // The Ball shape is the reference encoder's: `dart/encoder`'s
            // `ThrowExpression` arm emits `std.throw` with a single `value`
            // field, which is also what this crate's own `encode_unwrap`
            // already emits for a failed `.unwrap()`.
            //
            // The message travels through `build_format_expr`, the same
            // `std.concat`/`std.to_string` chain `format!` encodes to, so
            // `panic!("no method '{}' for {}", a, b)` keeps its interpolation.
            // A bare `panic!()` carries the message Rust itself prints for it —
            // `core`'s `panic!()` expands to `panic("explicit panic")` (see
            // `core::panicking::panic`'s callers in the standard library) — never
            // an empty string, which would silently lose the failure's identity.
            "panic" => {
                let message = if mac.tokens.is_empty() {
                    string_literal("explicit panic")
                } else {
                    self.build_format_expr(mac)
                };
                std_call("throw", Some(args_message(vec![("value", message)])))
            }
            // `unreachable!` is the SECOND macro the compiler emits into user
            // programs, so the same round-trip invariant covers it:
            // `base_call.rs::flow_propagation` ends a `try` that carries a
            // `break`/`continue` with no enclosing loop in
            // `unreachable!("break escaped a try with no enclosing loop")`.
            // Leaving it unmapped would have kept stage 3 failing for exactly
            // that shape, one `unsupported macro invocation` later.
            //
            // It is `panic!` with a fixed prefix — `core`'s edition-2021 form
            // expands to `panic!("internal error: entered unreachable code: {}",
            // format_args!(...))`, and the argument-less form to a plain
            // `panic("internal error: entered unreachable code")` (rust-lang/rust
            // `library/core/src/panic.rs`, `unreachable_2021`/`unreachable_2015`).
            // So it encodes as the same `std.throw`, carrying the message Rust
            // itself would print — prefix included, because that prefix is part
            // of the string a Ball `catch` binds.
            "unreachable" => {
                let message = if mac.tokens.is_empty() {
                    string_literal(UNREACHABLE_MESSAGE)
                } else {
                    concat_expr(
                        string_literal(format!("{UNREACHABLE_MESSAGE}: ")),
                        self.build_format_expr(mac),
                    )
                };
                std_call("throw", Some(args_message(vec![("value", message)])))
            }
            other => panic!(
                "ball-lang-encoder: unsupported macro invocation `{other}!` (only `println!`/\
                 `format!`/`vec!`/`panic!`/`unreachable!` are supported — issue #42's scope)"
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
                    "ball-lang-encoder: failed to parse `vec!` arguments (the `vec![elem; n]` repeat \
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
                panic!("ball-lang-encoder: failed to parse format-macro arguments: {err}")
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
                "ball-lang-encoder: the first argument to a format macro must be a string literal \
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
            "ball-lang-encoder: format string {format_str:?} has {placeholder_count} `{{}}` \
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
            result = concat_expr(result, part);
        }
        result
    }
}

/// Rust's own fixed message for `unreachable!`, quoted from
/// `library/core/src/panic.rs` (`unreachable_2015`/`unreachable_2021`): the
/// argument-less form panics with exactly this, and the formatted form with
/// this plus `": "` and the formatted arguments.
const UNREACHABLE_MESSAGE: &str = "internal error: entered unreachable code";

/// `std.concat(left, right)` — the string-joining node `format!`'s
/// interpolation chain is built from, shared with `unreachable!`'s
/// prefix-plus-message shape so both spell the join the same way.
fn concat_expr(left: Expression, right: Expression) -> Expression {
    Expression {
        expr: Some(Expr::Call(Box::new(FunctionCall {
            module: "std".to_string(),
            function: "concat".to_string(),
            input: Some(Box::new(args_message(vec![
                ("left", left),
                ("right", right),
            ]))),
            type_args: vec![],
        }))),
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
                        None => {
                            panic!("ball-lang-encoder: unterminated `{{` in format string: {s:?}")
                        }
                    }
                }
                if !spec.is_empty() {
                    panic!(
                        "ball-lang-encoder: only the empty `{{}}` format placeholder is supported \
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
                panic!("ball-lang-encoder: unmatched `}}` in format string: {s:?}");
            }
            other => current.push(other),
        }
    }
    if !current.is_empty() {
        parts.push(FormatPart::Literal(current));
    }
    parts
}
