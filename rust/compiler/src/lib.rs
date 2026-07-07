//! `ball-compiler` — compiles a Ball `Program` protobuf into Rust source.
//!
//! Phase 2a (issue #36) implements **expression-tree compilation**: a
//! recursive `compile_expression` that lowers every one of the seven Ball
//! `Expression` variants (`call`, `literal`, `reference`, `field_access`,
//! `message_creation`, `block`, `lambda` — see `proto/ball/v1/ball.proto`)
//! into Rust source, plus the per-function wrapper (`fn name(input:
//! BallValue) -> BallValue { ... }`, matching invariant #1 — one input, one
//! output). It mirrors the structure of the reference compilers:
//! `dart/compiler/lib/compiler.dart` (`DartCompiler.compile` /
//! `_compileExpression`) for the overall shape, and
//! `cpp/compiler/src/compiler.cpp` (`compile_expr`) as the closest analog —
//! both emit target source **as strings**, and both compile `Block` as a
//! self-contained, braces-delimited expression (an IIFE in C++; a native
//! Rust block expression here, since Rust blocks are already
//! tail-expression-valued).
//!
//! Every compiled Ball expression evaluates to a `ball_shared::BallValue`
//! (see `rust/shared/src/value.rs`). This is a deliberate, uniform
//! invariant of this crate: there are no "void" expressions — even
//! side-effecting calls like `print` compile to a `{ ...; BallValue::Null
//! }` block — which keeps every expression position (block tail, if/else
//! branches, function bodies) type-correct without needing a
//! statement-vs-expression compilation context.
//!
//! Phase 2b (issue #37) adds the real base-function dispatch table
//! (`base_call.rs`, delegating to `ball_shared::runtime` — see that
//! module's doc comment) plus **lazy** control flow (`if`/`and`/`or`/`for`/
//! `for_in`/`while`/`do_while` compile to native Rust control flow, never a
//! function call that would eagerly evaluate every branch — invariant #4)
//! and assignment/mutation (`crate::lvalue`).
//!
//! Phase 2c (issue #38) adds **type emission** and **multi-module output**
//! (`type_emit.rs`): `typeDefs[]` → Rust `struct`/`trait`/`enum` shapes
//! (`metadata.kind`/`is_abstract` decide which — see that module's doc
//! comment), functions flagged as a class member (`main:Point.describe`,
//! `main:Point.new`, ...) compile into the owner type's `impl` block instead
//! of as free functions, and each *other* Ball module compiles to its own
//! nested `pub mod <name> { ... }` (`compile_module_body`), with
//! cross-module calls resolved to `<mod>::<function>(...)`. Runtime values
//! stay the same dynamic `BallValue::Message`/`BallValue::Map` this crate
//! has used since #36 — Ball has no static type checker for a Rust compiler
//! to lean on, so a `struct`'s fields are a faithful (if largely
//! documentation-only) mapping of the `DescriptorProto`, while actual
//! instances and field reads still flow through
//! `ball_field_get`/`BallMessage` exactly as before. Polymorphic method
//! calls (two classes sharing a short method name, e.g. `Circle.area` /
//! `Rectangle.area`) can't be resolved to one concrete function at Rust
//! compile time — `compile_method_dispatchers` emits one free function per
//! shared short name that switches on the receiver's actual
//! `BallValue::Message::type_name` at run time and routes to the matching
//! `impl <Type>::<method>`, the same shape a dynamically-typed reference
//! engine gets for free from its own dispatch.
//!
//! ## Scope boundary (read before extending)
//!
//! This crate deliberately does **not** implement:
//! - A handful of individual base functions with a documented reason each
//!   (multi-parameter callbacks, `regex_*`, `std_memory`, ...) — see
//!   `base_call.rs`'s own module doc comment for the full list. Every one of
//!   these compiles to a clean runtime-helper fallback
//!   (`ball_unsupported_base_call`), not a compile-time panic.
//! - Constructors/methods with a real *body* that mutates `self` field-by-
//!   field (Java/TS-style `this.x = x;` constructors) — every #38 fixture's
//!   constructors are the Dart `Point(this.x, this.y)` init-formal-parameter
//!   shape (no body at all), so `type_emit.rs` only synthesizes that shape;
//!   a constructor that *does* carry a body compiles its body directly
//!   (defensive fallback — never panics — but doesn't get the `self`/field
//!   alias prologue a body would need to read/write instance state).
//! - A real class-hierarchy model (`superclass`/`interfaces` walked for
//!   inherited fields, Rust `impl Trait for Struct`, `is`/`as` subtype
//!   checks against a supertype chain) — `ball_is_type`
//!   (`rust/shared/src/runtime.rs`) still only matches an exact
//!   `Message.type_name` tag. `main:Circle extends Shape` compiles `Circle`
//!   as a fully independent struct; `Shape`'s own `is_abstract` methods
//!   become a `pub trait` purely for documentation (nothing `impl`s it —
//!   dispatch is by `type_name`, not Rust's trait system).
//! - Multi-parameter lambdas (needed for `list_reduce`/`list_sort`/...) —
//!   Ball's lambda calling convention is still single-`input`-only.
use std::cell::RefCell;
use std::collections::{HashMap, HashSet};

use ball_shared::proto::ball::v1::expression::Expr;
use ball_shared::proto::ball::v1::literal::Value as LiteralValue;
use ball_shared::proto::ball::v1::statement::Stmt;
use ball_shared::proto::ball::v1::{
    Block, Expression, FieldAccess, FunctionDefinition, Literal, MessageCreation, Module, Program,
    Reference,
};
use ball_shared::proto::google::protobuf::value::Kind;

