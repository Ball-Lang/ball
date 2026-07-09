//! `call` (base-function) compilation — the dispatch table that turns
//! `std`/`std_collections`/`std_io` base-function calls into native Rust
//! (issue #37). Base functions have no body (invariant #3) — this module
//! *is* their Rust implementation, mirroring `dart/compiler/lib/compiler.dart`'s
//! `_compileBaseCall` (the authoritative reference — read it first when in
//! doubt) and the C++/TS equivalents (`cpp/compiler/src/compiler.cpp`,
//! `ts/compiler/src/compiler.ts`).
//!
//! Arithmetic/comparison/logic/bitwise/string/math/collection operators
//! delegate to plain functions in `ball_shared::runtime` (see that module's
//! doc comment for why — short version: it's the Rust analog of
//! `cpp/shared/include/ball_dyn.h`'s operator overloads, and it's
//! unit-testable on its own). **This module's own job is exclusively the
//! handful of constructs a runtime function call fundamentally can't
//! express: lazy control flow.**
//!
//! ## Lazy control flow (invariant #4 — the crux of this issue)
//!
//! `if`/`and`/`or`/`for`/`for_in`/`while`/`do_while` compile to **native
//! Rust control flow**, never to a call that would evaluate every branch/
//! operand up front:
//! - `if(cond, then, else)` → a real Rust `if cond { then } else { else }` —
//!   only the taken arm's compiled code ever runs.
//! - `and`/`or` → native `&&`/`||` (`compile_and`/`compile_or`) — Rust's own
//!   short-circuit evaluation means the right operand's source text is never
//!   *reached*, not just "not used", when the left operand decides the
//!   result. This is what makes the laziness fixture's "untaken branch
//!   would panic/print if evaluated" assertion hold.
//! - `for`/`for_in`/`while`/`do_while` → native Rust `while`/`for`/`loop`
//!   with the loop body compiled directly inline as the loop's own block —
//!   never pre-evaluated or evaluated more/fewer times than the native
//!   construct naturally would.
//!
//! A runtime **function call**, by contrast, cannot be lazy — Rust always
//! evaluates every argument expression before making the call — which is
//! exactly why `and`/`or`/`null_coalesce` are hand-written here instead of
//! going through `ball_shared::runtime` like every other binary operator.
//!
//! ## Assignment / mutation
//!
//! `assign`, `pre_increment`/`post_increment`/`pre_decrement`/
//! `post_decrement`, and the mutating `std_collections` calls (`list_push`,
//! `map_set`, ...) all route through `crate::lvalue` — see that module's
//! doc comment for why a `.clone()`d read isn't good enough for a mutation
//! target.
//!
//! ## Scope boundary (read before extending)
//!
//! Deliberately deferred to a clean runtime-helper fallback
//! ([`ball_unsupported_base_call`], never a compile-time panic — a program
//! that doesn't reach the unimplemented path still compiles and runs):
//! `regex_*` (needs a new `regex` crate dependency), `list_reduce`/
//! `list_sort`/`list_sort_by`/`map_map`/`map_filter` (need a genuinely
//! multi-parameter callback — Ball's lambda convention is single-`input`
//! only until #38's typed parameter destructuring), `rethrow` (needs
//! "current exception in scope" context threading through `try`/`catch`),
//! `yield`/`await` (generators/async are a different control-flow model —
//! not attempted here), `goto` (no Rust equivalent without a state-machine
//! transform), and all of `std_memory` (linear-memory/pointer model, not
//! yet designed for this target). `try`/`switch` are implemented at a
//! deliberately minimal level (single untaken-catch-type dispatch / no
//! fall-through) — see [`Compiler::compile_try`]/[`Compiler::compile_switch`]'s
//! own doc comments for the exact limitation.
use indexmap::IndexMap;

use ball_shared::extract_fields;
use ball_shared::proto::ball::v1::expression::Expr;
use ball_shared::proto::ball::v1::literal::Value as LiteralValue;
use ball_shared::proto::ball::v1::{Expression, FunctionCall, ListLiteral, MessageCreation};

use crate::Compiler;

