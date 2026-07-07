//! `ball-encoder` — encodes Rust source into a Ball [`Program`] protobuf.
//!
//! Phase 3a (issue #42) parses Rust source with **`syn` 2.x** (`features =
//! ["full"]`) and walks the AST (items -> fns -> statements -> expressions),
//! mapping every construct to the universal `std`/`std_collections` base
//! modules — mirroring `dart/encoder/lib/encoder.dart` (the reference
//! implementation for the AST-to-Ball mapping discipline named in the
//! issue) and the TS encoder (`ts/encoder/src/encoder.ts`).
//!
//! **Core invariant (never violate): there is no `rust_std` base module.**
//! Every Rust construct — operators, control flow, iterator-chain sugar,
//! `?`, `if let` — expands into a tree of calls against the universal `std`
//! (and, for list operations, `std_collections`) base functions, exactly as
//! the Dart encoder expands cascade/null-aware-access/spread. A conformant
//! Ball engine that has never heard of Rust can still run the result.
//!
//! ## Scope (Phase 3a — see issue #43 for what's deliberately deferred)
//!
//! This crate covers **expressions, operators, and control flow** only:
//! - Top-level `fn` items only (no `struct`/`enum`/`impl`/`trait` — those
//!   need `TypeDefinition` emission, #43's job). Encountering one of these
//!   top-level items is a loud panic, not a silent skip (`use`/`mod` items
//!   ARE silently skipped — they carry no runtime semantics of their own).
//! - No metadata/round-trip fidelity beyond the one exception every
//!   reference encoder already relies on for correctness: a function/
//!   closure with **exactly one** parameter gets `metadata.params =
//!   [{name}]` (see [`single_param_metadata`]), which is what makes
//!   `ball-compiler`'s existing `param_alias_prologue` emit `let <name> =
//!   input.clone();` — without it, a body that references its own
//!   parameter by name wouldn't compile. This is a narrow, load-bearing
//!   exception, not general metadata/round-trip work.
//!
//! ## The "one input" convention, precisely
//!
//! Every Ball function/closure has exactly one input (invariant #1). This
//! crate handles Rust's N-parameter functions/closures as follows (see
//! [`Encoder::push_fn_scope`]):
//! - **Zero parameters** — no input at all.
//! - **Exactly one parameter** — the parameter keeps its own Rust name as a
//!   plain `reference(name)` throughout the body, driven by
//!   `metadata.params` (mirrors Dart's encoder exactly; the compiler's
//!   `param_alias_prologue` turns this into a real local binding).
//! - **Two or more parameters** — packed into one anonymous
//!   `MessageCreation` (fields keyed by each parameter's real name); each
//!   reference to a parameter compiles to `field_access(reference("input"),
//!   name)`, which needs **no** compiler-side alias support at all (unlike
//!   the single-parameter path) and therefore compiles correctly *today*,
//!   with zero risk of a nested closure's own (shadowing) "input"
//!   parameter silently reading the wrong value — see
//!   [`Encoder::is_current_multi_param`]'s doc comment for why this must
//!   only ever consult the **innermost** function/closure scope.
//!
//! Call sites mirror this: a single-argument call passes its one argument
//! directly as `FunctionCall.input` (no wrapping); a call to a
//! **known** (same-file) function with 2+ arguments packs them into a
//! `MessageCreation` keyed by that function's *real* declared parameter
//! names (see [`Encoder::fn_params`]) — not the positional `arg0`/`arg1`
//! convention Dart falls back to for calls whose target signature isn't
//! known — because a same-file callee's signature always *is* known here
//! (this crate encodes one whole file in a single pass).
mod block;
mod control_flow;
mod methods;

use std::collections::{HashMap, HashSet};

use ball_shared::proto::ball::v1::expression::Expr;
use ball_shared::proto::ball::v1::literal::Value as LiteralValue;
use ball_shared::proto::ball::v1::statement::Stmt as BallStmt;
use ball_shared::proto::ball::v1::{
    Block, Expression, FieldAccess, FieldValuePair, FunctionCall, FunctionDefinition, LetBinding,
    ListLiteral, Literal, MessageCreation, Module, ModuleImport, Program, Reference, Statement,
};
use ball_shared::proto::google::protobuf::value::Kind;
use ball_shared::proto::google::protobuf::{ListValue, Struct, Value};

/// Encode a Rust source file into a Ball [`Program`]. Requires a `fn
/// main()` (the entry point every Ball `Program` needs) — fails loud
/// (panics) if one isn't present, or if the source contains a construct
/// outside this crate's documented Phase 3a scope, rather than silently
/// dropping semantic content (see the module doc comment).
pub fn encode(source: &str) -> Program {
    let (main_module, has_main, uses_collections) = encode_main_module(source);
    assert!(
        has_main,
        "ball-encoder: a Ball Program requires a `fn main()` entry point"
    );

    let mut modules = vec![ball_shared::build_std_module()];
    if uses_collections {
        modules.push(ball_shared::build_std_collections_module());
    }
    modules.push(main_module);

    Program {
        name: "encoded_rust_program".to_string(),
        version: "1.0.0".to_string(),
        modules,
        entry_module: "main".to_string(),
        entry_function: "main".to_string(),
        metadata: None,
    }
}

/// Encode a Rust source file's functions into a bare [`Module`] named
/// `"main"` — **without** requiring (or checking for) a `fn main()`, and
/// without wrapping the result in a full [`Program`] or including the
/// `std`/`std_collections` base modules. Exists for tests/tools that want
/// to inspect the encoded `FunctionDefinition`/`Expression` tree structure
/// directly (e.g. asserting a specific function's body shape) without
/// needing a complete, runnable program. [`encode`] is the entry point for
/// producing an actually-runnable [`Program`].
pub fn encode_module_only(source: &str) -> Module {
    encode_main_module(source).0
}