mod base_call;
mod lvalue;
mod type_emit;

use type_emit::{is_class_member, split_member_name};

/// Compiles a Ball [`Program`] into Rust source.
///
/// Holds only the lookup tables needed to classify a `FunctionCall.module`
/// as a base module (dispatch to [`base_call::compile_base_call`]) versus a
/// user module (emit a direct Rust call). Borrows the source `Program` for
/// its lifetime rather than cloning it — mirrors the Dart/C++ compilers,
/// which hold a reference to the whole program for the duration of
/// compilation.
pub struct Compiler<'a> {
    program: &'a Program,
    /// Names of modules whose functions are *all* `is_base = true` (and at
    /// least one function) — e.g. `std`. Mirrors `DartCompiler._baseModules`
    /// (`dart/compiler/lib/compiler.dart`) and `CppCompiler::base_modules_`.
    base_modules: HashSet<String>,
    /// Names of every non-base module in the program (issue #38) — used by
    /// `type_emit::resolve_user_call_name` to decide whether a `call.module`
    /// names a *different* user module that needs `<mod>::` qualification,
    /// versus the module currently being compiled (no qualification needed).
    user_module_names: HashSet<String>,
    /// Every class-member `FunctionDefinition` (constructor/method —
    /// `main:Point.new`, `main:Point.describe`, ...), grouped by its owner
    /// `TypeDefinition.name` (issue #38). Populated once up front (mirrors
    /// `DartCompiler._buildLibrary`'s `classMethods` map) so
    /// `type_emit::compile_type_def` can place each member inside the right
    /// `impl`/`trait` block and `compile_message_creation` can map a
    /// constructor's positional `argN` fields to real field names.
    class_members_by_owner: HashMap<String, Vec<&'a FunctionDefinition>>,
    /// The Ball module currently being compiled (module name, not sanitized
    /// Rust identifier) — read by `type_emit::resolve_user_call_name` to
    /// decide whether a same-module call needs no qualification. Interior
    /// mutability keeps every `compile_*` method's signature untouched
    /// (`&self`, no extra "current module" parameter to thread through the
    /// whole expression-compilation tree); safe because modules are compiled
    /// one at a time, never interleaved — see `compile_module_body`.
    current_module: RefCell<String>,
}

impl<'a> Compiler<'a> {
    /// Build a compiler for `program`, scanning every module up front to
    /// determine which are base modules. A module qualifies when it
    /// declares at least one function and every function it declares has
    /// `is_base = true` — matching the reference compilers exactly (a
    /// mixed base/non-base module never occurs in practice, but an empty
    /// module must not be misclassified as "base" by a vacuous `all()`).
    pub fn new(program: &'a Program) -> Self {
        let mut base_modules = HashSet::new();
        for module in &program.modules {
            let all_base =
                !module.functions.is_empty() && module.functions.iter().all(|f| f.is_base);
            if all_base {
                base_modules.insert(module.name.clone());
            }
        }

        let user_module_names: HashSet<String> = program
            .modules
            .iter()
            .map(|m| m.name.clone())
            .filter(|name| !base_modules.contains(name))
            .collect();

        // Group every class-member function (constructor/method) by its
        // owner TypeDefinition name, scanning every non-base module — see
        // `type_emit::is_class_member`'s doc comment for the exact
        // classification rule (mirrors `DartCompiler._buildLibrary`).
        let mut class_members_by_owner: HashMap<String, Vec<&'a FunctionDefinition>> =
            HashMap::new();
        for module in &program.modules {
            if base_modules.contains(&module.name) {
                continue;
            }
            for func in &module.functions {
                if func.is_base || !is_class_member(func) {
                    continue;
                }
                if let Some((owner, _)) = split_member_name(&func.name) {
                    class_members_by_owner.entry(owner).or_default().push(func);
                }
            }
        }

        Compiler {
            program,
            base_modules,
            user_module_names,
            class_members_by_owner,
            current_module: RefCell::new(program.entry_module.clone()),
        }
    }

    fn is_base_module(&self, module: &str) -> bool {
        self.base_modules.contains(module)
    }

    // ════════════════════════════════════════════════════════════
    // Public API
    // ════════════════════════════════════════════════════════════