impl Compiler<'_> {
    /// `call` — the shared entry point for both node types folded under
    /// `Expression::Call`: a base-module call (dispatches to
    /// [`Compiler::compile_base_call`]) or a user-module call. A user call
    /// compiles to plain Rust call syntax `<function>(<input>)`, or
    /// `<mod>::<function>(<input>)` when `call.module` names a *different*
    /// user module than the one currently being compiled (issue #38's
    /// multi-module output — see `crate::type_emit::resolve_user_call_name`).
    /// Per Ball's "one input, one output" convention (invariant #1) there is
    /// exactly one argument, so no argument-list flattening is needed.
    /// `call.module` empty means "current module" (resolves the same way: a
    /// bare Rust identifier call).
    pub(crate) fn compile_call(&self, call: &FunctionCall) -> String {
        if self.is_base_module(&call.module) {
            return self.compile_base_call(call);
        }
        let prefix = self.resolve_user_call_name(&call.module);
        let name = crate::sanitize_ident(&call.function);
        let input = match &call.input {
            Some(input) => self.compile_expression(input),
            None => "BallValue::Null".to_string(),
        };
        // A callee that is a **local binding** (a `let`/parameter holding a
        // `BallValue::Function` — a stored `lambda`, a `scope.lookup(name)`
        // result, a callback parameter `op`/`predicate`/`callback`, the
        // `arg0` of `Function.apply`) is a call *through a value*: that local
        // is a `BallValue`, not a callable Rust item, so `name(input)` is
        // `error[E0618]` "expected function, found `BallValue`". Route it
        // through the dynamic dispatcher (issue #39, gap #6). Every *other*
        // unqualified callee names a real Rust `fn` — a user function or a
        // `ball_shared::runtime` Dart-SDK helper (`unmodifiable`/`now`/`cast`/
        // …) — and stays a direct call; only lexical scope (not the name
        // alone) distinguishes the two, since a local can shadow a function
        // of the same name. A cross-module call (non-empty `prefix`) is always
        // a real function.
        if prefix.is_empty() && self.is_local(&call.function) {
            return format!("ball_call_function({name}.clone(), {input})");
        }
        // Implicit-`this` receiver injection (issue #298): a call to an
        // instance-method dispatcher (which reads `input.self`) made from inside
        // an instance method/constructor body, with no explicit `self` already
        // in its input, is a `this.method(args)` call — the encoder packs only
        // the arguments. Weave `self_` (the enclosing receiver) into the input
        // so the dispatcher finds a receiver instead of `Null` (which would make
        // `ball_message_type_name` panic). An explicit `obj.method(args)` (whose
        // input already carries `self`) is left untouched.
        if prefix.is_empty()
            && self.in_instance_method()
            && self.instance_method_names.contains(&name)
            && !Self::call_input_has_explicit_self(call)
        {
            // The injection *shape* depends on how the encoder packed the
            // arguments (issue #300): a **multi-argument** call packs an
            // anonymous `{arg0, arg1, …}` message and a **zero-argument** call
            // packs nothing — both merge `self` in via `ball_with_self`
            // (`Null` → `{self}`). A **single positional** argument is passed
            // *directly* (not wrapped in `{arg0: …}`), so it must become
            // `{self, arg0: arg}` via `ball_arg0_with_self` — otherwise
            // `ball_with_self` would bury a message-shaped argument (e.g.
            // `func.body`) and leave the method's parameter `Null`.
            if Self::call_input_is_arg_message(call) || call.input.is_none() {
                return format!("{name}(ball_with_self({input}, __self_recv.clone()))");
            }
            return format!("{name}(ball_arg0_with_self({input}, __self_recv.clone()))");
        }
        format!("{prefix}{name}({input})")
    }

    /// Base-function dispatch table, routed first by `call.module`
    /// (`std_collections`/`std_io` get their own sub-tables, mirroring
    /// `_compileCollectionsCall`/`_compileIoCall` in the Dart reference) and
    /// then by `call.function` within `std` itself.
    fn compile_base_call(&self, call: &FunctionCall) -> String {
        match call.module.as_str() {
            "std_collections" => return self.compile_collections_call(call),
            "std_io" => return self.compile_io_call(call),
            "std_convert" => return self.compile_convert_call(call),
            "ball_proto" => return self.compile_ball_proto_call(call),
            "std_memory" => {
                return format!(
                    "ball_unsupported_base_call({:?}, {:?})",
                    call.module, call.function
                );
            }
            _ => {}
        }

        // Constructs needing the raw `FunctionCall` (lazy control flow that
        // dispatches on nested calls, or a repeated-`Expression` field) skip
        // `extract_fields` up front.
        match call.function.as_str() {
            "and" => return self.compile_and(call),
            "or" => return self.compile_or(call),
            "null_coalesce" => return self.compile_null_coalesce(call),
            "for" => return self.compile_for(call, None),
            "for_in" => return self.compile_for_in(call, None),
            "while" => return self.compile_while(call, None),
            "do_while" => return self.compile_do_while(call, None),
            "label" => return self.compile_label(call),
            "switch" => return self.compile_switch(call),
            "switch_expr" => return self.compile_switch(call),
            "map_create" => return self.compile_map_create(call),
            "record" => return self.compile_record(call),
            "invoke" => return self.compile_invoke(call),
            "try" => return self.compile_try(call),
            "assign" => return self.compile_assign(call),
            "pre_increment" => return self.compile_mutate_by_one(call, "+=", false),
            "post_increment" => return self.compile_mutate_by_one(call, "+=", true),
            "pre_decrement" => return self.compile_mutate_by_one(call, "-=", false),
            "post_decrement" => return self.compile_mutate_by_one(call, "-=", true),
            _ => {}
        }

        let f = extract_fields(call);
        match call.function.as_str() {
            "print" => self.compile_print(&f),
            // ── Arithmetic ──
            "add" => self.bin("ball_add", &f),
            "subtract" => self.bin("ball_subtract", &f),
            "multiply" => self.bin("ball_multiply", &f),
            "divide" => self.bin("ball_divide", &f),
            "divide_double" => self.bin("ball_divide_double", &f),
            "modulo" => self.bin("ball_modulo", &f),
            "negate" => self.un("ball_negate", &f),
            // ── Comparison ──
            "equals" => self.bin("ball_equals", &f),
            "not_equals" => self.bin("ball_not_equals", &f),
            "less_than" => self.bin("ball_less_than", &f),
            "greater_than" => self.bin("ball_greater_than", &f),
            "lte" => self.bin("ball_lte", &f),
            "gte" => self.bin("ball_gte", &f),
            "compare_to" => self.bin_alias(
                "ball_compare_to",
                &f,
                &["left", "value"],
                &["right", "other"],
            ),
            // ── Logic / bitwise ──
            "not" => self.un("ball_not", &f),
            "bitwise_and" => self.bin("ball_bitwise_and", &f),
            "bitwise_or" => self.bin("ball_bitwise_or", &f),
            "bitwise_xor" => self.bin("ball_bitwise_xor", &f),
            "bitwise_not" => self.un("ball_bitwise_not", &f),
            "left_shift" => self.bin("ball_left_shift", &f),
            "right_shift" => self.bin("ball_right_shift", &f),
            "unsigned_right_shift" => self.bin("ball_unsigned_right_shift", &f),
            // ── String & conversion ──
            "concat" | "string_concat" => self.bin("ball_add", &f),
            "to_string" | "int_to_string" | "double_to_string" => self.un("ball_to_string", &f),
            "length" | "string_length" => self.un("ball_length", &f),
            "string_to_int" => self.un("ball_string_to_int", &f),
            "string_to_double" => self.un("ball_string_to_double", &f),
            "to_double" => self.un("ball_to_double", &f),
            "to_int" => self.un("ball_to_int", &f),
            "round_to_double" => self.un("ball_round_to_double", &f),
            "floor_to_double" => self.un("ball_floor_to_double", &f),
            "ceil_to_double" => self.un("ball_ceil_to_double", &f),
            "truncate_to_double" => self.un("ball_truncate_to_double", &f),
            "to_string_as_fixed" => {
                self.compile_2("ball_to_string_as_fixed", &f, "value", "digits")
            }
            "string_code_unit_at" => {
                self.compile_2("ball_string_code_unit_at", &f, "value", "index")
            }
            // Collection literals whose semantic content is just the underlying
            // list (the type arguments are cosmetic and dropped — same as every
            // reference engine): `<T>[...]` and `<T>{...}` (a typed set). An
            // absent `elements` field means an empty literal.
            "typed_list" => self.field_list_or_empty(&f, "elements"),
            "set_create" => format!(
                "ball_set_create({})",
                self.field_list_or_empty(&f, "elements")
            ),
            // ── Null safety ──
            "null_check" => self.un("ball_null_check", &f),
            // ── Control flow (non-lazy leaves: `if` already handled inline) ──
            "if" => self.compile_if(&f),
            // ── Error handling / flow signals ──
            "throw" => self.un("ball_throw", &f),
            "rethrow" => self.compile_rethrow(),
            "assert" => self.compile_assert(&f),
            "return" => self.compile_return(&f),
            "break" => self.compile_break(&f),
            "continue" => self.compile_continue(&f),
            // `await` in a synchronous target is the identity on its operand:
            // the value model has no futures, so awaiting a value yields the
            // value (the reference engines' `await` on a non-future does the
            // same). `paren` is a parenthesized expression — also identity.
            "await" | "paren" => self.field_or_null(&f, "value"),
            // `spread` outside a collection literal (a standalone call) yields
            // its operand; spread *inside* a list literal is spliced by
            // `compile_literal` (see [`Compiler::compile_list_literal`]).
            "spread" | "null_spread" => self.field_or_null(&f, "value"),
            "goto" | "yield" => self.unsupported(call),
            // ── Type operations ──
            "is" => self.compile_type_op("ball_is", &f),
            "is_not" => self.compile_type_op("ball_is_not", &f),
            "as" => self.compile_type_op("ball_as", &f),
            // ── Indexing ──
            "index" | "string_char_at" => self.compile_index(&f),
            // ── Strings (pure manipulation) ──
            "string_is_empty" => self.un("ball_string_is_empty", &f),
            "string_contains" => self.bin("ball_string_contains", &f),
            "string_starts_with" => self.bin("ball_string_starts_with", &f),
            "string_ends_with" => self.bin("ball_string_ends_with", &f),
            "string_index_of" => self.bin("ball_string_index_of", &f),
            "string_last_index_of" => self.bin("ball_string_last_index_of", &f),
            "string_substring" => self.tri("ball_string_substring", &f, "value", "start", "end"),
            "string_char_code_at" => self.compile_index_named("ball_string_char_code_at", &f),
            "string_from_char_code" => self.un("ball_string_from_char_code", &f),
            "string_to_upper" => self.un("ball_string_to_upper", &f),
            "string_to_lower" => self.un("ball_string_to_lower", &f),
            "string_trim" => self.un("ball_string_trim", &f),
            "string_trim_start" => self.un("ball_string_trim_start", &f),
            "string_trim_end" => self.un("ball_string_trim_end", &f),
            "string_replace" => self.tri("ball_string_replace", &f, "value", "from", "to"),
            "string_replace_all" => self.tri("ball_string_replace_all", &f, "value", "from", "to"),
            "string_split" => self.bin_alias(
                "ball_string_split",
                &f,
                &["left", "value", "string"],
                &["right", "separator", "delimiter"],
            ),
            "string_runes" => self.un("ball_string_runes", &f),
            "string_repeat" => self.compile_2("ball_string_repeat", &f, "value", "count"),
            "string_pad_left" => self.tri("ball_string_pad_left", &f, "value", "width", "padding"),
            "string_pad_right" => {
                self.tri("ball_string_pad_right", &f, "value", "width", "padding")
            }
            // ── Regex (deferred — needs a `regex` crate dependency) ──
            "regex_match" | "regex_find" | "regex_find_all" | "regex_replace"
            | "regex_replace_all" => self.unsupported(call),
            // ── Math ──
            "math_abs" => self.un("ball_math_abs", &f),
            "math_floor" => self.un("ball_math_floor", &f),
            "math_ceil" => self.un("ball_math_ceil", &f),
            "math_round" => self.un("ball_math_round", &f),
            "math_trunc" => self.un("ball_math_trunc", &f),
            "math_sqrt" => self.un("ball_math_sqrt", &f),
            "math_pow" => self.bin("ball_math_pow", &f),
            "math_log" => self.un("ball_math_log", &f),
            "math_log2" => self.un("ball_math_log2", &f),
            "math_log10" => self.un("ball_math_log10", &f),
            "math_exp" => self.un("ball_math_exp", &f),
            "math_sin" => self.un("ball_math_sin", &f),
            "math_cos" => self.un("ball_math_cos", &f),
            "math_tan" => self.un("ball_math_tan", &f),
            "math_asin" => self.un("ball_math_asin", &f),
            "math_acos" => self.un("ball_math_acos", &f),
            "math_atan" => self.un("ball_math_atan", &f),
            "math_atan2" => self.bin("ball_math_atan2", &f),
            "math_min" => self.bin("ball_math_min", &f),
            "math_max" => self.bin("ball_math_max", &f),
            "math_clamp" => self.tri("ball_math_clamp", &f, "value", "min", "max"),
            "math_pi" => "BallValue::Double(std::f64::consts::PI)".to_string(),
            "math_e" => "BallValue::Double(std::f64::consts::E)".to_string(),
            "math_infinity" => "BallValue::Double(f64::INFINITY)".to_string(),
            "math_nan" => "BallValue::Double(f64::NAN)".to_string(),
            "math_is_nan" => self.un("ball_math_is_nan", &f),
            "math_is_finite" => self.un("ball_math_is_finite", &f),
            "math_is_infinite" => self.un("ball_math_is_infinite", &f),
            "math_sign" => self.un("ball_math_sign", &f),
            "math_gcd" => self.bin("ball_math_gcd", &f),
            "math_lcm" => self.bin("ball_math_lcm", &f),
            _ => self.unsupported(call),
        }
    }

    // ════════════════════════════════════════════════════════════
    // Field-extraction helpers
    // ════════════════════════════════════════════════════════════

    fn field_or_null(&self, fields: &IndexMap<String, Expression>, key: &str) -> String {
        match fields.get(key) {
            Some(expr) => self.compile_expression(expr),
            None => "BallValue::Null".to_string(),
        }
    }

    /// Read the first field present among `keys` (a compile-time decision —
    /// exactly one alias is emitted), else `Null`. Mirrors the Dart engine's
    /// `m['a'] ?? m['b'] ?? m['c']` tolerance for base functions whose
    /// canonical descriptor field names (e.g. `BinaryInput`'s `left`/`right`
    /// for `string_split`/`compare_to`) differ from the names the Dart
    /// *encoder* actually emits when it routes a method call (`value`/
    /// `separator` for `str.split`, `value`/`other` for `x.compareTo`). Without
    /// this, `bin`'s hard-coded `left`/`right` read `Null` and the runtime
    /// helper panics with `expected a number/string, got Null` (#39/#300).
    fn field_alias_or_null(&self, fields: &IndexMap<String, Expression>, keys: &[&str]) -> String {
        for key in keys {
            if let Some(expr) = fields.get(*key) {
                return self.compile_expression(expr);
            }
        }
        "BallValue::Null".to_string()
    }

    /// A binary base function whose two operands may arrive under any of the
    /// listed alias field names (canonical descriptor name first, then the
    /// encoder's method-routed names). See [`Compiler::field_alias_or_null`].
    fn bin_alias(
        &self,
        helper: &str,
        fields: &IndexMap<String, Expression>,
        left: &[&str],
        right: &[&str],
    ) -> String {
        format!(
            "{helper}({}, {})",
            self.field_alias_or_null(fields, left),
            self.field_alias_or_null(fields, right)
        )
    }

    /// Like [`Compiler::field_or_null`] but defaults an absent field to an
    /// **empty list** rather than `Null` — for collection-literal builders
    /// (`typed_list`/`set_create`) whose `elements` field is omitted when the
    /// literal is empty, where a `Null` would panic the list runtime helpers.
    fn field_list_or_empty(&self, fields: &IndexMap<String, Expression>, key: &str) -> String {
        match fields.get(key) {
            Some(expr) => self.compile_expression(expr),
            None => "BallValue::List(BallList::new())".to_string(),
        }
    }

    // ════════════════════════════════════════════════════════════
    // List-literal construction (spread / collection_if / collection_for)
    // ════════════════════════════════════════════════════════════

    /// If `el` is a list-literal element that must be **spliced** rather than
    /// pushed as one value — a `std.spread`/`null_spread` (`...x` / `...?x`), a
    /// `std.collection_if` (`if (c) x`), or a `std.collection_for`
    /// (`for (v in it) x`) — return its function name. These are the shapes the
    /// encoder emits inside a `ListLiteral.elements`, mirroring the reference
    /// engines' `_addCollectionElement`.
    fn collection_element_fn(el: &Expression) -> Option<&str> {
        if let Some(Expr::Call(call)) = &el.expr {
            if call.module == "std" {
                return match call.function.as_str() {
                    "spread" | "null_spread" | "collection_if" | "collection_for" => {
                        Some(call.function.as_str())
                    }
                    _ => None,
                };
            }
        }
        None
    }

    /// Compile a `ListLiteral`. The common case — every element a plain value —
    /// is a direct `vec![…]`. When any element is a spread/`collection_if`/
    /// `collection_for`, the whole literal is built imperatively so those
    /// elements *splice* their contents instead of nesting as a single element.
    /// The missing splice made the self-hosted engine's own
    /// `_ballSetOf([...items, v])` produce `{{…}, v}` (issues #39/#300).
    pub(crate) fn compile_list_literal(&self, list: &ListLiteral) -> String {
        if !list
            .elements
            .iter()
            .any(|el| Self::collection_element_fn(el).is_some())
        {
            let items = list
                .elements
                .iter()
                .map(|el| self.compile_expression(el))
                .collect::<Vec<_>>()
                .join(", ");
            return format!("BallValue::List(BallList::from(vec![{items}]))");
        }
        let mut out = String::from("{\nlet mut __lit: Vec<BallValue> = Vec::new();\n");
        for el in &list.elements {
            out.push_str(&self.compile_collection_element("__lit", el));
        }
        out.push_str("BallValue::List(BallList::from(__lit))\n}");
        out
    }

    /// Emit code appending one list-literal element to `target` (a
    /// `Vec<BallValue>` local). A plain element is `push`ed; a spread splices
    /// (`ball_spread_iter`); a `collection_if` conditionally emits its
    /// then/else element; a `collection_for` loops. Nested element forms recurse
    /// (`[if (c) ...x]` composes).
    fn compile_collection_element(&self, target: &str, el: &Expression) -> String {
        let Some(kind) = Self::collection_element_fn(el) else {
            return format!("{target}.push({});\n", self.compile_expression(el));
        };
        // `collection_element_fn` already proved this is an `Expr::Call`.
        let Some(Expr::Call(call)) = &el.expr else {
            unreachable!("collection_element_fn matched a non-call element")
        };
        let f = extract_fields(call);
        match kind {
            "spread" => format!(
                "for __sp in ball_spread_iter({}) {{ {target}.push(__sp); }}\n",
                self.field_or_null(&f, "value")
            ),
            "null_spread" => format!(
                "{{ let __sp = {}; if !matches!(__sp, BallValue::Null) {{ \
                 for __e in ball_spread_iter(__sp) {{ {target}.push(__e); }} }} }}\n",
                self.field_or_null(&f, "value")
            ),
            "collection_if" => {
                let cond = match f.get("condition") {
                    Some(c) => format!("ball_truthy({})", self.compile_expression(c)),
                    None => "false".to_string(),
                };
                let then = f
                    .get("then")
                    .map(|e| self.compile_collection_element(target, e))
                    .unwrap_or_default();
                match f.get("else") {
                    Some(else_expr) => {
                        let els = self.compile_collection_element(target, else_expr);
                        format!("if {cond} {{\n{then}}} else {{\n{els}}}\n")
                    }
                    None => format!("if {cond} {{\n{then}}}\n"),
                }
            }
            "collection_for" => self.compile_collection_for(target, &f),
            _ => unreachable!("collection_element_fn returned an unexpected kind"),
        }
    }

    /// Compile a `collection_for` list-literal element, appending each produced
    /// value to `target`. Handles both shapes the encoder emits (mirroring
    /// `compile_for`/`compile_for_in`): for-each (`variable`+`iterable`+`body`)
    /// and C-style (`init`;`condition`;`update`;`body`), each with a fresh
    /// lexical scope so the loop var resolves as a value (#39 gap #6).
    fn compile_collection_for(&self, target: &str, f: &IndexMap<String, Expression>) -> String {
        if let Some(iterable) = f.get("iterable") {
            let variable = self
                .string_field(f, "variable")
                .unwrap_or_else(|| "item".to_string());
            let var_ident = crate::sanitize_ident(&variable);
            let iterable_code = self.compile_expression(iterable);
            self.push_scope();
            self.bind_local(&variable);
            let body = f
                .get("body")
                .map(|e| self.compile_collection_element(target, e))
                .unwrap_or_default();
            self.pop_scope();
            return format!(
                "for __item in ball_iterate({iterable_code}) {{\nlet {var_ident} = __item;\n{body}}}\n"
            );
        }
        // C-style `for (init; condition; update) body`.
        self.push_scope();
        let init_code = f
            .get("init")
            .map(|e| self.compile_for_init(e))
            .unwrap_or_default();
        let condition_code = match f.get("condition") {
            Some(condition) => format!("ball_truthy({})", self.compile_expression(condition)),
            None => "true".to_string(),
        };
        let body = f
            .get("body")
            .map(|e| self.compile_collection_element(target, e))
            .unwrap_or_default();
        let update_code = f
            .get("update")
            .map(|e| self.compile_expression(e))
            .unwrap_or_default();
        self.pop_scope();
        format!(
            "{{\n{init_code}let mut __ball_cfor_first = true;\nloop {{\n\
             if __ball_cfor_first {{ __ball_cfor_first = false; }} else {{ {update_code}; }}\n\
             if !{condition_code} {{ break; }}\n{body}}}\n}}\n"
        )
    }

    /// Read a plain `string` descriptor field's value — stored as a literal
    /// string [`Expression`] inside the calling `MessageCreation` (see
    /// `dart/compiler/lib/compiler.dart`'s `_stringFieldValue`, which this
    /// mirrors exactly).
    fn string_field(&self, fields: &IndexMap<String, Expression>, key: &str) -> Option<String> {
        match fields.get(key).map(|e| &e.expr) {
            Some(Some(Expr::Literal(literal))) => match &literal.value {
                Some(LiteralValue::StringValue(value)) => Some(value.clone()),
                _ => None,
            },
            _ => None,
        }
    }

    fn bool_field(&self, fields: &IndexMap<String, Expression>, key: &str) -> bool {
        matches!(
            fields.get(key).map(|e| &e.expr),
            Some(Some(Expr::Literal(literal)))
                if matches!(&literal.value, Some(LiteralValue::BoolValue(true)))
        )
    }

    fn un(&self, helper: &str, fields: &IndexMap<String, Expression>) -> String {
        format!("{helper}({})", self.field_or_null(fields, "value"))
    }

    fn bin(&self, helper: &str, fields: &IndexMap<String, Expression>) -> String {
        format!(
            "{helper}({}, {})",
            self.field_or_null(fields, "left"),
            self.field_or_null(fields, "right")
        )
    }

    fn tri(
        &self,
        helper: &str,
        fields: &IndexMap<String, Expression>,
        a: &str,
        b: &str,
        c: &str,
    ) -> String {
        format!(
            "{helper}({}, {}, {})",
            self.field_or_null(fields, a),
            self.field_or_null(fields, b),
            self.field_or_null(fields, c)
        )
    }

    fn compile_2(
        &self,
        helper: &str,
        fields: &IndexMap<String, Expression>,
        a: &str,
        b: &str,
    ) -> String {
        format!(
            "{helper}({}, {})",
            self.field_or_null(fields, a),
            self.field_or_null(fields, b)
        )
    }

    /// Clean fallback for a base function this dispatch table doesn't
    /// special-case — see the module doc comment's scope boundary. Compiles
    /// to a *call*, not a compile-time panic, so a program that never
    /// reaches this path still compiles and runs.
    fn unsupported(&self, call: &FunctionCall) -> String {
        format!(
            "ball_unsupported_base_call({:?}, {:?})",
            call.module, call.function
        )
    }

    // ════════════════════════════════════════════════════════════
    // ball_proto — protobuf-compat AST access patterns (issue #300)
    // ════════════════════════════════════════════════════════════

    /// Route a `ball_proto.<fn>` call to its native `ball_shared::runtime`
    /// helper (implemented there; see that module's `ball_proto` section). The
    /// compiler had always lowered these to `ball_unsupported_base_call` (the
    /// long-open AGENTS gap #3), which is what blocked the self-hosted engine
    /// from *running* — it inspects every program through this module.
    fn compile_ball_proto_call(&self, call: &FunctionCall) -> String {
        let f = extract_fields(call);
        let obj = || self.field_or_null(&f, "obj");
        match call.function.as_str() {
            // Oneof discriminators.
            "whichExpr" => return format!("ball_which_expr({})", obj()),
            "whichValue" => return format!("ball_which_value({})", obj()),
            "whichStmt" => return format!("ball_which_stmt({})", obj()),
            "whichKind" => return format!("ball_which_kind({})", obj()),
            "whichSource" => return format!("ball_which_source({})", obj()),
            // Safe field access.
            "getField" => {
                return format!(
                    "ball_proto_get_field({}, {})",
                    obj(),
                    self.field_or_null(&f, "name")
                );
            }
            "getFieldOr" => {
                return format!(
                    "ball_proto_get_field_or({}, {}, {})",
                    obj(),
                    self.field_or_null(&f, "name"),
                    self.field_or_null(&f, "defaultValue")
                );
            }
            "setField" => {
                return format!(
                    "ball_proto_set_field({}, {}, {})",
                    obj(),
                    self.field_or_null(&f, "name"),
                    self.field_or_null(&f, "value")
                );
            }
            // Struct field access.
            "getStructField" => {
                return self.compile_2("ball_get_struct_field", &f, "struct", "key");
            }
            "getStringField" => {
                return self.compile_2("ball_get_string_field", &f, "struct", "key");
            }
            "getBoolField" => return self.compile_2("ball_get_bool_field", &f, "struct", "key"),
            "getListField" => return self.compile_2("ball_get_list_field", &f, "struct", "key"),
            "getNumberField" => {
                return self.compile_2("ball_get_number_field", &f, "struct", "key");
            }
            "getStructFieldKeys" => {
                return format!(
                    "ball_get_struct_field_keys({})",
                    self.field_or_null(&f, "struct")
                );
            }
            // Proto3 defaults.
            "ensureDefaults" => return format!("ball_proto_ensure_defaults({})", obj()),
            "defaultString" => return "BallValue::String(String::new())".to_string(),
            "defaultList" => return "BallValue::List(BallList::new())".to_string(),
            "defaultBool" => return "BallValue::Bool(false)".to_string(),
            "defaultInt" => return "BallValue::Int(0i64)".to_string(),
            // Case-name validators — the engine reads them back as the name.
            "exprCase" | "literalCase" | "stmtCase" => {
                return self.field_or_null(&f, "name");
            }
            _ => {}
        }
        // Presence checks: `has<Field>(obj)` → the named field's presence.
        if let Some(suffix) = call.function.strip_prefix("has") {
            if !suffix.is_empty() {
                let field = lower_first(suffix);
                return format!("ball_has_field({}, {field:?})", obj());
            }
        }
        self.unsupported(call)
    }

    // ════════════════════════════════════════════════════════════
    // std_convert
    // ════════════════════════════════════════════════════════════

    fn compile_convert_call(&self, call: &FunctionCall) -> String {
        let f = extract_fields(call);
        match call.function.as_str() {
            "utf8_encode" => self.un("ball_utf8_encode", &f),
            "utf8_decode" => self.un("ball_utf8_decode", &f),
            "base64_encode" => self.un("ball_base64_encode", &f),
            "base64_decode" => self.un("ball_base64_decode", &f),
            _ => self.unsupported(call),
        }
    }

    // ════════════════════════════════════════════════════════════
    // Collection / record literals
    // ════════════════════════════════════════════════════════════

    /// `map_create` — a map literal. The input `MessageCreation`'s fields are
    /// the entries (the cosmetic `type_args`/`elements` fields are dropped): an
    /// `entry` field carries a `{key, value}` message. Mirrors
    /// `dart/compiler/lib/compiler.dart`'s `_compileMapCreate`. Builds a
    /// `[[key, value], …]` list and hands it to the `ball_map_create` runtime
    /// helper (which stringifies keys — Ball maps are string-keyed).
    fn compile_map_create(&self, call: &FunctionCall) -> String {
        let mut pairs: Vec<String> = Vec::new();
        if let Some(Expression {
            expr: Some(Expr::MessageCreation(mc)),
        }) = call.input.as_deref()
        {
            for field in &mc.fields {
                if field.name == "type_args" || field.name == "elements" {
                    continue;
                }
                if field.name == "entry" {
                    if let Some(Expression {
                        expr: Some(Expr::MessageCreation(entry)),
                    }) = field.value.as_ref()
                    {
                        let ef = self.message_creation_fields(entry);
                        pairs.push(format!(
                            "BallValue::List(BallList::from(vec![{}, {}]))",
                            self.field_or_null(&ef, "key"),
                            self.field_or_null(&ef, "value")
                        ));
                    }
                }
            }
        }
        format!(
            "ball_map_create(BallValue::List(BallList::from(vec![{}])))",
            pairs.join(", ")
        )
    }

    /// `record` — a Dart record literal. The input `MessageCreation` already
    /// compiles to a `BallValue::Map` keyed by the record's field names
    /// (positional `$0`/`$1`/… or named), which is exactly the engine's
    /// `_stdRecord` value (`m['fields'] ?? m` — records here carry no `fields`
    /// key), so this is just its compiled input.
    fn compile_record(&self, call: &FunctionCall) -> String {
        match call.input.as_deref() {
            Some(input) => self.compile_expression(input),
            None => "BallValue::Map(BallMap::new())".to_string(),
        }
    }

    /// `invoke` — dynamically call a first-class function value. The whole
    /// input message (carrying `callee` + arguments) is handed to the
    /// `ball_invoke` runtime helper, which unpacks the callee and applies the
    /// single-`input` calling convention (see its doc comment).
    fn compile_invoke(&self, call: &FunctionCall) -> String {
        let input = match call.input.as_deref() {
            Some(input) => self.compile_expression(input),
            None => "BallValue::Null".to_string(),
        };
        format!("ball_invoke({input})")
    }

    // ════════════════════════════════════════════════════════════
    // print / to_string
    // ════════════════════════════════════════════════════════════

    /// `print(message)` — always compiles to a `BallValue`-typed block (this
    /// crate's uniform invariant): the `println!` runs for its side effect
    /// and the block's value is `BallValue::Null`, matching every reference
    /// engine's `print` returning `null`.
    fn compile_print(&self, fields: &IndexMap<String, Expression>) -> String {
        let message = self.field_or_null(fields, "message");
        format!("{{ println!(\"{{}}\", {message}); BallValue::Null }}")
    }

    // ════════════════════════════════════════════════════════════
    // Lazy control flow
    // ════════════════════════════════════════════════════════════

    /// `if(condition, then, else?)` — lazy by construction: both branches
    /// are Rust `if`/`else` arms, so only the taken branch's compiled code
    /// ever executes (invariant #4).
    fn compile_if(&self, fields: &IndexMap<String, Expression>) -> String {
        let condition = self.field_or_null(fields, "condition");
        let then = self.field_or_null(fields, "then");
        let else_branch = self.field_or_null(fields, "else");
        format!("if ball_truthy({condition}) {{ {then} }} else {{ {else_branch} }}")
    }

    /// `and(left, right)` — native `&&`. `right`'s compiled source is the
    /// second operand of Rust's own short-circuiting `&&`, so it is never
    /// *reached* (not merely "discarded") when `left` is `false` — this is
    /// the laziness fixture's key assertion (a divide-by-zero or `print` in
    /// the untaken `right` must not execute).
    fn compile_and(&self, call: &FunctionCall) -> String {
        let f = extract_fields(call);
        let left = self.field_or_null(&f, "left");
        let right = self.field_or_null(&f, "right");
        format!("BallValue::Bool(ball_truthy({left}) && ball_truthy({right}))")
    }

    /// `or(left, right)` — native `||`, lazy for the same reason as `and`.
    fn compile_or(&self, call: &FunctionCall) -> String {
        let f = extract_fields(call);
        let left = self.field_or_null(&f, "left");
        let right = self.field_or_null(&f, "right");
        format!("BallValue::Bool(ball_truthy({left}) || ball_truthy({right}))")
    }

    /// `null_coalesce(left, right)` (`??`) — Dart's `??` doesn't evaluate
    /// `right` when `left` is non-null, so (like `and`/`or`) this is an
    /// inline `if` rather than a `ball_shared::runtime` call.
    fn compile_null_coalesce(&self, call: &FunctionCall) -> String {
        let f = extract_fields(call);
        let left = self.field_or_null(&f, "left");
        let right = self.field_or_null(&f, "right");
        format!("{{ let __l = {left}; if __l != BallValue::Null {{ __l }} else {{ {right} }} }}")
    }

    /// `for(init, condition, update, body)` — a C-style for loop. Rust has
    /// no native C-style `for`, so this needs a hand-rolled desugaring —
    /// and the *naive* one (`while cond { body; update; }`) is a real bug,
    /// not just an inelegance: Rust's `continue` jumps straight to the
    /// loop's condition re-check, so a `continue` inside `body` would skip
    /// `update` entirely — an unconditional-`continue`'d loop counter never
    /// advances, hanging forever (caught by this issue's own nested-loop
    /// fixture during development).
    ///
    /// The fix is the standard "run update-or-skip at the top of the loop,
    /// gated by a first-iteration flag" idiom, which needs **no** special
    /// handling of `break`/`continue` at all — both already do the right
    /// thing by Rust's ordinary nearest-enclosing-loop rules:
    /// ```text
    /// init;
    /// let mut first = true;
    /// loop {
    ///     if first { first = false; } else { update; }
    ///     if !cond { break; }
    ///     body;
    /// }
    /// ```
    /// A `continue` in `body` jumps to the top of this `loop` — which now
    /// *is* the update step — then falls through to the condition check,
    /// exactly matching a native C-style `for`.
    fn compile_for(&self, call: &FunctionCall, label: Option<&str>) -> String {
        let f = extract_fields(call);
        // The C-style `for` is its own lexical scope: the `init` clause's
        // loop counters are visible to `condition`/`update`/`body` and gone
        // afterward. Bind them (via `compile_for_init`) so a call/reference
        // to a counter resolves as a value (#39, gap #6).
        self.push_scope();
        let init_code = f
            .get("init")
            .map(|e| self.compile_for_init(e))
            .unwrap_or_default();
        let condition_code = match f.get("condition") {
            Some(condition) => format!("ball_truthy({})", self.compile_expression(condition)),
            None => "true".to_string(),
        };
        self.push_flow_scope(crate::FlowScope::Loop);
        let body_code = self.field_or_null(&f, "body");
        self.pop_flow_scope();
        let update_code = f
            .get("update")
            .map(|e| self.compile_expression(e))
            .unwrap_or_default();
        self.pop_scope();
        let label_prefix = label.map(|l| format!("'{l}: ")).unwrap_or_default();
        format!(
            "{{\n{init_code}let mut __ball_for_first = true;\n{label_prefix}loop {{\n\
             if __ball_for_first {{ __ball_for_first = false; }} else {{ {update_code}; }}\n\
             if !{condition_code} {{ break; }}\n{body_code};\n}}\nBallValue::Null\n}}"
        )
    }

    /// Compile a `for` loop's `init` field. The canonical shape (see
    /// `dart/shared/lib/std.dart`'s `ForInput` and the encoder convention
    /// documented in `dart/compiler/lib/compiler.dart`'s `_generateFor`) is
    /// a `block` of `let`-bindings with no result (`for (var i = 0, j = 1;
    /// ...)`); each becomes `let mut <name> = <value>;` — unconditionally
    /// `mut` (safe: `compile()`'s preamble allows `unused_mut`, and a
    /// for-loop counter is overwhelmingly likely to be mutated by
    /// `update`/`body` anyway). Any other shape (e.g. `for (i = 0; ...)`,
    /// reusing an existing variable) is compiled as a plain statement.
    fn compile_for_init(&self, init: &Expression) -> String {
        if let Some(Expr::Block(block)) = &init.expr {
            if block.result.is_none()
                && !block.statements.is_empty()
                && block.statements.iter().all(|s| {
                    matches!(
                        &s.stmt,
                        Some(ball_shared::proto::ball::v1::statement::Stmt::Let(_))
                    )
                })
            {
                let mut out = String::new();
                for statement in &block.statements {
                    if let Some(ball_shared::proto::ball::v1::statement::Stmt::Let(let_binding)) =
                        &statement.stmt
                    {
                        let name = crate::sanitize_ident(&let_binding.name);
                        let value = match &let_binding.value {
                            Some(value) => self.compile_expression(value),
                            None => "BallValue::Null".to_string(),
                        };
                        self.bind_local(&let_binding.name);
                        out.push_str(&format!("let mut {name} = {value};\n"));
                    }
                }
                return out;
            }
        }
        format!("{};\n", self.compile_expression(init))
    }

    /// `for_in(variable, iterable, body)` — iterates a `List` (or a `Map`'s
    /// entries, each surfaced as `[key, value]` — see
    /// `ball_shared::runtime::ball_iterate`) via a native Rust `for` loop.
    fn compile_for_in(&self, call: &FunctionCall, label: Option<&str>) -> String {
        let f = extract_fields(call);
        let variable = self
            .string_field(&f, "variable")
            .unwrap_or_else(|| "item".to_string());
        let var_ident = crate::sanitize_ident(&variable);
        // The iterable is evaluated in the *outer* scope (before the loop
        // variable exists); the body is a new scope with the loop variable
        // bound (so a call/reference to it resolves as a value — #39 gap #6).
        let iterable_code = self.field_or_null(&f, "iterable");
        self.push_scope();
        self.bind_local(&variable);
        self.push_flow_scope(crate::FlowScope::Loop);
        let body_code = self.field_or_null(&f, "body");
        self.pop_flow_scope();
        self.pop_scope();
        let mutated = f
            .get("body")
            .is_some_and(|body| self.expr_mutates_var(body, &variable));
        let binding = if mutated { "let mut" } else { "let" };
        let label_prefix = label.map(|l| format!("'{l}: ")).unwrap_or_default();
        format!(
            "{{\n{label_prefix}for __item in ball_iterate({iterable_code}) {{\n{binding} {var_ident} = __item;\n{body_code};\n}}\nBallValue::Null\n}}"
        )
    }

    /// `while(condition, body)`.
    fn compile_while(&self, call: &FunctionCall, label: Option<&str>) -> String {
        let f = extract_fields(call);
        let condition_code = match f.get("condition") {
            Some(condition) => format!("ball_truthy({})", self.compile_expression(condition)),
            None => "true".to_string(),
        };
        self.push_flow_scope(crate::FlowScope::Loop);
        let body_code = self.field_or_null(&f, "body");
        self.pop_flow_scope();
        let label_prefix = label.map(|l| format!("'{l}: ")).unwrap_or_default();
        format!(
            "{{\n{label_prefix}while {condition_code} {{\n{body_code};\n}}\nBallValue::Null\n}}"
        )
    }

    /// `do_while(body, condition)` — runs `body` once unconditionally, then
    /// repeats while `condition` holds, matching Dart's `do { ... } while
    /// (...)`.
    ///
    /// The naive `loop { body; if !cond { break; } }` has the same
    /// `continue`-skips-a-step bug as the naive `for` desugaring (see
    /// [`Compiler::compile_for`]'s doc comment): a `continue` inside `body`
    /// jumps to the top of that `loop`, which is `body` itself — so it
    /// would *re-run `body` immediately*, skipping the condition check
    /// entirely, rather than "proceed to the next real iteration". The
    /// fix is the same first-iteration-flag idiom, just with the roles
    /// reversed (body runs unconditionally on the first pass; the
    /// condition gates every pass after):
    /// ```text
    /// let mut first = true;
    /// loop {
    ///     if first { first = false; } else if !cond { break; }
    ///     body;
    /// }
    /// ```
    /// A `continue` in `body` now jumps to the top — which checks `cond`
    /// (since `first` is `false` after the first pass) before deciding
    /// whether to run `body` again, exactly matching a native do-while.
    fn compile_do_while(&self, call: &FunctionCall, label: Option<&str>) -> String {
        let f = extract_fields(call);
        self.push_flow_scope(crate::FlowScope::Loop);
        let body_code = self.field_or_null(&f, "body");
        self.pop_flow_scope();
        let condition_code = match f.get("condition") {
            Some(condition) => format!("ball_truthy({})", self.compile_expression(condition)),
            None => "true".to_string(),
        };
        let label_prefix = label.map(|l| format!("'{l}: ")).unwrap_or_default();
        format!(
            "{{\nlet mut __ball_do_while_first = true;\n{label_prefix}loop {{\n\
             if __ball_do_while_first {{ __ball_do_while_first = false; }} else if !{condition_code} {{ break; }}\n\
             {body_code};\n}}\nBallValue::Null\n}}"
        )
    }

    /// `label(name, body)` — attaches a Rust loop label directly to `body`
    /// when `body` is itself one of the four loop calls (the common,
    /// directly-nested case: `label('outer', for(...))`), so
    /// `break('outer')`/`continue('outer')` compile to real
    /// `break 'outer`/`continue 'outer`. Any other `body` shape falls back
    /// to a bare labeled block (`'name: { body }`), which supports labeled
    /// `break` (Rust block labels can be `break`-targeted) but not labeled
    /// `continue` (blocks aren't loops) — a `continue` targeting a
    /// non-loop-wrapping label is a malformed program in every reference
    /// engine too.
    fn compile_label(&self, call: &FunctionCall) -> String {
        let f = extract_fields(call);
        let label = sanitize_label(&self.string_field(&f, "name").unwrap_or_default());
        match f.get("body").map(|e| &e.expr) {
            Some(Some(Expr::Call(inner))) if self.is_base_module(&inner.module) => {
                match inner.function.as_str() {
                    "for" => return self.compile_for(inner, Some(&label)),
                    "for_in" => return self.compile_for_in(inner, Some(&label)),
                    "while" => return self.compile_while(inner, Some(&label)),
                    "do_while" => return self.compile_do_while(inner, Some(&label)),
                    _ => {}
                }
            }
            _ => {}
        }
        let body_code = self.field_or_null(&f, "body");
        format!("'{label}: {{\n{body_code}\n}}")
    }

    // ════════════════════════════════════════════════════════════
    // Flow signals
    // ════════════════════════════════════════════════════════════

    /// `return(value)` — a real Rust `return`. `return`'s type is `!`
    /// (diverging), which unifies with whatever type the surrounding
    /// expression position expects, so it's always valid here regardless of
    /// context (block statement, `if` arm, ...).
    fn compile_return(&self, fields: &IndexMap<String, Expression>) -> String {
        let value = self.field_or_null(fields, "value");
        if self.return_needs_flow() {
            // Inside a `try` body — escape the `catch_unwind` closure via
            // `BallFlow` so the value survives to a real function return after
            // `finally` (issue #300).
            format!("return BallFlow::Return({value})")
        } else {
            format!("return {value}")
        }
    }

    /// `break([label])` — unlabeled breaks the innermost enclosing Rust
    /// loop (matches "break the innermost loop" for ordinary nested
    /// for/while loops); a non-empty label targets the matching loop label
    /// (see [`Compiler::compile_label`]).
    fn compile_break(&self, fields: &IndexMap<String, Expression>) -> String {
        let label = self.string_field(fields, "label").filter(|l| !l.is_empty());
        if self.break_needs_flow() {
            // The nearest enclosing scope is a `try`: escape it via `BallFlow`
            // (issue #300). The label is carried but the `try` re-issues a bare
            // `break` (labeled `break` *through* a `try` to an outer loop is the
            // documented boundary).
            match label {
                Some(label) => {
                    format!(
                        "return BallFlow::Break(Some({:?}.to_string()))",
                        sanitize_label(&label)
                    )
                }
                None => "return BallFlow::Break(None)".to_string(),
            }
        } else {
            match label {
                Some(label) => format!("break '{}", sanitize_label(&label)),
                None => "break".to_string(),
            }
        }
    }

    fn compile_continue(&self, fields: &IndexMap<String, Expression>) -> String {
        let label = self.string_field(fields, "label").filter(|l| !l.is_empty());
        if self.break_needs_flow() {
            match label {
                Some(label) => format!(
                    "return BallFlow::Continue(Some({:?}.to_string()))",
                    sanitize_label(&label)
                ),
                None => "return BallFlow::Continue(None)".to_string(),
            }
        } else {
            match label {
                Some(label) => format!("continue '{}", sanitize_label(&label)),
                None => "continue".to_string(),
            }
        }
    }

    /// `assert(condition, message?)` — a debug assertion; panics
    /// (unconditionally, matching every reference engine's `assert` running
    /// in "checked mode" — Ball has no separate release-mode assert-elision
    /// story yet) when `condition` is falsy.
    fn compile_assert(&self, fields: &IndexMap<String, Expression>) -> String {
        let condition = self.field_or_null(fields, "condition");
        let panic_stmt = match fields.get("message") {
            Some(message) => format!("panic!(\"{{}}\", {});", self.compile_expression(message)),
            None => "panic!(\"Assertion failed\");".to_string(),
        };
        format!("{{ if !ball_truthy({condition}) {{ {panic_stmt} }} BallValue::Null }}")
    }

    // ════════════════════════════════════════════════════════════
    // try / switch
    // ════════════════════════════════════════════════════════════

    /// `try(body, catches, finally?)` — wraps `body` in
    /// `std::panic::catch_unwind`; `throw` (see
    /// `ball_shared::runtime::ball_throw`) panics with the thrown
    /// `BallValue` as the panic payload via `std::panic::panic_any`, which
    /// `ball_catch_payload` recovers on the catching side.
    ///
    /// **Known limitation:** only the *first* `catches` clause is compiled
    /// (bound as a catch-all, ignoring `CatchClause.type` — real
    /// exception-type dispatch needs the class hierarchy #38 adds); multiple
    /// typed catch clauses are a documented gap, not a silent one. An
    /// uncaught exception (no `catches` at all) re-panics with the
    /// recovered value's `Debug` text.
    fn compile_try(&self, call: &FunctionCall) -> String {
        let f = extract_fields(call);
        // The body runs inside the `catch_unwind` closure (to catch Ball
        // `throw`s), so its `return`/`break`/`continue` escape as `BallFlow`
        // (issue #300) — the fix for the engine's pervasive `try { … return X }
        // finally { … }` (a bare Rust `return` would only leave the closure,
        // losing the value).
        self.push_flow_scope(crate::FlowScope::Try);
        let body_code = self.field_or_null(&f, "body");
        self.pop_flow_scope();

        // `finally` runs on *every* exit — normal fall-through, a `BallFlow`
        // exit, and a caught throw — so it is emitted before each propagation.
        let finally_snippet = f
            .get("finally")
            .map(|e| format!("{};\n", self.compile_expression(e)))
            .unwrap_or_default();
        let catches = f
            .get("catches")
            .map(literal_list_elements)
            .unwrap_or_default();
        // Re-issue this `try`'s `BallFlow` result as real control flow, matching
        // the *enclosing* scope (this try's own scope is already popped).
        let propagate = self.flow_propagation();

        let mut out = String::from(
            "{\nlet __try_outcome: Result<BallFlow, Box<dyn std::any::Any + Send>> = \
             std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {\nBallFlow::Normal(",
        );
        out.push_str(&body_code);
        out.push_str(")\n}));\nmatch __try_outcome {\n");
        out.push_str(&format!(
            "Ok(__flow) => {{\n{finally_snippet}{propagate}\n}}\n"
        ));
        out.push_str("Err(__payload) => {\n");

        if let Some(first_catch) = catches.first() {
            let cf = match &first_catch.expr {
                Some(Expr::MessageCreation(mc)) => self.message_creation_fields(mc),
                _ => IndexMap::new(),
            };
            let var_name = self
                .string_field(&cf, "variable")
                .unwrap_or_else(|| "_ball_err".to_string());
            // A `catch (e, st)` clause names a second variable in `stack_trace`
            // (`dart/encoder/lib/encoder.dart`'s `_encodeCatchClause`); the
            // handler body reads it as a bare `st` reference. The by-value Rust
            // model captures no real trace, so it binds the caught error's
            // string form — the closest faithful value.
            let stack_var = self
                .string_field(&cf, "stack_trace")
                .filter(|s| !s.is_empty());
            // The catch handler runs *outside* the `catch_unwind` closure (in
            // this match arm), so its own `return`/`break`/`continue` reflect the
            // enclosing scope directly — compile it with this try's scope popped.
            self.push_scope();
            self.bind_local(&var_name);
            if let Some(stack_var) = &stack_var {
                self.bind_local(stack_var);
            }
            // Compile the handler with a catch in scope so a `std.rethrow`
            // (Dart `rethrow`) re-raises `_ball_rethrow_err` (issue #39/#300).
            self.enter_catch();
            let catch_body = cf
                .get("body")
                .map(|b| self.compile_expression(b))
                .unwrap_or_else(|| "BallValue::Null".to_string());
            self.exit_catch();
            self.pop_scope();
            out.push_str("let __err = ball_catch_payload(__payload);\n");
            // Stable rethrow target: `rethrow` re-raises the *originally caught*
            // exception even if the handler reassigns its `catch (e)` variable,
            // so bind it before `__err` is moved into `var_name`. The leading
            // underscore keeps it warning-free when the handler never rethrows.
            out.push_str("let _ball_rethrow_err = __err.clone();\n");
            // Bind the stack-trace variable first (it reads `__err` by clone)
            // so the exception binding can then move `__err` into `var_name`.
            if let Some(stack_var) = &stack_var {
                out.push_str(&format!(
                    "let {} = ball_to_string(__err.clone());\n",
                    crate::sanitize_ident(stack_var)
                ));
            }
            out.push_str(&format!(
                "let {} = __err;\n",
                crate::sanitize_ident(&var_name)
            ));
            out.push_str(&format!(
                "let __flow = BallFlow::Normal({{\n{catch_body}\n}});\n{finally_snippet}{propagate}\n"
            ));
        } else {
            // No `catch`: run `finally`, then re-raise the original panic
            // (preserving the thrown Ball value so an *outer* `try` catches it).
            out.push_str(&format!(
                "{finally_snippet}std::panic::resume_unwind(__payload)\n"
            ));
        }
        out.push_str("}\n}\n}");
        out
    }

    /// `std.rethrow` (the Dart `rethrow` keyword) — re-raise the exception the
    /// innermost enclosing `catch` is handling. [`Compiler::compile_try`] binds
    /// that as `_ball_rethrow_err` (the originally-caught value, stable against
    /// the handler reassigning its `catch (e)` variable) and marks the handler
    /// via [`Compiler::enter_catch`], so a `rethrow` here re-panics with it (the
    /// same `ball_throw` an outer `try` catches). A `rethrow` with no enclosing
    /// catch mirrors the reference engine's `rethrow outside of catch` error
    /// (only reachable in a malformed program). Issue #39/#300.
    fn compile_rethrow(&self) -> String {
        if self.in_catch() {
            "ball_throw(_ball_rethrow_err.clone())".to_string()
        } else {
            "ball_throw(BallValue::String(\"rethrow outside of catch\".to_string()))".to_string()
        }
    }

    /// The `match __flow { … }` that re-issues a `try`'s [`ball_shared::runtime::BallFlow`]
    /// result as real control flow, matching the **enclosing** scope (the
    /// try's own scope must already be popped): a bare Rust keyword under a
    /// loop, a fresh `BallFlow` under an outer `try`, and — for a `break`/
    /// `continue` that reached a `try` with no enclosing loop (a malformed
    /// program) — an `unreachable!` guard that still type-checks. Issue #300.
    fn flow_propagation(&self) -> String {
        let (ret, brk, cont) = match self.innermost_flow_scope() {
            Some(crate::FlowScope::Try) => (
                "return BallFlow::Return(__x)",
                "return BallFlow::Break(__l)",
                "return BallFlow::Continue(__l)",
            ),
            Some(crate::FlowScope::Loop) => ("return __x", "break", "continue"),
            None => (
                "return __x",
                "unreachable!(\"break escaped a try with no enclosing loop\")",
                "unreachable!(\"continue escaped a try with no enclosing loop\")",
            ),
        };
        format!(
            "match __flow {{\n\
             BallFlow::Normal(__v) => __v,\n\
             BallFlow::Return(__x) => {ret},\n\
             BallFlow::Break(__l) => {brk},\n\
             BallFlow::Continue(__l) => {cont},\n\
             }}"
        )
    }

    /// `switch(subject, cases[])` — compiles to an **if-chain** (each case
    /// value compared to `subject` via `ball_equals`), not a native Rust
    /// `match`: case values are arbitrary compiled expressions (not
    /// necessarily `match`-pattern-legal literals), matching the issue's own
    /// "`match`/`if`-chain" phrasing.
    ///
    /// **Fall-through:** Dart's label fall-through (`case A: case B: body;`)
    /// encodes as consecutive cases where the leading ones carry *no* body
    /// (or an empty body) and the last carries the shared body — exactly what
    /// the reference Dart compiler's `_generateSwitch` relies on Dart's native
    /// `switch` to handle. Because this target lowers to an `if`-chain rather
    /// than a native `match`, fall-through is realized explicitly: body-less
    /// cases *accumulate* their match values into the next case that has a real
    /// body (`case 'post_increment': case 'pre_increment': … case
    /// 'pre_decrement': return _evalIncDec(…)` → one arm matching any of the
    /// four). Without this, a body-less fall-through case compiled to an empty
    /// `BallValue::Null` arm and the shared body was reached only for the *last*
    /// label — which silently no-op'd `i++`/`i--` (the engine routes three of
    /// the four increment/decrement functions through such a fall-through),
    /// wedging every `for`/`while` loop in an infinite spin.
    ///
    /// **Known limitation:** `break` inside a case body is not specially scoped
    /// to "exit the switch" — Rust's `break`/`continue` only make sense inside a
    /// real loop, and this if-chain isn't one. Not exercised by the corpus (the
    /// engine's switches all `return`/fall through, never bare-`break`).
    fn compile_switch(&self, call: &FunctionCall) -> String {
        let f = extract_fields(call);
        let subject_code = self.field_or_null(&f, "subject");
        let cases = f
            .get("cases")
            .map(literal_list_elements)
            .unwrap_or_default();

        let mut arms: Vec<(Vec<String>, String)> = Vec::new();
        let mut default_body: Option<String> = None;
        // Match values of body-less (fall-through) cases, carried forward until
        // the next case that supplies a real body absorbs them.
        let mut pending_values: Vec<String> = Vec::new();
        for case in &cases {
            let Some(Expr::MessageCreation(mc)) = &case.expr else {
                continue;
            };
            let cf = self.message_creation_fields(mc);
            let is_default = self.bool_field(&cf, "is_default");
            // A case "has a body" only if `body` is present AND not an empty
            // block/`notSet` literal — mirroring the Dart compiler's
            // `_isEmptyBody` fall-through test. A missing/empty body means this
            // label falls through to the next.
            let real_body = cf
                .get("body")
                .filter(|b| !is_empty_switch_body(b))
                .map(|b| self.compile_expression(b));

            if !is_default {
                pending_values.extend(self.switch_case_match_values(&cf));
            }

            let Some(body_code) = real_body else {
                // Fall-through: keep accumulating (non-default) match values;
                // a body-less `default` contributes nothing on its own.
                continue;
            };

            if is_default {
                default_body = Some(body_code);
                // Any values that fell through *into* this default are already
                // covered by the trailing `else` (default) arm, so drop them.
                pending_values.clear();
            } else {
                let values = std::mem::take(&mut pending_values);
                if !values.is_empty() {
                    arms.push((values, body_code));
                }
            }
        }

        let mut out = String::from("{\nlet __switch_subject = ");
        out.push_str(&subject_code);
        out.push_str(";\n");
        if arms.is_empty() {
            out.push_str(default_body.as_deref().unwrap_or("BallValue::Null"));
        } else {
            for (index, (values, body_code)) in arms.iter().enumerate() {
                if index > 0 {
                    out.push_str(" else ");
                }
                // A case matches if the subject equals **any** of its values
                // (a `LogicalOrPattern` — `case 'a' || 'b':` — contributes
                // several; a plain value contributes one).
                let condition = values
                    .iter()
                    .map(|value_code| {
                        format!(
                            "ball_equals(__switch_subject.clone(), {value_code}) == BallValue::Bool(true)"
                        )
                    })
                    .collect::<Vec<_>>()
                    .join(" || ");
                out.push_str(&format!("if {condition} {{\n{body_code}\n}}"));
            }
            out.push_str(&format!(
                " else {{\n{}\n}}",
                default_body.as_deref().unwrap_or("BallValue::Null")
            ));
        }
        out.push_str("\n}");
        out
    }

    /// A `SwitchCase`'s comparison expression: prefer the plain `value`
    /// field (the simple equality-switch shape most #37 fixtures use);
    /// fall back to the *semantic* `pattern_expr` (Dart 3 pattern-matching
    /// switches — e.g. `case Color.red:` on an enum encodes as
    /// `pattern_expr: ConstPattern { value: <fieldAccess Color.red> }`, with
    /// the case's own `pattern` field carrying only a cosmetic source-text
    /// string). Mirrors `dart/compiler/lib/compiler.dart`'s
    /// `_generateSwitchCase`, which prefers `pattern_expr` over the cosmetic
    /// `pattern` the same way. Only the `ConstPattern` kind is recognized —
    /// other structured-pattern kinds (destructuring/type patterns) fall
    /// through to `None` (the case is skipped), the same documented-gap
    /// shape as this function's own doc comment.
    /// The compiled value(s) a switch case matches — usually one (a plain
    /// `value`, or a `ConstPattern`), but **several** for a `LogicalOrPattern`
    /// (`case 'std' || 'std_collections' || …:`, which the engine's
    /// `StdModuleHandler.handles`/`_callBaseFunction` use). A `LogicalOrPattern`
    /// is a (possibly nested) `{left, right}` tree of `ConstPattern` leaves;
    /// this flattens it to the full set of constant alternatives. An
    /// unrecognized structured pattern yields no values (the case is skipped —
    /// the documented gap).
    fn switch_case_match_values(&self, cf: &IndexMap<String, Expression>) -> Vec<String> {
        if let Some(value) = cf.get("value") {
            return vec![self.compile_expression(value)];
        }
        match cf.get("pattern_expr") {
            Some(pattern_expr) => self.pattern_match_values(pattern_expr),
            None => Vec::new(),
        }
    }

    /// Flatten a `pattern_expr` to the constant value expression(s) it matches:
    /// a `ConstPattern`'s own `value`, or the union of a `LogicalOrPattern`'s
    /// `left`/`right` sub-patterns (recursively). Any other pattern kind
    /// contributes nothing.
    fn pattern_match_values(&self, pattern_expr: &Expression) -> Vec<String> {
        let Some(Expr::MessageCreation(mc)) = &pattern_expr.expr else {
            return Vec::new();
        };
        match mc.type_name.as_str() {
            "ConstPattern" => {
                let pf = self.message_creation_fields(mc);
                pf.get("value")
                    .map(|v| vec![self.compile_expression(v)])
                    .unwrap_or_default()
            }
            "LogicalOrPattern" => {
                let pf = self.message_creation_fields(mc);
                let mut values = Vec::new();
                if let Some(left) = pf.get("left") {
                    values.extend(self.pattern_match_values(left));
                }
                if let Some(right) = pf.get("right") {
                    values.extend(self.pattern_match_values(right));
                }
                values
            }
            _ => Vec::new(),
        }
    }

    /// Extract a `MessageCreation`'s fields directly (used by
    /// `switch`/`try` to read each case/catch-clause struct — these appear
    /// as list *elements*, not a `FunctionCall`'s own input, so
    /// `ball_shared::extract_fields` — which takes a `&FunctionCall` — can't
    /// be reused directly).
    fn message_creation_fields(&self, mc: &MessageCreation) -> IndexMap<String, Expression> {
        mc.fields
            .iter()
            .map(|field| (field.name.clone(), field.value.clone().unwrap_or_default()))
            .collect()
    }

    // ════════════════════════════════════════════════════════════
    // Type operations
    // ════════════════════════════════════════════════════════════

    fn compile_type_op(&self, helper: &str, fields: &IndexMap<String, Expression>) -> String {
        let value = self.field_or_null(fields, "value");
        let type_name = self.string_field(fields, "type").unwrap_or_default();
        format!("{helper}({value}, {type_name:?})")
    }

    // ════════════════════════════════════════════════════════════
    // Indexing
    // ════════════════════════════════════════════════════════════

    fn compile_index(&self, fields: &IndexMap<String, Expression>) -> String {
        format!(
            "ball_index_get({}, {})",
            self.field_or_null(fields, "target"),
            self.field_or_null(fields, "index")
        )
    }

    fn compile_index_named(&self, helper: &str, fields: &IndexMap<String, Expression>) -> String {
        format!(
            "{helper}({}, {})",
            self.field_or_null(fields, "target"),
            self.field_or_null(fields, "index")
        )
    }

    // ════════════════════════════════════════════════════════════
    // Assignment / mutation — see `crate::lvalue`
    // ════════════════════════════════════════════════════════════

    /// `assign(target, value, op?)`. `op` defaults to `"="` (simple
    /// assignment) when absent.
    fn compile_assign(&self, call: &FunctionCall) -> String {
        let f = extract_fields(call);
        let Some(target) = f.get("target") else {
            return "ball_unsupported_base_call(\"std\", \"assign\")".to_string();
        };
        let value_code = self.field_or_null(&f, "value");
        let op = self
            .string_field(&f, "op")
            .unwrap_or_else(|| "=".to_string());
        let lvalue = self.resolve_lvalue(target);
        let mutation = self.emit_mutation(&lvalue, &op, &value_code, false);
        // A **null-aware index** assignment (`obj?[k] = v` — the engine's
        // `_callCounts?[func] = …` profiling counter) must skip the entire
        // assignment, RHS included, when `obj` is null (issue #300). Guard it on
        // the base's non-nullness; a plain index/field/var assign is unchanged.
        if let Some(Expr::Call(target_call)) = &target.expr {
            if target_call.function == "null_aware_index"
                && self.is_base_module(&target_call.module)
            {
                let tf = extract_fields(target_call);
                let base_code = self.field_or_null(&tf, "target");
                return format!(
                    "{{ if {base_code} != BallValue::Null {{ {mutation} }} else {{ BallValue::Null }} }}"
                );
            }
        }
        mutation
    }

    /// `pre_increment`/`post_increment`/`pre_decrement`/`post_decrement` —
    /// all four are "mutate the target by 1" with a compound op (`+=`/`-=`)
    /// and a choice of which value the expression evaluates to (`want_old`
    /// distinguishes post- from pre-).
    fn compile_mutate_by_one(&self, call: &FunctionCall, op: &str, want_old: bool) -> String {
        let f = extract_fields(call);
        let Some(target) = f.get("value") else {
            return "ball_unsupported_base_call(\"std\", \"increment\")".to_string();
        };
        let lvalue = self.resolve_lvalue(target);
        self.emit_mutation(&lvalue, op, "BallValue::Int(1)", want_old)
    }

    // ════════════════════════════════════════════════════════════
    // std_collections
    // ════════════════════════════════════════════════════════════

    fn compile_collections_call(&self, call: &FunctionCall) -> String {
        // Mutating calls need the collection field's *lvalue* (a `&mut`
        // slot onto the caller's own binding), not a `.clone()`d read — see
        // `crate::lvalue`'s module doc comment.
        let mutating_field = match call.function.as_str() {
            "list_push" | "list_pop" | "list_insert" | "list_remove_at" | "list_set"
            | "list_clear" | "list_sort" => Some("list"),
            "map_set" | "map_delete" | "map_put_if_absent" => Some("map"),
            "set_add" | "set_remove" => Some("set"),
            _ => None,
        };
        if let Some(field_name) = mutating_field {
            return self.compile_mutating_collection_call(call, field_name);
        }

        let f = extract_fields(call);
        match call.function.as_str() {
            "list_get" => self.compile_2("ball_list_get", &f, "list", "index"),
            "list_length" => self.un("ball_list_length", &f),
            "list_is_empty" => self.un("ball_list_is_empty", &f),
            "list_first" => self.un("ball_list_first", &f),
            "list_last" => self.un("ball_list_last", &f),
            "list_single" => self.un("ball_list_single", &f),
            "list_contains" => self.compile_2("ball_list_contains", &f, "list", "value"),
            "list_index_of" => self.compile_2("ball_list_index_of", &f, "list", "value"),
            "list_map" => self.callback_call("ball_list_map", &f, "list"),
            "list_filter" => self.callback_call("ball_list_filter", &f, "list"),
            "list_find" => self.callback_call("ball_list_find", &f, "list"),
            "list_any" => self.callback_call("ball_list_any", &f, "list"),
            "list_all" => self.callback_call("ball_list_all", &f, "list"),
            "list_none" => self.callback_call("ball_list_none", &f, "list"),
            "list_reverse" => self.un("ball_list_reverse", &f),
            "list_slice" => self.tri("ball_list_slice", &f, "list", "start", "end"),
            "list_flat_map" => self.callback_call("ball_list_flat_map", &f, "list"),
            "list_take" => self.compile_2("ball_list_take", &f, "list", "value"),
            "list_drop" => self.compile_2("ball_list_drop", &f, "list", "value"),
            "list_concat" => self.compile_2("ball_list_concat", &f, "list", "value"),
            "list_to_list" => self.un_named("ball_list_to_list", &f, "list"),
            "list_join" => self.compile_2("ball_list_join", &f, "list", "separator"),
            "map_get" => self.compile_2("ball_map_get", &f, "map", "key"),
            "map_contains_key" => self.compile_2("ball_map_contains_key", &f, "map", "key"),
            "map_contains_value" => self.compile_2("ball_map_contains_value", &f, "map", "value"),
            "map_keys" => self.un_named("ball_map_keys", &f, "map"),
            "map_values" => self.un_named("ball_map_values", &f, "map"),
            "map_entries" => self.un_named("ball_map_entries", &f, "map"),
            "map_from_entries" => self.un_named("ball_map_from_entries", &f, "list"),
            "map_merge" => self.bin("ball_map_merge", &f),
            "map_is_empty" => self.un_named("ball_map_is_empty", &f, "map"),
            "map_length" => self.un_named("ball_map_length", &f, "map"),
            "string_join" => self.compile_2("ball_string_join", &f, "list", "separator"),
            "set_create" => self.un_named("ball_set_create", &f, "list"),
            "set_contains" => self.compile_2("ball_set_contains", &f, "set", "value"),
            "set_union" => self.bin("ball_set_union", &f),
            "set_intersection" => self.bin("ball_set_intersection", &f),
            "set_difference" => self.bin("ball_set_difference", &f),
            "set_length" => self.un_named("ball_set_length", &f, "set"),
            "set_is_empty" => self.un_named("ball_set_is_empty", &f, "set"),
            "set_to_list" => self.un_named("ball_set_to_list", &f, "set"),
            // Deferred — genuinely multi-parameter callbacks
            // (accumulator+element / key-extractor+element), which Ball's
            // single-`input` lambda convention can't express until #38.
            "list_reduce" | "list_sort_by" | "list_zip" | "map_map" | "map_filter" => {
                self.unsupported(call)
            }
            _ => self.unsupported(call),
        }
    }

    fn un_named(&self, helper: &str, fields: &IndexMap<String, Expression>, key: &str) -> String {
        format!("{helper}({})", self.field_or_null(fields, key))
    }

    /// A collection call whose single non-collection argument is a
    /// (single-`input`) callback — `list_map(list, callback)`, etc. The
    /// callback's compiled source (a Rust closure literal or a
    /// `.clone()`d closure/fn-item reference) satisfies
    /// `ball_shared::runtime`'s generic `F: Fn(BallValue) -> BallValue`
    /// bound directly, no boxing needed.
    fn callback_call(
        &self,
        helper: &str,
        fields: &IndexMap<String, Expression>,
        collection_key: &str,
    ) -> String {
        let collection = self.field_or_null(fields, collection_key);
        // The encoder packs a collection callback under `value` (`list.where((v)
        // => …)` → `list_filter{list, value: <lambda>}`); older/hand-authored
        // fixtures used `callback`/`function`. Prefer the real one.
        let callback = fields
            .get("value")
            .or_else(|| fields.get("callback"))
            .or_else(|| fields.get("function"))
            .map(|expr| self.compile_expression(expr))
            .unwrap_or_else(|| "BallValue::Null".to_string());
        format!("{helper}({collection}, {callback})")
    }

    /// Mutating `std_collections` calls (`list_push`, `map_set`, ...):
    /// resolve `field_name`'s value to an [`crate::lvalue::LValue`] and pass
    /// a `&mut BallValue` slot onto it as the first argument, so the helper
    /// mutates the caller's actual binding rather than a throwaway clone.
    fn compile_mutating_collection_call(&self, call: &FunctionCall, field_name: &str) -> String {
        let f = extract_fields(call);
        let Some(target) = f.get(field_name) else {
            return self.unsupported(call);
        };
        let lvalue = self.resolve_lvalue(target);
        // A collection stored in a **message field** (`list_push(obj.field, x)`)
        // or a **list/map element** (`list_push(matrix[i], x)`) can't hand out a
        // `&mut` slot — a reference-semantic `BallValue::Message`/`BallValue::List`
        // keeps its backing behind an `Arc<Mutex>` (issues #298/#39/#300). Read
        // the collection out into an owned `__coll`, mutate it through the
        // ordinary `&mut __coll` slot, then write it back (`ball_field_set` /
        // `ball_index_set`). For a *list* `__coll` the write-back is redundant
        // (its shared backing is already mutated in place), but a value-semantic
        // *map*/*set* `__coll` needs it — so this one path is correct for both,
        // without the compiler having to know the runtime kind. A plain-variable
        // target (`LValue::Var`) still passes the operation through unchanged on
        // a direct `(&mut var)` slot.
        enum Wrapped {
            Direct,
            Field(String, String),
            Index(String, String),
        }
        let wrapped = match &lvalue {
            crate::lvalue::LValue::Field { object_var, field } => {
                Wrapped::Field(object_var.clone(), field.clone())
            }
            crate::lvalue::LValue::Index {
                target_var,
                index_code,
            } => Wrapped::Index(target_var.clone(), index_code.clone()),
            _ => Wrapped::Direct,
        };
        let slot = match &wrapped {
            Wrapped::Direct => self.lvalue_mut_expr(&lvalue),
            _ => "(&mut __coll)".to_string(),
        };
        let wrap = |op: String| -> String {
            match &wrapped {
                Wrapped::Direct => op,
                Wrapped::Field(object_var, field) => format!(
                    "{{ let mut __coll = ball_field_get({object_var}.clone(), {field:?}); \
                     let __r = {op}; ball_field_set(&mut {object_var}, {field:?}, __coll); __r }}"
                ),
                Wrapped::Index(target_var, index_code) => format!(
                    "{{ let __ci = {index_code}; \
                     let mut __coll = ball_index_get({target_var}.clone(), __ci.clone()); \
                     let __r = {op}; ball_index_set(&mut {target_var}, __ci, __coll); __r }}"
                ),
            }
        };
        let extra_args: Vec<String> = match call.function.as_str() {
            "list_push" => vec![self.field_or_null(&f, "value")],
            "list_pop" => vec![],
            "list_insert" => vec![
                self.field_or_null(&f, "index"),
                self.field_or_null(&f, "value"),
            ],
            "list_remove_at" => vec![self.field_or_null(&f, "index")],
            "list_set" => vec![
                self.field_or_null(&f, "index"),
                self.field_or_null(&f, "value"),
            ],
            "map_set" => vec![
                self.field_or_null(&f, "key"),
                self.field_or_null(&f, "value"),
            ],
            "map_delete" => vec![self.field_or_null(&f, "key")],
            "map_put_if_absent" => vec![
                self.field_or_null(&f, "key"),
                self.field_or_null(&f, "value"),
            ],
            "set_add" => vec![self.field_or_null(&f, "value")],
            "set_remove" => vec![self.field_or_null(&f, "value")],
            "list_clear" => vec![],
            "list_sort" => vec![self.field_or_null(&f, "value")],
            _ => return self.unsupported(call),
        };
        let helper = match call.function.as_str() {
            "list_push" => "ball_list_push",
            "list_pop" => "ball_list_pop",
            "list_insert" => "ball_list_insert",
            "list_remove_at" => "ball_list_remove_at",
            "list_set" => {
                // `list[index] = value` isn't its own runtime helper — it's
                // the same "slot then write" shape `assign` uses, with the list
                // *itself* (not one element) resolved as the lvalue and the
                // element write done through `ball_index_set` (the list's
                // `Arc<Mutex>` backing has no `&mut` into an element — #39/#300).
                let index_code = &extra_args[0];
                let value_code = &extra_args[1];
                return wrap(format!(
                    "{{ let __v = {value_code}; ball_index_set({slot}, {index_code}, __v.clone()); __v }}"
                ));
            }
            "map_set" => "ball_map_set",
            "map_delete" => "ball_map_delete",
            "map_put_if_absent" => "ball_map_put_if_absent",
            "set_add" => "ball_set_add",
            "set_remove" => "ball_set_remove",
            "list_clear" => "ball_list_clear",
            "list_sort" => "ball_list_sort",
            _ => return self.unsupported(call),
        };
        let args = extra_args.join(", ");
        if args.is_empty() {
            wrap(format!("{helper}({slot})"))
        } else {
            wrap(format!("{helper}({slot}, {args})"))
        }
    }

    // ════════════════════════════════════════════════════════════
    // std_io
    // ════════════════════════════════════════════════════════════

    fn compile_io_call(&self, call: &FunctionCall) -> String {
        let f = extract_fields(call);
        match call.function.as_str() {
            "print_error" => self.un_named("ball_print_error", &f, "message"),
            "read_line" => "ball_read_line()".to_string(),
            "exit" => format!("ball_exit({})", self.field_or_null(&f, "code")),
            "panic" => format!("ball_panic({})", self.field_or_null(&f, "message")),
            "sleep_ms" => self.un_named("ball_sleep_ms", &f, "milliseconds"),
            "timestamp_ms" => "ball_timestamp_ms()".to_string(),
            "random_int" => self.compile_2("ball_random_int", &f, "min", "max"),
            "random_double" => "ball_random_double()".to_string(),
            "env_get" => self.un_named("ball_env_get", &f, "name"),
            "args_get" => "ball_args_get()".to_string(),
            _ => self.unsupported(call),
        }
    }
}