/// Shared implementation behind [`encode`] and [`encode_module_only`].
/// Returns `(module, has_main, uses_collections)`.
fn encode_main_module(source: &str) -> (Module, bool, bool) {
    let file: syn::File = syn::parse_file(source)
        .unwrap_or_else(|err| panic!("ball-encoder: failed to parse Rust source: {err}"));

    let mut encoder = Encoder::new();

    // Pass 1: collect every top-level fn's (name, parameter-name list) up
    // front so call sites (which may textually precede their callee) can
    // pack a 2+-argument call using the callee's *real* parameter names.
    for item in &file.items {
        if let syn::Item::Fn(item_fn) = item {
            let params = param_names_and_types(&item_fn.sig);
            encoder.fn_params.insert(
                item_fn.sig.ident.to_string(),
                params.iter().map(|(name, _)| name.clone()).collect(),
            );
        }
    }

    // Pass 2: encode every top-level fn's body.
    let mut functions = Vec::new();
    let mut has_main = false;
    for item in &file.items {
        match item {
            syn::Item::Fn(item_fn) => {
                if item_fn.sig.ident == "main" {
                    has_main = true;
                }
                functions.push(encoder.encode_item_fn(item_fn));
            }
            // Imports and (sub)modules carry no runtime semantics of their
            // own to encode — silently skipped, not a scope violation.
            syn::Item::Use(_) | syn::Item::Mod(_) => {}
            other => panic!(
                "ball-encoder: unsupported top-level item `{}` — types/impls/traits/consts \
                 need TypeDefinition emission, which is issue #43's scope (Phase 3a covers \
                 expressions/operators/control flow only)",
                item_kind_name(other)
            ),
        }
    }

    let mut module_imports = vec![ModuleImport {
        name: "std".to_string(),
        ..Default::default()
    }];
    if encoder.uses_collections {
        module_imports.push(ModuleImport {
            name: "std_collections".to_string(),
            ..Default::default()
        });
    }
    let module = Module {
        name: "main".to_string(),
        functions,
        module_imports,
        ..Default::default()
    };
    (module, has_main, encoder.uses_collections)
}

fn item_kind_name(item: &syn::Item) -> &'static str {
    match item {
        syn::Item::Struct(_) => "struct",
        syn::Item::Enum(_) => "enum",
        syn::Item::Impl(_) => "impl",
        syn::Item::Trait(_) => "trait",
        syn::Item::Const(_) => "const",
        syn::Item::Static(_) => "static",
        syn::Item::Type(_) => "type alias",
        syn::Item::Macro(_) => "macro invocation",
        _ => "item",
    }
}

/// The encoder's mutable state while walking one Rust source file.
pub(crate) struct Encoder {
    /// Every top-level fn's real parameter names, keyed by fn name —
    /// populated in a pre-pass (see [`encode`]) so a 2+-argument call site
    /// can pack its `MessageCreation` fields with the callee's *actual*
    /// parameter names, not a positional `arg0`/`arg1` guess.
    pub(crate) fn_params: HashMap<String, Vec<String>>,
    /// One frame per fn/closure currently being encoded, holding that
    /// fn/closure's own parameter names **only when it has 2+ parameters**
    /// (see [`Self::push_fn_scope`]). Consulted by
    /// [`Self::is_current_multi_param`] — which, critically, only ever
    /// looks at the *innermost* (last) frame; see that method's doc
    /// comment for why consulting outer frames would silently miscompile.
    scopes: Vec<HashSet<String>>,
    /// Did this file's encoding reach any `std_collections` construct
    /// (iterator-chain sugar, `Vec::push`, ...)? Drives conditional module
    /// inclusion (Phase 3.5's "std module accumulation") — `std` itself is
    /// always included (virtually every program uses it).
    pub(crate) uses_collections: bool,
}

impl Encoder {
    fn new() -> Self {
        Encoder {
            fn_params: HashMap::new(),
            scopes: Vec::new(),
            uses_collections: false,
        }
    }

    // ════════════════════════════════════════════════════════════
    // Function / closure parameter scoping
    // ════════════════════════════════════════════════════════════

    /// Push a fresh scope frame for a fn/closure body about to be encoded,
    /// and return the `FunctionDefinition.metadata` it should carry (see
    /// the module doc comment's "one input" section). Must be paired with
    /// [`Self::pop_fn_scope`] once the body has been encoded.
    fn push_fn_scope(&mut self, params: &[(String, String)]) -> Option<Struct> {
        if params.len() >= 2 {
            self.scopes
                .push(params.iter().map(|(name, _)| name.clone()).collect());
        } else {
            self.scopes.push(HashSet::new());
        }
        if params.len() == 1 {
            Some(single_param_metadata(&params[0].0))
        } else {
            None
        }
    }

    fn pop_fn_scope(&mut self) {
        self.scopes.pop();
    }

    /// Is `name` one of the **currently-being-encoded** fn/closure's own
    /// 2+ parameters?
    ///
    /// Deliberately consults **only** [`Self::scopes`]'s last (innermost)
    /// frame, never outer ones: a multi-parameter fn/closure's parameters
    /// are read via `field_access(reference("input"), name)`, and
    /// `"input"` is *shadowed* by any nested closure's own `input`
    /// parameter (`ball-compiler`'s `compile_lambda` emits `move |input:
    /// BallValue| ...`) — so a `field_access` on `"input"` written from
    /// inside a nested closure would silently read the closure's *own*
    /// input, not the enclosing fn's, if this walked outer frames too. A
    /// single-named parameter doesn't have this problem (it aliases to a
    /// genuinely distinctly-named local via `metadata.params`, unaffected
    /// by any inner `"input"` shadow), which is exactly why only the
    /// multi-parameter path needs this scoping restriction. Capturing one
    /// *individual* field of an enclosing multi-parameter fn/closure from a
    /// nested closure is consequently unsupported (falls through to a bare
    /// `reference(name)`, which fails loud at Rust compile time — an
    /// undefined identifier — rather than silently reading the wrong
    /// value); narrow enough that it isn't exercised by this issue's
    /// fixtures.
    fn is_current_multi_param(&self, name: &str) -> bool {
        self.scopes.last().is_some_and(|frame| frame.contains(name))
    }

    // ════════════════════════════════════════════════════════════
    // Top-level fn encoding
    // ════════════════════════════════════════════════════════════

    fn encode_item_fn(&mut self, item_fn: &syn::ItemFn) -> FunctionDefinition {
        let name = item_fn.sig.ident.to_string();
        let params = param_names_and_types(&item_fn.sig);
        let metadata = self.push_fn_scope(&params);
        let body = self.encode_block(&item_fn.block);
        self.pop_fn_scope();

        let input_type = if params.len() == 1 {
            params[0].1.clone()
        } else {
            String::new()
        };
        let output_type = match &item_fn.sig.output {
            syn::ReturnType::Default => String::new(),
            syn::ReturnType::Type(_, ty) => type_to_string(ty),
        };

        FunctionDefinition {
            name,
            input_type,
            output_type,
            body: Some(Box::new(body)),
            description: String::new(),
            is_base: false,
            metadata,
        }
    }

    // ════════════════════════════════════════════════════════════
    // Expression dispatch — the seven-node Ball Expression tree
    // ════════════════════════════════════════════════════════════