    /// Compile [`Self::program`] into a complete, runnable Rust source file:
    /// a `use ball_shared::runtime::*;` import (the base-function runtime
    /// helpers — see that module's doc comment), the entry module's own
    /// types/functions inlined at the top level, every *other* user module
    /// nested as its own `pub mod <name> { ... }` (issue #38 — see
    /// `compile_module_body`), and a `fn main()` wrapping the entry
    /// function's body (mirrors the Dart/C++ compilers inlining the entry
    /// function's body directly into the target language's real entry
    /// point, rather than emitting it as a separate function that `main`
    /// calls).
    ///
    /// `call.module` is resolved against *every* module in the program when
    /// classifying base-vs-user calls, so cross-module base calls (`std`,
    /// etc.) always compile correctly regardless of which module a call
    /// site lives in.
    pub fn compile(&self) -> String {
        let entry_module = self
            .program
            .modules
            .iter()
            .find(|m| m.name == self.program.entry_module)
            .unwrap_or_else(|| panic!("Entry module \"{}\" not found", self.program.entry_module));
        let entry_func = entry_module
            .functions
            .iter()
            .find(|f| f.name == self.program.entry_function)
            .unwrap_or_else(|| {
                panic!(
                    "Entry function \"{}\" not found",
                    self.program.entry_function
                )
            });

        let mut out = String::new();
        out.push_str(&format!(
            "// Generated by ball compiler (Rust target)\n// Source: {} v{}\n\n",
            self.program.name, self.program.version
        ));
        out.push_str("#![allow(unused_mut, dead_code)]\n\n");
        out.push_str("use ball_shared::{BallMap, BallMessage, BallValue};\n");
        out.push_str("use ball_shared::runtime::*;\n\n");

        // Every other user (non-base) module → its own nested `mod` block,
        // one per Ball module (issue #38's multi-module output). `use
        // super::*;` brings the preamble's `BallValue`/`BallMap`/
        // `BallMessage`/`runtime::*` imports into scope — Rust privacy lets
        // a child module see its ancestors' private `use` items, so this
        // needs no re-import.
        for module in &self.program.modules {
            if module.name == entry_module.name || self.is_base_module(&module.name) {
                continue;
            }
            out.push_str(&format!(
                "pub mod {} {{\n    use super::*;\n",
                sanitize_ident(&module.name)
            ));
            out.push_str(&self.compile_module_body(module));
            out.push_str("}\n\n");
        }

        out.push_str(&self.compile_module_body(entry_module));
        out.push_str(&self.compile_entry_main(entry_func));
        out
    }

    /// Compile one module's own types, class `impl`/`trait` blocks, method
    /// dispatchers, and standalone (non-base, non-class-member, non-entry)
    /// functions — everything *except* the program's `main()`. Shared by
    /// [`Self::compile`]'s entry-module inlining and its nested-`mod`-per-
    /// other-module loop (issue #38), so both paths get identical type/
    /// method/cross-module-call handling. Sets [`Self::current_module`] for
    /// the duration of `module`'s own compilation so
    /// `type_emit::resolve_user_call_name` can tell a same-module call
    /// (`call.module` empty or equal to `module.name`) from a genuine
    /// cross-module call needing `<mod>::` qualification.
    fn compile_module_body(&self, module: &Module) -> String {
        *self.current_module.borrow_mut() = module.name.clone();

        let mut out = String::new();
        out.push_str(&self.compile_module_types(module));
        for func in &module.functions {
            if func.is_base || is_class_member(func) {
                continue;
            }
            if module.name == self.program.entry_module && func.name == self.program.entry_function
            {
                continue;
            }
            out.push_str(&self.compile_function(func));
            out.push('\n');
        }
        out.push_str(&self.compile_method_dispatchers(module));
        out
    }

    /// Compile a single non-entry [`FunctionDefinition`] to a Rust function
    /// item: `pub fn <name>(input: BallValue) -> BallValue { ... }`
    /// (invariant #1 — one input, one output). When the function's metadata
    /// carries a single positional parameter name (the Dart/C++/TS
    /// compilers' convention for surfacing a readable parameter name, e.g.
    /// `fibonacci`'s `n`, instead of the raw `input`), the body is prefixed
    /// with `let <name> = input.clone();` so the body's references to that
    /// name resolve — see [`param_alias_prologue`].
    fn compile_function(&self, func: &FunctionDefinition) -> String {
        let name = sanitize_ident(&func.name);
        let prologue = self.param_alias_prologue(func);
        let body = match &func.body {
            Some(body) => self.compile_expression(body),
            None => "BallValue::Null".to_string(),
        };
        format!("pub fn {name}(input: BallValue) -> BallValue {{\n{prologue}{body}\n}}\n")
    }

    /// Compile the entry `FunctionDefinition` as Rust's real `fn main()`,
    /// inlining its body directly (mirrors every reference compiler — see
    /// `CppCompiler::emit_main`). The compiled body is always a
    /// `BallValue`-typed expression (this crate's uniform invariant — see
    /// the module doc comment), so its value is bound to `_` and discarded;
    /// any `print` calls inside it still execute for their side effects.
    fn compile_entry_main(&self, func: &FunctionDefinition) -> String {
        let prologue = self.param_alias_prologue(func);
        let body = match &func.body {
            Some(body) => self.compile_expression(body),
            None => "BallValue::Null".to_string(),
        };
        format!("fn main() {{\n{prologue}let _ballvalue_result: BallValue = {body};\n}}\n")
    }