/// Lowercase the first character of a camelCase name — turns a `has<Field>`
/// presence-check function name's suffix (`Body`, `StringValue`, `Metadata`)
/// into its proto `jsonName` field (`body`, `stringValue`, `metadata`).
fn lower_first(name: &str) -> String {
    let mut chars = name.chars();
    match chars.next() {
        Some(first) => first.to_lowercase().chain(chars).collect(),
        None => String::new(),
    }
}

/// Turn a Ball label/loop-label name into a valid Rust lifetime-style loop
/// label (`'name`). Reuses [`crate::sanitize_ident`] for the identifier part.
fn sanitize_label(name: &str) -> String {
    if name.is_empty() {
        "ball_label".to_string()
    } else {
        crate::sanitize_ident(name)
    }
}

/// `SwitchInput.cases` / `TryInput.catches` are `repeated Expression`
/// descriptor fields, but the actual value carried in a `MessageCreation`
/// argument is a single `Expression` whose `literal.list_value.elements` is
/// the real list (mirrors `dart/compiler/lib/compiler.dart`'s
/// `_generateSwitch`, which reads `cases.literal.listValue.elements` the
/// same way). Any other shape (field absent, or present but not a list
/// literal) yields no elements.
fn literal_list_elements(expr: &Expression) -> Vec<Expression> {
    match &expr.expr {
        Some(Expr::Literal(literal)) => match &literal.value {
            Some(LiteralValue::ListValue(list)) => list.elements.clone(),
            _ => Vec::new(),
        },
        _ => Vec::new(),
    }
}

/// Whether a switch case's `body` expression is "empty" — an empty block (no
/// statements, no result) or a `notSet` literal — the signal (alongside an
/// absent `body`) that the case falls through to the next label's body. Mirrors
/// the reference Dart compiler's `_isEmptyBody`.
fn is_empty_switch_body(expr: &Expression) -> bool {
    match &expr.expr {
        Some(Expr::Block(block)) => block.statements.is_empty() && block.result.is_none(),
        Some(Expr::Literal(literal)) => literal.value.is_none(),
        _ => false,
    }
}