    pub(crate) fn encode_expr(&mut self, expr: &syn::Expr) -> Expression {
        match expr {
            syn::Expr::Lit(e) => self.encode_lit(&e.lit),
            syn::Expr::Path(e) => self.encode_path_expr(&e.path),
            syn::Expr::Paren(e) => self.encode_expr(&e.expr),
            syn::Expr::Group(e) => self.encode_expr(&e.expr),
            syn::Expr::Reference(e) => self.encode_expr(&e.expr),
            syn::Expr::Cast(e) => self.encode_expr(&e.expr),
            syn::Expr::Binary(e) => self.encode_binary(e),
            syn::Expr::Unary(e) => self.encode_unary(e),
            syn::Expr::Assign(e) => self.encode_assign(&e.left, &e.right, "="),
            syn::Expr::Field(e) => self.encode_field(e),
            syn::Expr::Index(e) => self.encode_index(e),
            syn::Expr::Array(e) => {
                let elements = e.elems.iter().map(|el| self.encode_expr(el)).collect();
                list_literal(elements)
            }
            syn::Expr::Call(e) => self.encode_call(e),
            syn::Expr::MethodCall(e) => self.encode_method_call(e),
            syn::Expr::If(e) => self.encode_if(e),
            syn::Expr::While(e) => self.encode_while(e),
            syn::Expr::ForLoop(e) => self.encode_for_loop(e),
            syn::Expr::Loop(e) => self.encode_loop(e),
            syn::Expr::Match(e) => self.encode_match(e),
            syn::Expr::Block(e) => self.encode_block(&e.block),
            syn::Expr::Return(e) => self.encode_return(e),
            syn::Expr::Break(e) => self.encode_break(e),
            syn::Expr::Continue(e) => self.encode_continue(e),
            syn::Expr::Try(e) => self.encode_try_operator(e),
            syn::Expr::Closure(e) => self.encode_closure(e),
            syn::Expr::Macro(e) => self.encode_macro(&e.mac),
            other => panic!(
                "ball-encoder: unsupported Rust expression kind `{}` (deferred — see the \
                 module doc comment for Phase 3a's scope)",
                expr_kind_name(other)
            ),
        }
    }

    // ── literals ─────────────────────────────────────────────

    fn encode_lit(&mut self, lit: &syn::Lit) -> Expression {
        match lit {
            syn::Lit::Int(i) => int_literal(
                i.base10_parse::<i64>()
                    .unwrap_or_else(|err| panic!("ball-encoder: invalid integer literal: {err}")),
            ),
            syn::Lit::Float(f) => double_literal(
                f.base10_parse::<f64>()
                    .unwrap_or_else(|err| panic!("ball-encoder: invalid float literal: {err}")),
            ),
            syn::Lit::Str(s) => string_literal(s.value()),
            syn::Lit::Bool(b) => bool_literal(b.value),
            syn::Lit::ByteStr(b) => bytes_literal(b.value()),
            other => panic!(
                "ball-encoder: unsupported literal kind (only int/float/string/bool/byte-string \
                 literals are supported): {other:?}"
            ),
        }
    }

    // ── path / reference ─────────────────────────────────────

    fn encode_path_expr(&mut self, path: &syn::Path) -> Expression {
        if let Some(ident) = path.get_ident() {
            let name = ident.to_string();
            if name == "None" {
                return option_result_message(true, null_literal());
            }
            if self.is_current_multi_param(&name) {
                return field_access(reference("input"), name);
            }
            return reference(name);
        }
        if let Some(last) = path.segments.last() {
            if last.ident == "None" {
                return option_result_message(true, null_literal());
            }
        }
        panic!(
            "ball-encoder: unsupported path expression `{}` — module/type/enum-variant paths \
             beyond `None` need TypeDefinition-aware resolution (issue #43's scope)",
            path_to_string(path)
        );
    }

    // ── binary / unary operators ─────────────────────────────

    fn encode_binary(&mut self, e: &syn::ExprBinary) -> Expression {
        use syn::BinOp::*;
        match &e.op {
            Add(_) => self.bin_std("add", &e.left, &e.right),
            Sub(_) => self.bin_std("subtract", &e.left, &e.right),
            Mul(_) => self.bin_std("multiply", &e.left, &e.right),
            Div(_) => {
                // No static type information is available (a syntactic
                // encoder, like the Dart/TS references — see dart.md's
                // "syntactic-encoder gotchas"), so this is a best-effort
                // heuristic: a literal float operand on either side selects
                // `divide_double` (always-double division); otherwise
                // `divide` (truncating), matching Rust's own native `/` for
                // the far more common integer case exactly (see
                // `ball_shared::runtime::ball_divide`'s doc comment).
                let op = if looks_like_float(&e.left) || looks_like_float(&e.right) {
                    "divide_double"
                } else {
                    "divide"
                };
                self.bin_std(op, &e.left, &e.right)
            }
            Rem(_) => self.bin_std("modulo", &e.left, &e.right),
            And(_) => self.bin_std("and", &e.left, &e.right),
            Or(_) => self.bin_std("or", &e.left, &e.right),
            BitXor(_) => self.bin_std("bitwise_xor", &e.left, &e.right),
            BitAnd(_) => self.bin_std("bitwise_and", &e.left, &e.right),
            BitOr(_) => self.bin_std("bitwise_or", &e.left, &e.right),
            Shl(_) => self.bin_std("left_shift", &e.left, &e.right),
            Shr(_) => self.bin_std("right_shift", &e.left, &e.right),
            Eq(_) => self.bin_std("equals", &e.left, &e.right),
            Ne(_) => self.bin_std("not_equals", &e.left, &e.right),
            Lt(_) => self.bin_std("less_than", &e.left, &e.right),
            Gt(_) => self.bin_std("greater_than", &e.left, &e.right),
            Le(_) => self.bin_std("lte", &e.left, &e.right),
            Ge(_) => self.bin_std("gte", &e.left, &e.right),
            AddAssign(_) => self.encode_assign(&e.left, &e.right, "+="),
            SubAssign(_) => self.encode_assign(&e.left, &e.right, "-="),
            MulAssign(_) => self.encode_assign(&e.left, &e.right, "*="),
            DivAssign(_) => self.encode_assign(&e.left, &e.right, "/="),
            RemAssign(_) => self.encode_assign(&e.left, &e.right, "%="),
            BitXorAssign(_) => self.encode_assign(&e.left, &e.right, "^="),
            BitAndAssign(_) => self.encode_assign(&e.left, &e.right, "&="),
            BitOrAssign(_) => self.encode_assign(&e.left, &e.right, "|="),
            ShlAssign(_) => self.encode_assign(&e.left, &e.right, "<<="),
            ShrAssign(_) => self.encode_assign(&e.left, &e.right, ">>="),
            other => panic!("ball-encoder: unsupported binary operator: {other:?}"),
        }
    }