    /// If `func.metadata.params` names exactly one positional parameter
    /// (the shape every reference compiler's encoder emits for a normal
    /// single-argument function — see `dart/compiler/lib/compiler.dart`'s
    /// `_addParameters`), emit `let <name> = input.clone();` so the body's
    /// references to that original name resolve. Richer parameter shapes
    /// (multiple/named/optional parameters, which need real typed
    /// destructuring of the input message) are `TypeDefinition`/descriptor
    /// work deferred to #38 — functions with zero or more-than-one declared
    /// parameters simply get no alias, and their bodies must reference
    /// `"input"` directly.
    ///
    /// The binding is `let mut` (rather than a plain `let`) whenever
    /// [`Compiler::expr_mutates_var`] finds the body reassigning its own
    /// parameter (a counter/accumulator-style function that treats its
    /// parameter as a local variable, e.g. `assign(target: n, ...)` or
    /// `n += 1` inside `func`'s body) — the same detection
    /// [`Compiler::compile_block`] already uses for `let`-bindings, applied
    /// here so a self-reassigning parameter alias doesn't hit Rust's "cannot
    /// assign twice to immutable variable" (issue #287).
    fn param_alias_prologue(&self, func: &FunctionDefinition) -> String {
        let Some(metadata) = &func.metadata else {
            return String::new();
        };
        let Some(params_value) = metadata.fields.get("params") else {
            return String::new();
        };
        let Some(Kind::ListValue(list)) = &params_value.kind else {
            return String::new();
        };
        if list.values.len() != 1 {
            return String::new();
        }
        let Some(Kind::StructValue(param_struct)) = &list.values[0].kind else {
            return String::new();
        };
        let Some(name_value) = param_struct.fields.get("name") else {
            return String::new();
        };
        let Some(Kind::StringValue(name)) = &name_value.kind else {
            return String::new();
        };
        if name.is_empty() || name == "input" {
            return String::new();
        }
        let mutates = func
            .body
            .as_deref()
            .is_some_and(|body| self.expr_mutates_var(body, name));
        let keyword = if mutates { "let mut" } else { "let" };
        format!("{keyword} {} = input.clone();\n", sanitize_ident(name))
    }

    // ════════════════════════════════════════════════════════════
    // Expression compilation — the 7 node types
    // ════════════════════════════════════════════════════════════

    /// Recursively compile any [`Expression`] to a Rust source string that
    /// evaluates to a `BallValue`. Dispatches on the `expr` oneof — every
    /// one of the seven variants is handled explicitly; an unset oneof
    /// (`Expr::None`, which the protobuf spec treats as an error/empty
    /// expression rather than any real Ball construct) compiles to
    /// `BallValue::Null` rather than panicking, matching the reference
    /// compilers' defensive `notSet` fallback
    /// (`Expression_Expr.notSet => _raw('/* unknown expression */')` in
    /// Dart) while staying inside this crate's uniform "every expression is
    /// `BallValue`-typed" invariant.
    pub fn compile_expression(&self, expr: &Expression) -> String {
        match &expr.expr {
            Some(Expr::Call(call)) => self.compile_call(call),
            Some(Expr::Literal(lit)) => self.compile_literal(lit),
            Some(Expr::Reference(reference)) => self.compile_reference(reference),
            Some(Expr::FieldAccess(field_access)) => self.compile_field_access(field_access),
            Some(Expr::MessageCreation(message_creation)) => {
                self.compile_message_creation(message_creation)
            }
            Some(Expr::Block(block)) => self.compile_block(block),
            Some(Expr::Lambda(lambda)) => self.compile_lambda(lambda),
            None => "BallValue::Null".to_string(),
        }
    }

    /// `literal` — emit a `BallValue` constructor for the literal's value.
    /// Every variant is handled: `null` (an unset `Literal.value` oneof —
    /// Ball's `Literal_Value.notSet`), `int64`, `double`, `string`, `bool`,
    /// `bytes`, and `list` (recursively compiling each element).
    fn compile_literal(&self, lit: &Literal) -> String {
        match &lit.value {
            None => "BallValue::Null".to_string(),
            Some(LiteralValue::IntValue(value)) => format!("BallValue::Int({value}i64)"),
            Some(LiteralValue::DoubleValue(value)) => {
                format!("BallValue::Double({})", format_double_literal(*value))
            }
            Some(LiteralValue::StringValue(value)) => {
                format!("BallValue::String({value:?}.to_string())")
            }
            Some(LiteralValue::BoolValue(value)) => format!("BallValue::Bool({value})"),
            Some(LiteralValue::BytesValue(bytes)) => {
                let items = bytes
                    .iter()
                    .map(|b| b.to_string())
                    .collect::<Vec<_>>()
                    .join(", ");
                format!("BallValue::Bytes(vec![{items}])")
            }
            Some(LiteralValue::ListValue(list)) => {
                let items = list
                    .elements
                    .iter()
                    .map(|el| self.compile_expression(el))
                    .collect::<Vec<_>>()
                    .join(", ");
                format!("BallValue::List(vec![{items}])")
            }
        }
    }

    /// `reference` — emit an identifier read. The special reference name
    /// `"input"` always denotes the current function's (or lambda's) single
    /// parameter (invariant #1) and lowers straight to the Rust parameter
    /// `input`. Every other reference resolves to an in-scope `let`
    /// binding, parameter alias (see [`param_alias_prologue`]), or —
    /// because Rust calls a closure-typed local with the same `name(args)`
    /// syntax as a function item — a function name shadowed into local
    /// scope. Every read is `.clone()`d: `BallValue` has no `Copy` impl
    /// (its `List`/`Map`/`Message` variants own heap data), and a
    /// reference may be used more than once in the same expression tree
    /// (e.g. `fibonacci(n - 1) + fibonacci(n - 2)` reads `n` twice).
    fn compile_reference(&self, reference: &Reference) -> String {
        if reference.name == "input" {
            "input.clone()".to_string()
        } else {
            format!("{}.clone()", sanitize_ident(&reference.name))
        }
    }

    /// `field_access` — `object.field` against a dynamic (`BallValue::Map`
    /// or `BallValue::Message`) receiver, via the
    /// [`base_call::field_get`] runtime helper. Real typed struct field
    /// access (`obj.field` compiling to a genuine Rust struct field read)
    /// needs `TypeDefinition`-driven struct emission, which is #38's scope.
    fn compile_field_access(&self, field_access: &FieldAccess) -> String {
        let object = match &field_access.object {
            Some(object) => self.compile_expression(object),
            None => "BallValue::Null".to_string(),
        };
        format!("ball_field_get({object}, {:?})", field_access.field)
    }

    /// `message_creation` — construct a runtime message value from named
    /// field expressions. Always builds a dynamic `BallValue::Map` (for an
    /// anonymous/argument-list message, `type_name` empty — the shape
    /// base-function inputs like `BinaryInput`'s `{left, right}` use) or a
    /// `BallValue::Message` (for a named `TypeDefinition` instance) — see
    /// the module doc comment for why this crate keeps that dynamic
    /// representation even after #38's type emission lands, rather than
    /// building a real typed Rust struct literal.
    ///
    /// **Constructor field-name mapping (issue #38):** when `type_name`
    /// names a class with a registered constructor (`main:Point.new`), the
    /// encoder emits the constructor *call* as positional fields literally
    /// named `arg0`, `arg1`, ... (see `dart/compiler/lib/compiler.dart`'s
    /// own `_compileArgs` positional convention) — those must be renamed to
    /// the constructor's *real* parameter names (`x`, `y`, ...) in
    /// declaration order so a later `field_access`/method reads the field
    /// under the name it actually expects
    /// (`type_emit::constructor_field_names`). A field whose name doesn't
    /// match the `argN` shape (or a type with no registered constructor —
    /// e.g. a plain literal-field `MessageCreation` in a hand-built fixture)
    /// is inserted under its given name unchanged, exactly as before #38.
    fn compile_message_creation(&self, message_creation: &MessageCreation) -> String {
        let ctor_params = self.constructor_field_names(&message_creation.type_name);
        let mut inserts = String::new();
        for (index, field) in message_creation.fields.iter().enumerate() {
            let value = match &field.value {
                Some(value) => self.compile_expression(value),
                None => "BallValue::Null".to_string(),
            };
            let field_name = if type_emit::is_positional_arg_name(&field.name) {
                ctor_params
                    .get(index)
                    .map(|(name, _)| name.clone())
                    .unwrap_or_else(|| field.name.clone())
            } else {
                field.name.clone()
            };
            inserts.push_str(&format!(
                "__ball_map.insert({field_name:?}.to_string(), {value});\n"
            ));
        }
        if message_creation.type_name.is_empty() {
            format!(
                "{{ let mut __ball_map = BallMap::new(); {inserts}BallValue::Map(__ball_map) }}"
            )
        } else {
            format!(
                "{{ let mut __ball_map = BallMap::new(); {inserts}BallValue::Message(BallMessage {{ type_name: {:?}.to_string(), fields: __ball_map }}) }}",
                message_creation.type_name
            )
        }
    }

    /// `block` — a Rust block expression `{ stmt; stmt; tail }`. Ball's
    /// `Block.statements` are `let`-bindings or bare expressions (evaluated
    /// for side effects); `Block.result` is the value the whole block
    /// evaluates to (defaulting to `BallValue::Null` when absent — an
    /// empty/statement-only block, matching every reference compiler's
    /// convention). Rust blocks are natively tail-expression-valued, so
    /// (unlike the C++ reference, which must emit an immediately-invoked
    /// lambda to fake this) this compiles directly to a real Rust block —
    /// used both standalone and, for a function's top-level body, nested
    /// one level inside the enclosing `fn`'s own braces (harmless — a
    /// block-as-a-block-tail is ordinary, valid Rust).
    ///
    /// Each `let` binding is declared `let mut` when [`Compiler::rest_mutates_var`]
    /// finds an `assign`/increment/mutating-collection call targeting it
    /// anywhere later in the same block (including inside a loop body, `if`
    /// branch, or nested block reached from a later statement) — needed for
    /// the ordinary "declare a loop counter, then mutate it in a `while`"
    /// shape, which #37's control-flow codegen (`base_call.rs`) otherwise
    /// has no way to make compile (Rust rejects reassigning an immutable
    /// `let`). See `crate::lvalue`'s module doc comment for the full design.
    fn compile_block(&self, block: &Block) -> String {
        let mut out = String::from("{\n");
        for (index, statement) in block.statements.iter().enumerate() {
            match &statement.stmt {
                Some(Stmt::Let(let_binding)) => {
                    let name = sanitize_ident(&let_binding.name);
                    let value = match &let_binding.value {
                        Some(value) => self.compile_expression(value),
                        None => "BallValue::Null".to_string(),
                    };
                    let mutated = self.rest_mutates_var(
                        &block.statements[index + 1..],
                        block.result.as_deref(),
                        &let_binding.name,
                    );
                    let keyword = if mutated { "let mut" } else { "let" };
                    out.push_str(&format!("{keyword} {name} = {value};\n"));
                }
                Some(Stmt::Expression(expression)) => {
                    out.push_str(&self.compile_expression(expression));
                    out.push_str(";\n");
                }
                None => {}
            }
        }
        let tail = match &block.result {
            Some(result) => self.compile_expression(result),
            None => "BallValue::Null".to_string(),
        };
        out.push_str(&tail);
        out.push_str("\n}");
        out
    }