    fn encode_unary(&mut self, e: &syn::ExprUnary) -> Expression {
        match e.op {
            syn::UnOp::Neg(_) => self.un_std("negate", &e.expr),
            syn::UnOp::Not(_) => self.un_std("not", &e.expr),
            // `*x` on a reference is transparent in Ball's pointer-free
            // value model for Phase 3a (mirrors the C++ encoder inlining
            // pointer dereference at encode time — see the module doc
            // comment's cross-reference to `cpp/encoder`).
            syn::UnOp::Deref(_) => self.encode_expr(&e.expr),
            other => panic!("ball-encoder: unsupported unary operator: {other:?}"),
        }
    }

    fn encode_assign(&mut self, target: &syn::Expr, value: &syn::Expr, op: &str) -> Expression {
        let target_expr = self.encode_expr(target);
        let value_expr = self.encode_expr(value);
        std_call(
            "assign",
            Some(args_message(vec![
                ("target", target_expr),
                ("value", value_expr),
                ("op", string_literal(op.to_string())),
            ])),
        )
    }

    pub(crate) fn bin_std(
        &mut self,
        function: &str,
        left: &syn::Expr,
        right: &syn::Expr,
    ) -> Expression {
        let left_expr = self.encode_expr(left);
        let right_expr = self.encode_expr(right);
        std_call(
            function,
            Some(args_message(vec![
                ("left", left_expr),
                ("right", right_expr),
            ])),
        )
    }

    pub(crate) fn un_std(&mut self, function: &str, value: &syn::Expr) -> Expression {
        let value_expr = self.encode_expr(value);
        std_call(function, Some(args_message(vec![("value", value_expr)])))
    }

    // ── field access / indexing ──────────────────────────────

    fn encode_field(&mut self, e: &syn::ExprField) -> Expression {
        let object = self.encode_expr(&e.base);
        let field = match &e.member {
            syn::Member::Named(ident) => ident.to_string(),
            syn::Member::Unnamed(index) => index.index.to_string(),
        };
        field_access(object, field)
    }

    fn encode_index(&mut self, e: &syn::ExprIndex) -> Expression {
        let target = self.encode_expr(&e.expr);
        let index = self.encode_expr(&e.index);
        std_call(
            "index",
            Some(args_message(vec![("target", target), ("index", index)])),
        )
    }

    // ── calls ─────────────────────────────────────────────────