    /// `lambda` — an anonymous [`FunctionDefinition`] (`name` empty) whose
    /// `body` is compiled exactly like any other function's, but as a Rust
    /// **closure** (`move |input: BallValue| -> BallValue { ... }`) rather
    /// than a top-level `fn` item, so it captures its enclosing lexical
    /// scope by value (`move`) — every reference the body makes to an
    /// outer local is a `.clone()`, so capturing by value never fights a
    /// borrow of the same local used again after the closure is built. The
    /// lambda's own parameter is again addressed as `"input"`
    /// ([`compile_reference`] handles this uniformly — a lambda's
    /// `FunctionDefinition` is compiled with the same
    /// [`param_alias_prologue`] as a named function, so a lambda with a
    /// single named parameter in its metadata gets the same alias
    /// prologue).
    fn compile_lambda(&self, lambda: &FunctionDefinition) -> String {
        let prologue = self.param_alias_prologue(lambda);
        let body = match &lambda.body {
            Some(body) => self.compile_expression(body),
            None => "BallValue::Null".to_string(),
        };
        format!("(move |input: BallValue| -> BallValue {{\n{prologue}{body}\n}})")
    }
}

/// Format a `double` literal for embedding in generated Rust source (a
/// syntactically valid Rust `f64` expression, not stdout formatting — see
/// `ball_shared::value::format_double` for *that*, used at run time by the
/// compiled program's own `BallValue::Display`). Rust has no literal syntax
/// for NaN/Infinity, so those lower to the `f64::NAN`/`f64::INFINITY`/
/// `f64::NEG_INFINITY` constants; every finite value uses `{:?}` (Rust's
/// `f64` `Debug` always includes a decimal point — `5.0`, not `5` — so the
/// output always parses back as a float literal, never an integer).
fn format_double_literal(value: f64) -> String {
    if value.is_nan() {
        return "f64::NAN".to_string();
    }
    if value.is_infinite() {
        return if value.is_sign_negative() {
            "f64::NEG_INFINITY".to_string()
        } else {
            "f64::INFINITY".to_string()
        };
    }
    format!("{value:?}")
}

/// Sanitize a Ball identifier (function/variable/field name) into a valid
/// Rust identifier: non-`[A-Za-z0-9_]` characters become `_`, a leading
/// digit gets a `_` prefix, an empty name becomes `_unnamed`, and a Rust
/// reserved keyword gets a trailing `_` (the common transpiler convention —
/// simpler than raw identifiers, which don't support `self`/`Self`/`super`/
/// `crate` anyway). Ball identifiers from every existing encoder are
/// already valid source identifiers in their origin language, so this is a
/// defensive fallback, not the common case.
fn sanitize_ident(name: &str) -> String {
    const RESERVED: &[&str] = &[
        "as", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false",
        "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub",
        "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type",
        "unsafe", "use", "where", "while", "async", "await", "try", "union", "yield", "abstract",
        "become", "box", "do", "final", "macro", "override", "priv", "typeof", "unsized",
        "virtual", "gen",
    ];
    let mut result: String = name
        .chars()
        .map(|c| {
            if c.is_alphanumeric() || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect();
    if result.is_empty() {
        result = "_unnamed".to_string();
    }
    if result.chars().next().is_some_and(|c| c.is_ascii_digit()) {
        result = format!("_{result}");
    }
    if RESERVED.contains(&result.as_str()) {
        result.push('_');
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use ball_shared::proto::ball::v1::{
        FieldValuePair, FunctionCall, ListLiteral, Literal as LiteralMsg, Module,
    };
    use ball_shared::proto::google::protobuf::{ListValue, Struct, Value};

    fn program_with_std() -> Program {
        Program {
            name: "test".to_string(),
            version: "1.0.0".to_string(),
            modules: vec![ball_shared::build_std_module()],
            entry_module: "main".to_string(),
            entry_function: "main".to_string(),
            metadata: None,
        }
    }

    fn int_lit(value: i64) -> Expression {
        Expression {
            expr: Some(Expr::Literal(LiteralMsg {
                value: Some(LiteralValue::IntValue(value)),
            })),
        }
    }

    fn reference(name: &str) -> Expression {
        Expression {
            expr: Some(Expr::Reference(Reference {
                name: name.to_string(),
            })),
        }
    }

    // ── literal ──────────────────────────────────────────────
    #[test]
    fn compiles_literal_variants() {
        let program = program_with_std();
        let compiler = Compiler::new(&program);

        assert_eq!(
            compiler.compile_literal(&Literal { value: None }),
            "BallValue::Null"
        );
        assert_eq!(
            compiler.compile_literal(&LiteralMsg {
                value: Some(LiteralValue::IntValue(42))
            }),
            "BallValue::Int(42i64)"
        );
        assert_eq!(
            compiler.compile_literal(&LiteralMsg {
                value: Some(LiteralValue::DoubleValue(3.25))
            }),
            "BallValue::Double(3.25)"
        );
        assert_eq!(
            compiler.compile_literal(&LiteralMsg {
                value: Some(LiteralValue::BoolValue(true))
            }),
            "BallValue::Bool(true)"
        );
        assert_eq!(
            compiler.compile_literal(&LiteralMsg {
                value: Some(LiteralValue::StringValue("hi\n\"there\"".to_string()))
            }),
            "BallValue::String(\"hi\\n\\\"there\\\"\".to_string())"
        );
        assert_eq!(
            compiler.compile_literal(&LiteralMsg {
                value: Some(LiteralValue::BytesValue(vec![1, 2, 3]))
            }),
            "BallValue::Bytes(vec![1, 2, 3])"
        );
        assert_eq!(
            compiler.compile_literal(&LiteralMsg {
                value: Some(LiteralValue::ListValue(ListLiteral {
                    elements: vec![int_lit(1), int_lit(2)],
                })),
            }),
            "BallValue::List(vec![BallValue::Int(1i64), BallValue::Int(2i64)])"
        );
    }

    #[test]
    fn double_literal_handles_nan_and_infinity() {
        assert_eq!(format_double_literal(f64::NAN), "f64::NAN");
        assert_eq!(format_double_literal(f64::INFINITY), "f64::INFINITY");
        assert_eq!(
            format_double_literal(f64::NEG_INFINITY),
            "f64::NEG_INFINITY"
        );
        assert_eq!(format_double_literal(5.0), "5.0");
    }

    // ── reference ────────────────────────────────────────────
    #[test]
    fn compiles_reference() {
        let program = program_with_std();
        let compiler = Compiler::new(&program);
        assert_eq!(
            compiler.compile_expression(&reference("input")),
            "input.clone()"
        );
        assert_eq!(compiler.compile_expression(&reference("n")), "n.clone()");
        // Reserved-keyword names are sanitized.
        assert_eq!(
            compiler.compile_expression(&reference("type")),
            "type_.clone()"
        );
    }

    // ── field_access ─────────────────────────────────────────
    #[test]
    fn compiles_field_access() {
        let program = program_with_std();
        let compiler = Compiler::new(&program);
        let expr = Expression {
            expr: Some(Expr::FieldAccess(Box::new(FieldAccess {
                object: Some(Box::new(reference("point"))),
                field: "x".to_string(),
            }))),
        };
        assert_eq!(
            compiler.compile_expression(&expr),
            "ball_field_get(point.clone(), \"x\")"
        );
    }

    // ── message_creation ─────────────────────────────────────
    #[test]
    fn compiles_anonymous_message_creation_to_ball_map() {
        let program = program_with_std();
        let compiler = Compiler::new(&program);
        let expr = Expression {
            expr: Some(Expr::MessageCreation(MessageCreation {
                type_name: String::new(),
                fields: vec![FieldValuePair {
                    name: "left".to_string(),
                    value: Some(int_lit(1)),
                }],
                metadata: None,
            })),
        };
        let compiled = compiler.compile_expression(&expr);
        assert!(compiled.contains("BallMap::new()"));
        assert!(
            compiled.contains("__ball_map.insert(\"left\".to_string(), BallValue::Int(1i64));")
        );
        assert!(
            compiled
                .trim_end()
                .ends_with("BallValue::Map(__ball_map) }")
        );
    }

    #[test]
    fn compiles_named_message_creation_to_ball_message() {
        let program = program_with_std();
        let compiler = Compiler::new(&program);
        let expr = Expression {
            expr: Some(Expr::MessageCreation(MessageCreation {
                type_name: "Point".to_string(),
                fields: vec![FieldValuePair {
                    name: "x".to_string(),
                    value: Some(int_lit(1)),
                }],
                metadata: None,
            })),
        };
        let compiled = compiler.compile_expression(&expr);
        assert!(
            compiled.contains("BallValue::Message(BallMessage { type_name: \"Point\".to_string()")
        );
    }

    // ── block ────────────────────────────────────────────────
    #[test]
    fn compiles_block_with_let_bindings_and_result() {
        let program = program_with_std();
        let compiler = Compiler::new(&program);
        let block = Block {
            statements: vec![ball_shared::proto::ball::v1::Statement {
                stmt: Some(Stmt::Let(ball_shared::proto::ball::v1::LetBinding {
                    name: "a".to_string(),
                    value: Some(int_lit(1)),
                    metadata: None,
                })),
            }],
            result: Some(Box::new(reference("a"))),
        };
        let expr = Expression {
            expr: Some(Expr::Block(Box::new(block))),
        };
        let compiled = compiler.compile_expression(&expr);
        assert!(compiled.starts_with('{'));
        assert!(compiled.contains("let a = BallValue::Int(1i64);"));
        assert!(compiled.trim_end().ends_with("a.clone()\n}"));
    }

    #[test]
    fn empty_block_defaults_result_to_null() {
        let program = program_with_std();
        let compiler = Compiler::new(&program);
        let expr = Expression {
            expr: Some(Expr::Block(Box::new(Block {
                statements: vec![],
                result: None,
            }))),
        };
        assert_eq!(compiler.compile_expression(&expr), "{\nBallValue::Null\n}");
    }

    // ── lambda ───────────────────────────────────────────────
    #[test]
    fn compiles_lambda_as_move_closure() {
        let program = program_with_std();
        let compiler = Compiler::new(&program);
        let lambda_def = FunctionDefinition {
            name: String::new(),
            input_type: String::new(),
            output_type: String::new(),
            body: Some(Box::new(reference("input"))),
            description: String::new(),
            is_base: false,
            metadata: None,
        };
        let expr = Expression {
            expr: Some(Expr::Lambda(Box::new(lambda_def))),
        };
        let compiled = compiler.compile_expression(&expr);
        assert!(compiled.contains("move |input: BallValue| -> BallValue"));
        assert!(compiled.contains("input.clone()"));
    }

    // ── call ─────────────────────────────────────────────────
    #[test]
    fn compiles_user_function_call() {
        let program = program_with_std();
        let compiler = Compiler::new(&program);
        let expr = Expression {
            expr: Some(Expr::Call(Box::new(FunctionCall {
                module: String::new(),
                function: "fibonacci".to_string(),
                input: Some(Box::new(int_lit(10))),
                type_args: vec![],
            }))),
        };
        assert_eq!(
            compiler.compile_expression(&expr),
            "fibonacci(BallValue::Int(10i64))"
        );
    }

    #[test]
    fn compiles_base_call_via_hook() {
        let program = program_with_std();
        let compiler = Compiler::new(&program);
        let expr = Expression {
            expr: Some(Expr::Call(Box::new(FunctionCall {
                module: "std".to_string(),
                function: "add".to_string(),
                input: Some(Box::new(Expression {
                    expr: Some(Expr::MessageCreation(MessageCreation {
                        type_name: String::new(),
                        fields: vec![
                            FieldValuePair {
                                name: "left".to_string(),
                                value: Some(int_lit(1)),
                            },
                            FieldValuePair {
                                name: "right".to_string(),
                                value: Some(int_lit(2)),
                            },
                        ],
                        metadata: None,
                    })),
                })),
                type_args: vec![],
            }))),
        };
        assert_eq!(
            compiler.compile_expression(&expr),
            "ball_add(BallValue::Int(1i64), BallValue::Int(2i64))"
        );
    }

    #[test]
    fn unimplemented_base_call_compiles_to_clean_runtime_fallback() {
        // `regex_match` is one of #37's explicitly-deferred functions (see
        // base_call.rs's module doc comment) — it must compile to a *call*
        // (so the surrounding program still builds), not a compile-time
        // panic, and the call must name both the module and function so a
        // program that actually reaches it fails loudly and legibly at run
        // time.
        let program = program_with_std();
        let compiler = Compiler::new(&program);
        let expr = Expression {
            expr: Some(Expr::Call(Box::new(FunctionCall {
                module: "std".to_string(),
                function: "regex_match".to_string(),
                input: None,
                type_args: vec![],
            }))),
        };
        let compiled = compiler.compile_expression(&expr);
        assert_eq!(
            compiled,
            "ball_unsupported_base_call(\"std\", \"regex_match\")"
        );
    }

    // ── param_alias_prologue ─────────────────────────────────
    #[test]
    fn single_named_param_gets_alias_prologue() {
        let program = program_with_std();
        let compiler = Compiler::new(&program);
        let mut params_struct_fields = std::collections::HashMap::new();
        params_struct_fields.insert(
            "name".to_string(),
            Value {
                kind: Some(Kind::StringValue("n".to_string())),
            },
        );
        params_struct_fields.insert(
            "type".to_string(),
            Value {
                kind: Some(Kind::StringValue("int".to_string())),
            },
        );
        let mut meta_fields = std::collections::HashMap::new();
        meta_fields.insert(
            "params".to_string(),
            Value {
                kind: Some(Kind::ListValue(ListValue {
                    values: vec![Value {
                        kind: Some(Kind::StructValue(Struct {
                            fields: params_struct_fields,
                        })),
                    }],
                })),
            },
        );
        let func = FunctionDefinition {
            name: "fibonacci".to_string(),
            input_type: "int".to_string(),
            output_type: "int".to_string(),
            body: Some(Box::new(reference("n"))),
            description: String::new(),
            is_base: false,
            metadata: Some(Struct {
                fields: meta_fields,
            }),
        };
        assert_eq!(
            compiler.param_alias_prologue(&func),
            "let n = input.clone();\n"
        );
    }

    #[test]
    fn no_params_metadata_gives_empty_prologue() {
        let program = program_with_std();
        let compiler = Compiler::new(&program);
        let func = FunctionDefinition {
            name: "main".to_string(),
            input_type: String::new(),
            output_type: "void".to_string(),
            body: Some(Box::new(int_lit(1))),
            description: String::new(),
            is_base: false,
            metadata: None,
        };
        assert_eq!(compiler.param_alias_prologue(&func), "");
    }

    // ── sanitize_ident ───────────────────────────────────────
    #[test]
    fn sanitizes_identifiers() {
        assert_eq!(sanitize_ident("n"), "n");
        assert_eq!(sanitize_ident("type"), "type_");
        assert_eq!(sanitize_ident("self"), "self_");
        assert_eq!(sanitize_ident("2fast"), "_2fast");
        assert_eq!(sanitize_ident(""), "_unnamed");
        assert_eq!(sanitize_ident("Dog.new"), "Dog_new");
    }

    // ── compile() end-to-end shape (structural — see tests/end_to_end.rs
    // for fixtures that actually invoke rustc/cargo and compare stdout) ──
    #[test]
    fn compile_emits_preamble_and_main() {
        let mut program = program_with_std();
        program.modules.push(Module {
            name: "main".to_string(),
            functions: vec![FunctionDefinition {
                name: "main".to_string(),
                input_type: String::new(),
                output_type: "void".to_string(),
                body: Some(Box::new(int_lit(1))),
                description: String::new(),
                is_base: false,
                metadata: None,
            }],
            ..Default::default()
        });
        let compiler = Compiler::new(&program);
        let compiled = compiler.compile();
        assert!(compiled.contains("use ball_shared::{BallMap, BallMessage, BallValue};"));
        assert!(compiled.contains("use ball_shared::runtime::*;"));
        assert!(compiled.contains("fn main() {"));
        assert!(!compiled.contains("pub fn main(")); // entry fn is inlined, not emitted as a wrapper
    }
}