    fn encode_call(&mut self, e: &syn::ExprCall) -> Expression {
        if let syn::Expr::Path(path_expr) = e.func.as_ref() {
            let path = &path_expr.path;
            if let Some(last) = path.segments.last() {
                let last_name = last.ident.to_string();
                // `String::from(x)` — identity passthrough (a Ball string
                // needs no separate "owned" representation).
                if path.segments.len() == 2 && last_name == "from" {
                    if let Some(first) = path.segments.first() {
                        if first.ident == "String" && e.args.len() == 1 {
                            return self.encode_expr(&e.args[0]);
                        }
                    }
                }
                // `Ok(x)` / `Err(x)` / `Some(x)` — the unified
                // Option/Result "outcome" representation (see the module
                // doc comment's cross-reference in `control_flow.rs`).
                if path.get_ident().is_some() && e.args.len() == 1 {
                    let is_err = match last_name.as_str() {
                        "Ok" | "Some" => Some(false),
                        "Err" => Some(true),
                        _ => None,
                    };
                    if let Some(is_err) = is_err {
                        let value = self.encode_expr(&e.args[0]);
                        return option_result_message(is_err, value);
                    }
                }
                // A same-file user function — pack args using its *real*
                // declared parameter names when it takes 2+ of them.
                if let Some(ident) = path.get_ident() {
                    let name = ident.to_string();
                    return self.encode_user_call(&name, &e.args);
                }
            }
        }
        panic!(
            "ball-encoder: unsupported call target `{}` — only same-file functions, \
             `Ok`/`Err`/`Some`, and `String::from` are supported (issue #42's scope)",
            quote::quote!(#e)
        );
    }

    /// Pack `args` as the input to a call targeting `name` — a bare Rust
    /// call syntax, resolved by `ball-compiler` through ordinary Rust name
    /// resolution (works identically whether `name` is a same-file
    /// top-level fn or a local closure-valued variable; see the module doc
    /// comment).
    fn encode_user_call(
        &mut self,
        name: &str,
        args: &syn::punctuated::Punctuated<syn::Expr, syn::Token![,]>,
    ) -> Expression {
        let encoded: Vec<Expression> = args.iter().map(|a| self.encode_expr(a)).collect();
        let input = match encoded.len() {
            0 => None,
            1 => Some(encoded.into_iter().next().expect("length checked above")),
            _ => {
                let field_names: Vec<String> = self
                    .fn_params
                    .get(name)
                    .filter(|params| params.len() == encoded.len())
                    .cloned()
                    .unwrap_or_else(|| (0..encoded.len()).map(|i| format!("arg{i}")).collect());
                let fields: Vec<(&str, Expression)> = field_names
                    .iter()
                    .map(String::as_str)
                    .zip(encoded)
                    .collect();
                Some(args_message(fields))
            }
        };
        Expression {
            expr: Some(Expr::Call(Box::new(FunctionCall {
                module: String::new(),
                function: name.to_string(),
                input: input.map(Box::new),
                type_args: vec![],
            }))),
        }
    }

    // ── closures ──────────────────────────────────────────────

    fn encode_closure(&mut self, e: &syn::ExprClosure) -> Expression {
        let params: Vec<(String, String)> = e
            .inputs
            .iter()
            .map(|pat| match pat {
                syn::Pat::Ident(syn::PatIdent {
                    ident,
                    subpat: None,
                    ..
                }) => (ident.to_string(), String::new()),
                syn::Pat::Type(pat_type) => match pat_type.pat.as_ref() {
                    syn::Pat::Ident(syn::PatIdent {
                        ident,
                        subpat: None,
                        ..
                    }) => (ident.to_string(), type_to_string(&pat_type.ty)),
                    _ => panic!(
                        "ball-encoder: only simple identifier closure parameters are supported"
                    ),
                },
                syn::Pat::Wild(_) => ("_".to_string(), String::new()),
                _ => {
                    panic!("ball-encoder: only simple identifier closure parameters are supported")
                }
            })
            .collect();

        let metadata = self.push_fn_scope(&params);
        let body = match e.body.as_ref() {
            // A closure whose body is already a block expression compiles
            // through the normal block path; anything else is a single
            // tail expression (Rust's `|x| expr` shorthand).
            syn::Expr::Block(block_expr) => self.encode_block(&block_expr.block),
            other => self.encode_expr(other),
        };
        self.pop_fn_scope();

        Expression {
            expr: Some(Expr::Lambda(Box::new(FunctionDefinition {
                name: String::new(),
                input_type: String::new(),
                output_type: String::new(),
                body: Some(Box::new(body)),
                description: String::new(),
                is_base: false,
                metadata,
            }))),
        }
    }
}

// ════════════════════════════════════════════════════════════
// Free helpers — Ball Expression/Literal builders
// ════════════════════════════════════════════════════════════

pub(crate) fn int_literal(value: i64) -> Expression {
    Expression {
        expr: Some(Expr::Literal(Literal {
            value: Some(LiteralValue::IntValue(value)),
        })),
    }
}

pub(crate) fn double_literal(value: f64) -> Expression {
    Expression {
        expr: Some(Expr::Literal(Literal {
            value: Some(LiteralValue::DoubleValue(value)),
        })),
    }
}

pub(crate) fn string_literal(value: impl Into<String>) -> Expression {
    Expression {
        expr: Some(Expr::Literal(Literal {
            value: Some(LiteralValue::StringValue(value.into())),
        })),
    }
}

pub(crate) fn bool_literal(value: bool) -> Expression {
    Expression {
        expr: Some(Expr::Literal(Literal {
            value: Some(LiteralValue::BoolValue(value)),
        })),
    }
}

pub(crate) fn bytes_literal(value: Vec<u8>) -> Expression {
    Expression {
        expr: Some(Expr::Literal(Literal {
            value: Some(LiteralValue::BytesValue(value)),
        })),
    }
}

pub(crate) fn null_literal() -> Expression {
    Expression {
        expr: Some(Expr::Literal(Literal { value: None })),
    }
}

pub(crate) fn list_literal(elements: Vec<Expression>) -> Expression {
    Expression {
        expr: Some(Expr::Literal(Literal {
            value: Some(LiteralValue::ListValue(ListLiteral { elements })),
        })),
    }
}

pub(crate) fn reference(name: impl Into<String>) -> Expression {
    Expression {
        expr: Some(Expr::Reference(Reference { name: name.into() })),
    }
}

pub(crate) fn field_access(object: Expression, field: impl Into<String>) -> Expression {
    Expression {
        expr: Some(Expr::FieldAccess(Box::new(FieldAccess {
            object: Some(Box::new(object)),
            field: field.into(),
        }))),
    }
}

/// An anonymous (`type_name` empty) `message_creation` — the "pack named
/// arguments for a base-function call" shape every base function's
/// `*Input` descriptor uses.
pub(crate) fn args_message(fields: Vec<(&str, Expression)>) -> Expression {
    Expression {
        expr: Some(Expr::MessageCreation(MessageCreation {
            type_name: String::new(),
            fields: fields
                .into_iter()
                .map(|(name, value)| FieldValuePair {
                    name: name.to_string(),
                    value: Some(value),
                })
                .collect(),
            metadata: None,
        })),
    }
}

/// A named (`type_name` non-empty) `message_creation` — a typed base-input
/// instance such as `SwitchCase`/`CatchClause`.
pub(crate) fn named_message(type_name: &str, fields: Vec<(&str, Expression)>) -> Expression {
    Expression {
        expr: Some(Expr::MessageCreation(MessageCreation {
            type_name: type_name.to_string(),
            fields: fields
                .into_iter()
                .map(|(name, value)| FieldValuePair {
                    name: name.to_string(),
                    value: Some(value),
                })
                .collect(),
            metadata: None,
        })),
    }
}

pub(crate) fn let_stmt(name: impl Into<String>, value: Expression) -> Statement {
    Statement {
        stmt: Some(BallStmt::Let(LetBinding {
            name: name.into(),
            value: Some(value),
            metadata: None,
        })),
    }
}

/// A Ball `block` [`Expression`] wrapping `statements` with a tail
/// `result` — used by `control_flow.rs` to introduce a temp `let` before a
/// desugared construct (`?`, `if let`, `match`) without recomputing its
/// subject expression more than once.
pub(crate) fn block_expr(statements: Vec<Statement>, result: Expression) -> Expression {
    Expression {
        expr: Some(Expr::Block(Box::new(Block {
            statements,
            result: Some(Box::new(result)),
        }))),
    }
}

/// A `for` loop's `init` clause shape `ball_compiler::Compiler::compile_for_init`
/// specifically recognizes (a `block` of fresh `let`-bindings with **no**
/// result — mirrors `rust/compiler/tests/end_to_end.rs`'s `for_init_lets`
/// helper) so each becomes a real `let mut <name> = <value>;` in the
/// compiled loop, not a nested throwaway block value.
pub(crate) fn for_init_block(bindings: Vec<(String, Expression)>) -> Expression {
    Expression {
        expr: Some(Expr::Block(Box::new(Block {
            statements: bindings
                .into_iter()
                .map(|(name, value)| let_stmt(name, value))
                .collect(),
            result: None,
        }))),
    }
}

pub(crate) fn std_call(function: &str, input: Option<Expression>) -> Expression {
    Expression {
        expr: Some(Expr::Call(Box::new(FunctionCall {
            module: "std".to_string(),
            function: function.to_string(),
            input: input.map(Box::new),
            type_args: vec![],
        }))),
    }
}

pub(crate) fn collections_call(function: &str, input: Option<Expression>) -> Expression {
    Expression {
        expr: Some(Expr::Call(Box::new(FunctionCall {
            module: "std_collections".to_string(),
            function: function.to_string(),
            input: input.map(Box::new),
            type_args: vec![],
        }))),
    }
}

/// `std.if(condition, then, else)` — shared by `control_flow.rs` (if/if
/// let/match/try) and `methods.rs` (`.unwrap()`/`.unwrap_or()`).
pub(crate) fn if_call(
    condition: Expression,
    then: Expression,
    else_branch: Expression,
) -> Expression {
    std_call(
        "if",
        Some(args_message(vec![
            ("condition", condition),
            ("then", then),
            ("else", else_branch),
        ])),
    )
}

/// The unified Option/Result "outcome" value both `?` and `if let`/`match`
/// (in `control_flow.rs`) operate on: `{is_err: bool, value: <T | E |
/// null>}`. `Some(x)`/`Ok(x)` -> `{is_err: false, value: x}`;
/// `None`/`Err(e)` -> `{is_err: true, value: e_or_null}`. A single shape
/// for both Rust types is a deliberate simplification (this is a
/// syntax-only encoder with no type inference — see the module doc comment
/// — so it cannot always tell an `Option` `?`/`if let` apart from a
/// `Result` one); real, independently-typed `Option`/`Result`
/// `TypeDefinition`s are #43's job.
pub(crate) fn option_result_message(is_err: bool, value: Expression) -> Expression {
    Expression {
        expr: Some(Expr::MessageCreation(MessageCreation {
            type_name: "Result".to_string(),
            fields: vec![
                FieldValuePair {
                    name: "is_err".to_string(),
                    value: Some(bool_literal(is_err)),
                },
                FieldValuePair {
                    name: "value".to_string(),
                    value: Some(value),
                },
            ],
            metadata: None,
        })),
    }
}

/// Builds the `metadata.params = [{name: <name>}]` shape
/// `ball_compiler::Compiler::param_alias_prologue` reads to alias a
/// function/closure's single named parameter to a real local binding
/// (mirrors `rust/compiler/tests/end_to_end.rs`'s `single_param_metadata`
/// test helper — the exact same shape Dart's `_encodeParamsMeta` emits).
pub(crate) fn single_param_metadata(name: &str) -> Struct {
    let mut param_fields = HashMap::new();
    param_fields.insert(
        "name".to_string(),
        Value {
            kind: Some(Kind::StringValue(name.to_string())),
        },
    );
    let mut fields = HashMap::new();
    fields.insert(
        "params".to_string(),
        Value {
            kind: Some(Kind::ListValue(ListValue {
                values: vec![Value {
                    kind: Some(Kind::StructValue(Struct {
                        fields: param_fields,
                    })),
                }],
            })),
        },
    );
    Struct { fields }
}

// ════════════════════════════════════════════════════════════
// syn helpers
// ════════════════════════════════════════════════════════════

/// Extract `(name, type-as-string)` for every declared parameter of a
/// function signature. Fails loud on `self` receivers (method emission is
/// #43's scope) and on destructuring parameter patterns (`fn f((a, b):
/// (i64, i64))`, deferred).
fn param_names_and_types(sig: &syn::Signature) -> Vec<(String, String)> {
    sig.inputs
        .iter()
        .map(|arg| match arg {
            syn::FnArg::Typed(pat_type) => {
                let name = match pat_type.pat.as_ref() {
                    syn::Pat::Ident(syn::PatIdent {
                        ident,
                        subpat: None,
                        ..
                    }) => ident.to_string(),
                    other => panic!(
                        "ball-encoder: only simple identifier function parameters are supported \
                         (destructuring parameters are deferred): {}",
                        quote::quote!(#other)
                    ),
                };
                (name, type_to_string(&pat_type.ty))
            }
            syn::FnArg::Receiver(_) => panic!(
                "ball-encoder: `self` methods need TypeDefinition/impl-block emission — deferred \
                 to issue #43 (Phase 3a covers free functions only)"
            ),
        })
        .collect()
}

/// Best-effort, purely cosmetic stringification of a `syn::Type` for
/// `FunctionDefinition.input_type`/`output_type` (informational only —
/// `ball-compiler` never parses these strings back).
fn type_to_string(ty: &syn::Type) -> String {
    quote::quote!(#ty).to_string().replace(' ', "")
}

fn path_to_string(path: &syn::Path) -> String {
    quote::quote!(#path).to_string()
}

/// A conservative heuristic used only to disambiguate `/`'s int-truncating
/// vs always-double semantics (see [`Encoder::encode_binary`]): does this
/// operand *syntactically* look like a float (a float literal, or a
/// negation of one)?
fn looks_like_float(expr: &syn::Expr) -> bool {
    match expr {
        syn::Expr::Lit(lit) => matches!(lit.lit, syn::Lit::Float(_)),
        syn::Expr::Unary(unary) => looks_like_float(&unary.expr),
        syn::Expr::Paren(paren) => looks_like_float(&paren.expr),
        _ => false,
    }
}

fn expr_kind_name(expr: &syn::Expr) -> &'static str {
    match expr {
        syn::Expr::Struct(_) => "struct literal",
        syn::Expr::Repeat(_) => "array-repeat literal",
        syn::Expr::Range(_) => "standalone range",
        syn::Expr::Let(_) => "let-guard outside if/while",
        syn::Expr::Tuple(_) => "tuple",
        syn::Expr::Await(_) => "await",
        syn::Expr::Async(_) => "async block",
        syn::Expr::Yield(_) => "yield",
        _ => "expression",
    }
}

#[cfg(test)]
mod tests {
    //! Fast, in-process structural tests covering the operator/construct
    //! breadth issue #42's checklist enumerates (arithmetic, comparison,
    //! logic, bitwise, assignment, field/index, closures, macros, loops).
    //! `tests/end_to_end.rs` covers the *executable* proof (encode ->
    //! compile -> `cargo run`, with independently hand-computed expected
    //! output) — these tests instead assert directly on the encoded
    //! `Expression` tree shape, which is both faster (no subprocess) and a
    //! more precise check that a specific Rust construct maps to the
    //! specific `std`/`std_collections` function the issue names.
    use super::*;

    /// Encode a single fn named `f` and return its (block-unwrapped) body:
    /// every fn body is wrapped in a `block` by `encode_block`, so for a
    /// one-expression body this peels that wrapper away, returning the
    /// `block`'s `result` — the tree these tests actually want to inspect.
    fn encode_fn_tail(src: &str) -> Expression {
        let wrapped = format!("fn f{src}");
        let module = encode_module_only(&wrapped);
        let f = module
            .functions
            .iter()
            .find(|func| func.name == "f")
            .expect("fn `f` must be encoded");
        let body = *f.body.clone().expect("fn `f` must have a body");
        match body.expr {
            Some(Expr::Block(block)) => *block.result.expect("block must have a result"),
            _ => body,
        }
    }

    /// Like [`encode_fn_tail`] but returns the fn body's **outer `Block`
    /// itself** (statements included) rather than unwrapping to its
    /// `result` — for tests that need to inspect a statement-list body
    /// (`{ let x = ...; for ... { } }`) instead of a single tail
    /// expression.
    fn encode_fn_block(src: &str) -> Block {
        let wrapped = format!("fn f{src}");
        let module = encode_module_only(&wrapped);
        let f = module
            .functions
            .iter()
            .find(|func| func.name == "f")
            .expect("fn `f` must be encoded");
        let body = *f.body.clone().expect("fn `f` must have a body");
        match body.expr {
            Some(Expr::Block(block)) => *block,
            other => panic!("expected `f`'s body to be a block, got {other:?}"),
        }
    }

    fn as_call(expr: &Expression) -> &FunctionCall {
        match &expr.expr {
            Some(Expr::Call(call)) => call,
            other => panic!("expected a `call` expression, got {other:?}"),
        }
    }

    fn field<'a>(expr: &'a Expression, name: &str) -> &'a Expression {
        let call = as_call(expr);
        let input = call.input.as_deref().expect("call must have an input");
        let Some(Expr::MessageCreation(message)) = &input.expr else {
            panic!("expected the call's input to be a `message_creation`, got {input:?}");
        };
        message
            .fields
            .iter()
            .find(|f| f.name == name)
            .unwrap_or_else(|| panic!("field `{name}` not found in {message:?}"))
            .value
            .as_ref()
            .expect("field must carry a value")
    }

    // ── binary operators ─────────────────────────────────────

    #[test]
    fn arithmetic_operators_map_to_std_functions() {
        let cases = [
            ("(a: i64, b: i64) -> i64 { a + b }", "add"),
            ("(a: i64, b: i64) -> i64 { a - b }", "subtract"),
            ("(a: i64, b: i64) -> i64 { a * b }", "multiply"),
            ("(a: i64, b: i64) -> i64 { a % b }", "modulo"),
        ];
        for (src, expected_fn) in cases {
            let body = encode_fn_tail(src);
            let call = as_call(&body);
            assert_eq!(call.module, "std");
            assert_eq!(call.function, expected_fn, "for source: {src}");
        }
    }

    #[test]
    fn division_heuristic_picks_divide_vs_divide_double() {
        let int_div = encode_fn_tail("(a: i64, b: i64) -> i64 { a / b }");
        assert_eq!(as_call(&int_div).function, "divide");

        let float_div = encode_fn_tail("(a: f64) -> f64 { a / 2.0 }");
        assert_eq!(as_call(&float_div).function, "divide_double");
    }

    #[test]
    fn comparison_operators_map_to_std_functions() {
        let cases = [
            ("(a: i64, b: i64) -> bool { a == b }", "equals"),
            ("(a: i64, b: i64) -> bool { a != b }", "not_equals"),
            ("(a: i64, b: i64) -> bool { a < b }", "less_than"),
            ("(a: i64, b: i64) -> bool { a > b }", "greater_than"),
            ("(a: i64, b: i64) -> bool { a <= b }", "lte"),
            ("(a: i64, b: i64) -> bool { a >= b }", "gte"),
        ];
        for (src, expected_fn) in cases {
            assert_eq!(
                as_call(&encode_fn_tail(src)).function,
                expected_fn,
                "for {src}"
            );
        }
    }

    #[test]
    fn logic_and_bitwise_operators_map_to_std_functions() {
        let cases = [
            ("(a: bool, b: bool) -> bool { a && b }", "and"),
            ("(a: bool, b: bool) -> bool { a || b }", "or"),
            ("(a: i64, b: i64) -> i64 { a & b }", "bitwise_and"),
            ("(a: i64, b: i64) -> i64 { a | b }", "bitwise_or"),
            ("(a: i64, b: i64) -> i64 { a ^ b }", "bitwise_xor"),
            ("(a: i64, b: i64) -> i64 { a << b }", "left_shift"),
            ("(a: i64, b: i64) -> i64 { a >> b }", "right_shift"),
        ];
        for (src, expected_fn) in cases {
            assert_eq!(
                as_call(&encode_fn_tail(src)).function,
                expected_fn,
                "for {src}"
            );
        }
        assert_eq!(
            as_call(&encode_fn_tail("(a: bool) -> bool { !a }")).function,
            "not"
        );
        assert_eq!(
            as_call(&encode_fn_tail("(a: i64) -> i64 { -a }")).function,
            "negate"
        );
    }

    #[test]
    fn compound_assignment_ops_carry_the_rust_op_token() {
        let cases = [
            ("fn f(a: i64) { let mut x = a; x += 1; }", "+="),
            ("fn f(a: i64) { let mut x = a; x -= 1; }", "-="),
            ("fn f(a: i64) { let mut x = a; x *= 2; }", "*="),
            ("fn f(a: i64) { let mut x = a; x /= 2; }", "/="),
        ];
        for (src, expected_op) in cases {
            let module = encode_module_only(src);
            let f = module.functions.iter().find(|f| f.name == "f").unwrap();
            let body = f.body.clone().unwrap();
            let Some(Expr::Block(block)) = &body.expr else {
                panic!("expected a block body for: {src}");
            };
            let assign_stmt = &block.statements[1];
            let Some(BallStmt::Expression(assign_expr)) = &assign_stmt.stmt else {
                panic!("expected the second statement to be an expression statement: {src}");
            };
            assert_eq!(as_call(assign_expr).function, "assign");
            let op_field = field(assign_expr, "op");
            assert_eq!(
                op_field.expr,
                Some(Expr::Literal(Literal {
                    value: Some(LiteralValue::StringValue(expected_op.to_string()))
                })),
                "for source: {src}"
            );
        }
    }

    // ── literals ──────────────────────────────────────────────

    #[test]
    fn literal_kinds_encode_correctly() {
        assert_eq!(
            encode_fn_tail("() -> i64 { 42 }").expr,
            Some(Expr::Literal(Literal {
                value: Some(LiteralValue::IntValue(42))
            }))
        );
        assert_eq!(
            encode_fn_tail("() -> f64 { 3.5 }").expr,
            Some(Expr::Literal(Literal {
                value: Some(LiteralValue::DoubleValue(3.5))
            }))
        );
        assert_eq!(
            encode_fn_tail("() -> bool { true }").expr,
            Some(Expr::Literal(Literal {
                value: Some(LiteralValue::BoolValue(true))
            }))
        );
        assert_eq!(
            encode_fn_tail(r#"() -> &'static str { "hi" }"#).expr,
            Some(Expr::Literal(Literal {
                value: Some(LiteralValue::StringValue("hi".to_string()))
            }))
        );
    }

    // ── path / reference resolution ──────────────────────────

    #[test]
    fn single_parameter_resolves_to_a_bare_named_reference() {
        let body = encode_fn_tail("(n: i64) -> i64 { n }");
        assert_eq!(
            body.expr,
            Some(Expr::Reference(Reference {
                name: "n".to_string()
            }))
        );
    }

    #[test]
    fn single_parameter_function_gets_params_metadata() {
        let module = encode_module_only("fn f(n: i64) -> i64 { n }");
        let f = module.functions.iter().find(|f| f.name == "f").unwrap();
        let metadata = f.metadata.as_ref().expect("must carry params metadata");
        assert!(metadata.fields.contains_key("params"));
    }

    #[test]
    fn multi_parameter_references_use_field_access_on_input() {
        let body = encode_fn_tail("(a: i64, b: i64) -> i64 { a }");
        let Some(Expr::FieldAccess(field_access)) = &body.expr else {
            panic!("expected a `field_access`, got {body:?}");
        };
        assert_eq!(field_access.field, "a");
        assert_eq!(
            field_access.object.as_deref().and_then(|o| o.expr.clone()),
            Some(Expr::Reference(Reference {
                name: "input".to_string()
            }))
        );
    }

    #[test]
    fn zero_parameter_function_has_no_params_metadata() {
        let module = encode_module_only("fn f() -> i64 { 1 }");
        let f = module.functions.iter().find(|f| f.name == "f").unwrap();
        assert!(f.metadata.is_none());
    }

    // ── field access / index ──────────────────────────────────

    #[test]
    fn field_access_and_index_encode_correctly() {
        let field_body = encode_fn_tail("(p: i64) -> i64 { p.0 }");
        assert!(matches!(field_body.expr, Some(Expr::FieldAccess(_))));

        let index_body = encode_fn_tail("(v: i64) -> i64 { v[0] }");
        let call = as_call(&index_body);
        assert_eq!(call.module, "std");
        assert_eq!(call.function, "index");
    }

    // ── closures ──────────────────────────────────────────────

    #[test]
    fn single_param_closure_encodes_as_a_lambda_with_bare_reference() {
        let block = encode_fn_block("() { let f = |x| x + 1; }");
        let Some(BallStmt::Let(let_binding)) = &block.statements[0].stmt else {
            panic!("expected a let binding");
        };
        let closure_expr = let_binding.value.as_ref().unwrap();
        let Some(Expr::Lambda(lambda)) = &closure_expr.expr else {
            panic!("expected a `lambda`, got {closure_expr:?}");
        };
        assert_eq!(lambda.name, "");
        // `|x| x + 1` is the brace-less closure shorthand — its body
        // encodes directly to the `add` call, with no enclosing `block`
        // (only a braced `|x| { x + 1 }` body would go through
        // `encode_block`).
        let lambda_body = lambda.body.as_ref().unwrap();
        assert_eq!(as_call(lambda_body).function, "add");
    }

    // ── macros ────────────────────────────────────────────────

    #[test]
    fn vec_macro_encodes_as_a_list_literal() {
        let body = encode_fn_tail("() -> Vec<i64> { vec![1, 2, 3] }");
        let Some(Expr::Literal(Literal {
            value: Some(LiteralValue::ListValue(list)),
        })) = &body.expr
        else {
            panic!("expected a list literal, got {body:?}");
        };
        assert_eq!(list.elements.len(), 3);
    }

    #[test]
    fn println_with_placeholder_builds_a_to_string_print_call() {
        let module = encode_module_only(r#"fn f(n: i64) { println!("n = {}", n); }"#);
        let f = module.functions.iter().find(|f| f.name == "f").unwrap();
        let body = f.body.clone().unwrap();
        let Some(Expr::Block(block)) = &body.expr else {
            panic!("expected a block body");
        };
        let Some(BallStmt::Expression(print_expr)) = &block.statements[0].stmt else {
            panic!("expected an expression statement");
        };
        let print_call = as_call(print_expr);
        assert_eq!(print_call.module, "std");
        assert_eq!(print_call.function, "print");
    }

    // ── loops ─────────────────────────────────────────────────

    #[test]
    fn range_for_loop_desugars_to_std_for() {
        let block = encode_fn_block("() { for i in 0..5 { } }");
        // A brace-less-semicolon block-form expression (`for`/`while`/
        // `loop`/`if`/...) in tail position, with no explicit trailing
        // `;`, is carried through as the block's `result` — see
        // `block.rs::encode_block`'s doc comment.
        let for_expr = block.result.as_deref().expect("block must have a result");
        assert_eq!(as_call(for_expr).function, "for");
    }

    #[test]
    fn iterable_for_loop_desugars_to_std_for_in() {
        let block = encode_fn_block("(items: i64) { for x in items { } }");
        let for_expr = block.result.as_deref().expect("block must have a result");
        assert_eq!(as_call(for_expr).function, "for_in");
    }

    #[test]
    fn bare_loop_desugars_to_while_true() {
        let block = encode_fn_block("() { loop { break; } }");
        let loop_expr = block.result.as_deref().expect("block must have a result");
        let call = as_call(loop_expr);
        assert_eq!(call.function, "while");
        let condition = field(loop_expr, "condition");
        assert_eq!(
            condition.expr,
            Some(Expr::Literal(Literal {
                value: Some(LiteralValue::BoolValue(true))
            }))
        );
    }

    #[test]
    fn labeled_loop_wraps_in_std_label() {
        let block = encode_fn_block("() { 'outer: for i in 0..3 { break 'outer; } }");
        let label_expr = block.result.as_deref().expect("block must have a result");
        let call = as_call(label_expr);
        assert_eq!(call.function, "label");
        let name_field = field(label_expr, "name");
        assert_eq!(
            name_field.expr,
            Some(Expr::Literal(Literal {
                value: Some(LiteralValue::StringValue("outer".to_string()))
            }))
        );
    }

    // ── Option/Result outcome shape ──────────────────────────

    #[test]
    fn none_encodes_as_the_unified_outcome_message() {
        let body = encode_fn_tail("() { None }");
        let Some(Expr::MessageCreation(message)) = &body.expr else {
            panic!("expected a `message_creation`, got {body:?}");
        };
        assert_eq!(message.type_name, "Result");
        let is_err = message.fields.iter().find(|f| f.name == "is_err").unwrap();
        assert_eq!(
            is_err.value.as_ref().unwrap().expr,
            Some(Expr::Literal(Literal {
                value: Some(LiteralValue::BoolValue(true))
            }))
        );
    }

    #[test]
    fn string_from_is_an_identity_passthrough() {
        let body = encode_fn_tail(r#"() -> &'static str { String::from("hi") }"#);
        assert_eq!(
            body.expr,
            Some(Expr::Literal(Literal {
                value: Some(LiteralValue::StringValue("hi".to_string()))
            }))
        );
    }

    // ── std module accumulation ──────────────────────────────

    #[test]
    fn program_always_includes_std_and_conditionally_std_collections() {
        let no_collections = encode("fn main() { println!(\"{}\", 1); }");
        assert!(no_collections.modules.iter().any(|m| m.name == "std"));
        assert!(
            !no_collections
                .modules
                .iter()
                .any(|m| m.name == "std_collections")
        );

        let with_collections = encode(
            "fn main() { let v = vec![1, 2, 3]; let _ = v.iter().map(|x| x + 1).collect::<Vec<i64>>(); }",
        );
        assert!(
            with_collections
                .modules
                .iter()
                .any(|m| m.name == "std_collections")
        );
    }
}
