//! `ball-lang-compiler` — compiles a Ball `Program` protobuf into Rust source.
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
//! Every compiled Ball expression evaluates to a `ball_lang_shared::BallValue`
//! (see `rust/shared/src/value.rs`). This is a deliberate, uniform
//! invariant of this crate: there are no "void" expressions — even
//! side-effecting calls like `print` compile to a `{ ...; BallValue::Null
//! }` block — which keeps every expression position (block tail, if/else
//! branches, function bodies) type-correct without needing a
//! statement-vs-expression compilation context.
//!
//! Phase 2b (issue #37) adds the real base-function dispatch table
//! (`base_call.rs`, delegating to `ball_lang_shared::runtime` — see that
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

use ball_lang_shared::proto::ball::v1::expression::Expr;
use ball_lang_shared::proto::ball::v1::literal::Value as LiteralValue;
use ball_lang_shared::proto::ball::v1::statement::Stmt;
use ball_lang_shared::proto::ball::v1::{
    Block, Expression, FieldAccess, FunctionDefinition, Literal, MessageCreation, Module, Program,
    Reference, TypeDefinition,
};

mod base_call;
mod lvalue;
mod type_emit;

use type_emit::{is_class_member, split_member_name};

/// The encoders' shared sentinel reference name for an uninitialized
/// `late`/nullable local declaration (`int? maybe;`, a multi-variable
/// declaration's not-yet-assigned entry). The encoder emits
/// `reference{name: "__no_init__"}` as such a `LetBinding`'s value rather
/// than omitting it; every reference compiler special-cases it (Dart's
/// `_isNoInit`, TS's `__no_init__` symbol) — see [`Compiler::compile_reference`].
const NO_INIT_SENTINEL: &str = "__no_init__";

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
    /// Every user `TypeDefinition`, keyed by its **short** name (`"BallObject"`
    /// for a `TypeDefinition.name` of `"main:BallObject"`). Lets
    /// [`Compiler::inherited_field_names`] resolve a class's
    /// `metadata.superclass` (which the encoders store as the bare short name,
    /// e.g. `BallObject`'s `superclass: "BallMap"`) to the superclass's own
    /// `TypeDefinition`, so a subclass method/constructor body's bare reference
    /// to an *inherited* field binds like an own field (issue #39, gap #5 —
    /// class-hierarchy field inheritance).
    type_defs_by_short_name: HashMap<String, &'a TypeDefinition>,
    /// Every **sanitized** name that compiles to a callable Rust item — a
    /// standalone user function (`pub fn <name>`) or a polymorphic method
    /// dispatcher / short method name (`pub fn <short>`, see
    /// `type_emit::compile_method_dispatchers`). Used by
    /// [`Compiler::is_known_callable`] to tell a statically-resolvable
    /// function call (`fibonacci(n)` → a direct Rust call) from a call
    /// through a first-class function *value* (`bound(input)`, where `bound`
    /// is a local `BallValue::Function` — the self-hosted engine's
    /// `scope.lookup(name)(input)` shape), which must instead route through
    /// `ball_call_function` (issue #39, gap #6). A `BallValue` is not a Rust
    /// fn item, so emitting `bound(input)` for the latter is `error[E0618]`
    /// "expected function, found `BallValue`".
    callable_names: HashSet<String>,
    /// Lexical scope stack of **sanitized local binding names** — function/
    /// method/lambda parameters (`input`, aliased params, a method's `self_`
    /// and field aliases), `let` bindings, `for`/`for_in` loop variables, and
    /// `catch` variables. Each frame is one lexical scope (a function body, a
    /// `block`, a loop/catch body); [`Compiler::is_local`] checks the whole
    /// stack (every enclosing scope). Interior mutability keeps every
    /// `compile_*` method `&self` (like [`Compiler::current_module`]); safe
    /// because compilation is single-threaded and strictly nested — a frame
    /// is pushed on entering a scope and popped on leaving it.
    ///
    /// This is what lets [`Compiler::compile_call`] tell a call *through a
    /// value* (`bound(input)`, where `bound` is a local `BallValue::Function`
    /// — dynamic dispatch via `ball_call_function`) from a call to a real
    /// function *item* (a user function, or a `ball_lang_shared::runtime` Dart-SDK
    /// helper like `unmodifiable`/`now`/`cast` — a direct Rust call), which a
    /// name-only test cannot: both are unqualified, and a local can even
    /// shadow a function of the same name (the self-hosted engine binds a
    /// local `init`/`func`/… alongside its top-level namesakes). Issue #39,
    /// gap #6.
    local_scopes: RefCell<Vec<HashSet<String>>>,
    /// The **short names of every instance method** (non-static, non-abstract,
    /// non-constructor class member) declared anywhere in the program — the
    /// method-dispatcher names whose generated free `pub fn <short>(input)`
    /// reads `ball_field_get(input, "self")` to pick the concrete `impl`. A
    /// call to one of these from *inside* an instance method/constructor body
    /// (an implicit-`this` call — `this.method(args)`, encoded with only its
    /// arguments and no `self`) must have the receiver injected so that
    /// dispatcher finds one (issue #298 — the implicit-`this` dispatch gap).
    /// See [`Compiler::compile_call`].
    instance_method_names: HashSet<String>,
    /// The sanitized names of every **top-level variable** (`metadata.kind ==
    /// "top_level_variable"` — a `const`/`final`/`var` at library scope, e.g.
    /// the engine's `const _ballPointerBytes = 8;`). These compile to a nullary
    /// `pub fn <name>(input) -> BallValue { <initializer> }`, so a *reference*
    /// to one (`value.length * _ballPointerBytes`) is a **getter invocation**
    /// that must be **called** — `<name>(BallValue::Null)` — not torn off as a
    /// first-class function value (which would then fail arithmetic/comparison,
    /// "expected a number, got Function"). A reference to a real function
    /// (`kind == "function"`) stays a tear-off. Issue #300.
    top_level_var_names: HashSet<String>,
    /// Whether the expression tree currently being compiled is the body of a
    /// **non-static** instance method or a body-carrying constructor — i.e. a
    /// context where `self_` is a bound local and an implicit-`this` method
    /// call's receiver can be injected. Interior mutability (like
    /// [`Compiler::local_scopes`]) keeps every `compile_*` method `&self`; safe
    /// because method bodies are compiled one at a time, never interleaved
    /// (a nested lambda inside a method keeps this `true`, which is correct —
    /// the lambda still closes over the enclosing `self_`).
    in_instance_method: RefCell<bool>,
    /// The Ball module currently being compiled (module name, not sanitized
    /// Rust identifier) — read by `type_emit::resolve_user_call_name` to
    /// decide whether a same-module call needs no qualification. Interior
    /// mutability keeps every `compile_*` method's signature untouched
    /// (`&self`, no extra "current module" parameter to thread through the
    /// whole expression-compilation tree); safe because modules are compiled
    /// one at a time, never interleaved — see `compile_module_body`.
    current_module: RefCell<String>,
    /// The stack of enclosing **control-flow scopes** — a `try` body or a loop
    /// body — of the expression currently being compiled (issue #300). A
    /// `return`/`break`/`continue` inside a `try` body cannot escape the `try`'s
    /// `catch_unwind` closure with a bare Rust keyword; it must yield a
    /// [`ball_lang_shared::runtime::BallFlow`] the `try` re-issues after `finally`.
    /// Whether a `break`/`continue` needs that treatment depends on whether the
    /// nearest scope is the `try` (escape) or a loop (its own target) — hence a
    /// stack, not a counter. See [`Compiler::compile_try`].
    flow_scopes: RefCell<Vec<FlowScope>>,
    /// The stack of enclosing **goto-via-switch** label maps (issue #346) —
    /// see [`SwitchLabelCtx`] and `base_call.rs`'s `compile_switch_goto`.
    switch_label_stack: RefCell<Vec<SwitchLabelCtx>>,
    /// Monotonic counter minting unique `__swst<N>`/`swl<N>` names for
    /// (possibly nested) goto-via-switch lowerings.
    switch_uid: RefCell<usize>,
    /// Nesting depth of compiled `catch` handler bodies. `std.rethrow` (the
    /// Dart `rethrow` keyword) re-raises the exception the *innermost* enclosing
    /// catch is handling; `compile_try` binds that as `_ball_rethrow_err` and
    /// increments this while compiling the handler body, so `compile_rethrow`
    /// knows a rethrow target is in scope (issue #39/#300).
    catch_depth: RefCell<usize>,
    /// The instance fields of the class member currently being compiled, as
    /// `sanitized local name → original field key` (populated by
    /// `field_alias_prologue`, cleared when the member's compilation ends).
    /// Drives **late-bound field access inside lambdas** (issue #39/#300): a
    /// `move` closure pre-clones the method's field *alias*, freezing the value
    /// at closure-build time — the engine's `_buildStdDispatch` closures then
    /// read `_activeException` as it was at engine init (permanently `Null`),
    /// so a target program's `rethrow` reported "rethrow outside of catch".
    /// With this set, a lambda-body reference to an instance field compiles to
    /// a call-time `ball_field_get(__self_recv, …)` (and an assignment to a
    /// `ball_field_set` through the shared receiver), matching Dart's
    /// closure-over-`this` semantics.
    instance_fields: RefCell<std::collections::HashMap<String, String>>,
    /// The `local_scopes` frame index where each currently-open lambda's own
    /// scope begins. A name bound at/after the innermost floor is a lambda-local
    /// (parameter/`let` — shadows any instance-field namesake); a
    /// known-instance-field name bound only *below* it resolves late-bound
    /// through `__self_recv` (see `instance_fields`).
    lambda_scope_floors: RefCell<Vec<usize>>,
}

/// A control-flow scope on [`Compiler::flow_scopes`] — a `try` body or a loop
/// body — used to decide whether a `return`/`break`/`continue` must escape a
/// `try`'s `catch_unwind` closure via [`ball_lang_shared::runtime::BallFlow`]
/// (issue #300).
#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum FlowScope {
    /// A `try` body: `return`/`break`/`continue` here escape via `BallFlow`.
    Try,
    /// A loop body: a `break`/`continue` whose nearest scope is this loop is a
    /// bare Rust keyword (its target is inside every enclosing `try`).
    Loop,
}

/// A registered goto-via-switch's label→arm map, scoped for the duration of
/// compiling that switch's arm bodies (issue #346 — the Rust port of
/// `ts/compiler/src/compiler.ts`'s `switchLabelStack`). Looked up by
/// [`Compiler::resolve_switch_goto`] to lower a `continue <caseLabel>;` to a
/// state-variable jump instead of a (nonexistent) Rust loop label. See
/// `base_call.rs`'s `compile_switch_goto`.
pub(crate) struct SwitchLabelCtx {
    /// The lifetime-style Rust label on this switch's own dispatch `loop`
    /// (`swl0`, `swl1`, ...; used as `'swl0` — see
    /// [`Compiler::next_switch_uid`]). `continue <caseLabel>` re-enters it
    /// via `continue '<loop_label>` after setting `state_var`.
    pub(crate) loop_label: String,
    /// The `i64` local holding the currently-dispatched arm index.
    pub(crate) state_var: String,
    /// Case label name → its arm's `match` index. The default arm, if any,
    /// is index `arms.len()` — one past the last real case.
    pub(crate) label_to_arm: HashMap<String, usize>,
    /// [`Compiler::flow_scopes`]'s length at the moment this switch's own
    /// `FlowScope::Loop` was pushed. A `continue <caseLabel>` whose
    /// `flow_scopes[flow_floor..]` contains a `Try` must cross that `try`'s
    /// `catch_unwind` closure — a raw `continue '<loop_label>` there is an
    /// "unreachable label" `rustc` error (a closure can't jump to a label in
    /// its enclosing function), so [`Compiler::resolve_switch_goto`] declines
    /// the rewrite in that case, falling back to the existing (documented)
    /// labeled-continue-through-a-`try` gap instead of emitting code that
    /// fails to compile.
    pub(crate) flow_floor: usize,
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

        // Every user `TypeDefinition` keyed by short name, for superclass
        // resolution (issue #39 gap #5 — inherited-field binding). A
        // `metadata.superclass` names its parent by short name, so this map
        // resolves it back to the parent's `TypeDefinition`.
        let mut type_defs_by_short_name: HashMap<String, &'a TypeDefinition> = HashMap::new();
        for module in &program.modules {
            if base_modules.contains(&module.name) {
                continue;
            }
            for td in &module.type_defs {
                type_defs_by_short_name
                    .insert(type_emit::type_short_name(&td.name).to_string(), td);
            }
        }

        // Every sanitized name that resolves to a callable Rust *item* — a
        // standalone function (emitted as `pub fn <name>`) or a class member
        // that becomes a polymorphic dispatcher / short-named `pub fn`
        // (`type_emit::compile_method_dispatchers`). Any *other* callee name
        // is a first-class function value, dispatched dynamically (see
        // `callable_names`' doc comment). Over-inclusion is safe: a name in
        // this set compiles to a direct Rust call (the pre-#39 default),
        // while *under*-inclusion would wrongly route a real function call
        // through `ball_call_function` — so a constructor's `new` (invoked
        // via `MessageCreation`, never a bare call — harmless here) is left
        // in rather than special-cased out.
        let mut callable_names: HashSet<String> = HashSet::new();
        for module in &program.modules {
            if base_modules.contains(&module.name) {
                continue;
            }
            for func in &module.functions {
                if func.is_base {
                    continue;
                }
                // The entry function is never a callable `pub fn`: it is
                // inlined into `fn main()` (binary mode) or skipped entirely
                // (library mode — the self-host route), so it must not be
                // treated as a direct-call target or wrapped as a function
                // value (`BallFunction::new("main", main)` would bind Rust's
                // zero-arg `fn main`, a type error).
                if module.name == program.entry_module && func.name == program.entry_function {
                    continue;
                }
                if is_class_member(func) {
                    callable_names.insert(type_emit::member_short_name(&func.name));
                } else {
                    callable_names.insert(sanitize_ident(&func.name));
                }
            }
        }

        // Every instance-method short name — the receiver-reading dispatch
        // targets for implicit-`this` injection (issue #298). A method-call
        // node from inside an instance method body that names one of these must
        // have `self_` woven into its input.
        let mut instance_method_names: HashSet<String> = HashSet::new();
        for module in &program.modules {
            if base_modules.contains(&module.name) {
                continue;
            }
            for func in &module.functions {
                if func.is_base {
                    continue;
                }
                if let Some(short) = type_emit::instance_method_short_name(func) {
                    instance_method_names.insert(short);
                }
            }
        }

        // Every top-level-variable name — a reference to one is a getter
        // invocation (call it), not a function tear-off (issue #300).
        let mut top_level_var_names: HashSet<String> = HashSet::new();
        for module in &program.modules {
            if base_modules.contains(&module.name) {
                continue;
            }
            for func in &module.functions {
                if func.is_base || is_class_member(func) {
                    continue;
                }
                if type_emit::func_meta_kind(func).as_deref() == Some("top_level_variable") {
                    top_level_var_names.insert(sanitize_ident(&func.name));
                }
            }
        }

        Compiler {
            program,
            base_modules,
            user_module_names,
            class_members_by_owner,
            type_defs_by_short_name,
            callable_names,
            local_scopes: RefCell::new(Vec::new()),
            instance_method_names,
            top_level_var_names,
            in_instance_method: RefCell::new(false),
            current_module: RefCell::new(program.entry_module.clone()),
            flow_scopes: RefCell::new(Vec::new()),
            switch_label_stack: RefCell::new(Vec::new()),
            switch_uid: RefCell::new(0),
            catch_depth: RefCell::new(0),
            instance_fields: RefCell::new(std::collections::HashMap::new()),
            lambda_scope_floors: RefCell::new(Vec::new()),
        }
    }

    /// Record one instance field of the class member being compiled (called by
    /// `field_alias_prologue` per field). `sanitized` is the alias local's
    /// name, `original` the runtime field key (`ball_field_get`'s argument).
    pub(crate) fn record_instance_field(&self, sanitized: String, original: String) {
        self.instance_fields
            .borrow_mut()
            .insert(sanitized, original);
    }

    /// Forget the current member's instance fields (member compilation ended).
    pub(crate) fn clear_instance_fields(&self) {
        self.instance_fields.borrow_mut().clear();
    }

    /// Is `original` (an un-sanitized referenced name) an instance field of the
    /// class member currently being compiled?
    pub(crate) fn is_instance_field(&self, original: &str) -> bool {
        self.instance_fields
            .borrow()
            .get(&sanitize_ident(original))
            .is_some_and(|orig| orig == original)
    }

    /// Is `name` bound in a scope frame at or above `floor` (i.e. *inside* the
    /// innermost open lambda)? Used to let a lambda parameter/`let` shadow an
    /// instance-field namesake in the late-bound-field check.
    fn is_bound_at_or_above(&self, name: &str, floor: usize) -> bool {
        self.local_scopes.borrow()[floor..]
            .iter()
            .any(|frame| frame.contains(name))
    }

    /// If a reference to `original` from the current compilation point must be
    /// **late-bound** — read through the shared receiver at closure-call time
    /// rather than a pre-cloned alias — return the runtime field key. True only
    /// inside a lambda, for an instance field of the current member, when no
    /// lambda-local shadows the name and a `__self_recv` receiver is in scope.
    pub(crate) fn late_bound_field(&self, original: &str) -> Option<String> {
        // The *outermost* open lambda's floor: any binding created inside any
        // open lambda (its params/`let`s, or an enclosing lambda's) is a real
        // lambda-local that shadows a field namesake; only a binding from the
        // method scope proper (below every floor) is a stale-prone field alias.
        let floor = *self.lambda_scope_floors.borrow().first()?;
        if !self.is_instance_field(original)
            || self.is_bound_at_or_above(original, floor)
            || !self.is_local("__self_recv")
        {
            return None;
        }
        Some(original.to_string())
    }

    /// If `sanitized` (an `LValue::Var` mutation-target name) is an instance
    /// field of the current member, return its runtime field key — the
    /// mutation must also write through to the shared instance (immediately in
    /// a method body; via `__self_recv` inside a lambda). See
    /// [`Compiler::emit_mutation`].
    pub(crate) fn instance_field_key_of_var(&self, sanitized: &str) -> Option<String> {
        self.instance_fields.borrow().get(sanitized).cloned()
    }

    /// Is compilation currently inside a lambda body?
    pub(crate) fn in_lambda(&self) -> bool {
        !self.lambda_scope_floors.borrow().is_empty()
    }

    /// Enter a compiled `catch` handler body (`_ball_rethrow_err` is in scope).
    pub(crate) fn enter_catch(&self) {
        *self.catch_depth.borrow_mut() += 1;
    }

    /// Leave a compiled `catch` handler body. Paired with [`Compiler::enter_catch`].
    pub(crate) fn exit_catch(&self) {
        *self.catch_depth.borrow_mut() -= 1;
    }

    /// Is a `catch` handler body currently being compiled — i.e. is a
    /// `_ball_rethrow_err` binding in scope for `std.rethrow` to re-raise?
    pub(crate) fn in_catch(&self) -> bool {
        *self.catch_depth.borrow() > 0
    }

    /// Enter a control-flow scope (a `try` body or a loop body). Paired with
    /// [`Compiler::pop_flow_scope`].
    pub(crate) fn push_flow_scope(&self, kind: FlowScope) {
        self.flow_scopes.borrow_mut().push(kind);
    }

    /// Leave the innermost control-flow scope.
    pub(crate) fn pop_flow_scope(&self) {
        self.flow_scopes.borrow_mut().pop();
    }

    /// Does a `return` here need to escape a `try` via `BallFlow`? True iff any
    /// enclosing scope is a `try` (a `return` crosses every scope out to its
    /// function). Issue #300.
    pub(crate) fn return_needs_flow(&self) -> bool {
        self.flow_scopes.borrow().contains(&FlowScope::Try)
    }

    /// Does a `break`/`continue` here need to escape a `try` via `BallFlow`?
    /// True iff the **nearest** enclosing scope is a `try` (the break must
    /// cross it to reach its loop); false if the nearest scope is a loop (that
    /// loop is the break's own target — a bare Rust keyword). Issue #300.
    pub(crate) fn break_needs_flow(&self) -> bool {
        matches!(self.flow_scopes.borrow().last(), Some(FlowScope::Try))
    }

    /// The innermost enclosing scope (used by [`Compiler::compile_try`] to
    /// re-issue a `break`/`continue` that escaped it — into a bare keyword if a
    /// loop encloses the `try`, or a fresh `BallFlow` if another `try` does).
    pub(crate) fn innermost_flow_scope(&self) -> Option<FlowScope> {
        self.flow_scopes.borrow().last().copied()
    }

    // ════════════════════════════════════════════════════════════
    // Goto-via-switch (issue #346)
    // ════════════════════════════════════════════════════════════

    /// Register a goto-via-switch's label→arm map for the duration of
    /// compiling its arm bodies. Paired with
    /// [`Compiler::pop_switch_label_scope`].
    pub(crate) fn push_switch_label_scope(&self, ctx: SwitchLabelCtx) {
        self.switch_label_stack.borrow_mut().push(ctx);
    }

    /// Leave the innermost goto-via-switch label scope.
    pub(crate) fn pop_switch_label_scope(&self) {
        self.switch_label_stack.borrow_mut().pop();
    }

    /// The next unique id for a goto-via-switch's generated
    /// `__swst<N>`/`swl<N>` names (distinct per switch, including nested
    /// ones — mirrors `ts/compiler/src/compiler.ts`'s `switchUid`).
    pub(crate) fn next_switch_uid(&self) -> usize {
        let mut counter = self.switch_uid.borrow_mut();
        let id = *counter;
        *counter += 1;
        id
    }

    /// Does `label` name a case of an *enclosing* goto-via-switch (innermost
    /// wins — "innermost matching switch wins", mirroring
    /// `ts/compiler/src/compiler.ts`'s `switchLabelStack` search)? If so,
    /// return the compiled `continue <caseLabel>;` — a state-variable jump
    /// with no subject re-check. `None` means either `label` isn't a
    /// registered switch-case label, or it is one but resolving it here would
    /// have to cross an intervening `try`'s `catch_unwind` closure (see
    /// [`SwitchLabelCtx::flow_floor`]) — in both cases the caller
    /// ([`base_call::Compiler::compile_continue`]) falls back to a verbatim
    /// labeled `continue`.
    pub(crate) fn resolve_switch_goto(&self, label: &str) -> Option<String> {
        let stack = self.switch_label_stack.borrow();
        for ctx in stack.iter().rev() {
            let Some(&idx) = ctx.label_to_arm.get(label) else {
                continue;
            };
            let flow_scopes = self.flow_scopes.borrow();
            if flow_scopes[ctx.flow_floor..].contains(&FlowScope::Try) {
                return None;
            }
            return Some(format!(
                "{{ {} = {idx}; continue '{} }}",
                ctx.state_var, ctx.loop_label
            ));
        }
        None
    }

    // ════════════════════════════════════════════════════════════
    // Implicit-`this` context (issue #298)
    // ════════════════════════════════════════════════════════════

    /// Run `body` with the "inside an instance method/constructor body" flag
    /// set (so implicit-`this` calls inside it get `self_` injected), restoring
    /// the previous value afterward. Paired around a non-static method or
    /// body-carrying constructor's body compilation.
    fn with_instance_method<R>(&self, active: bool, body: impl FnOnce() -> R) -> R {
        let previous = self.in_instance_method.replace(active);
        let result = body();
        self.in_instance_method.replace(previous);
        result
    }

    /// Whether a `self_` local is in scope for implicit-`this` injection.
    fn in_instance_method(&self) -> bool {
        *self.in_instance_method.borrow()
    }

    /// Does `call`'s input already carry an **explicit** `self` field (an
    /// `obj.method(args)` call with a real receiver packed by the encoder)? If
    /// so, an implicit-`this` receiver must NOT be injected over it. Only a
    /// `message_creation` input can carry named fields, so any other input
    /// shape (a bare positional value, or none) has no explicit receiver.
    fn call_input_has_explicit_self(
        call: &ball_lang_shared::proto::ball::v1::FunctionCall,
    ) -> bool {
        matches!(
            call.input.as_deref(),
            Some(Expression { expr: Some(Expr::MessageCreation(mc)) })
                if mc.fields.iter().any(|f| f.name == "self")
        )
    }

    /// Is `call`'s input the encoder's **multi-argument message** — an anonymous
    /// (empty `type_name`) `MessageCreation` packing `arg0`/`arg1`/named fields
    /// (invariant #1)? A *single* positional argument is passed directly (any
    /// other expression shape, or a *typed* `MessageCreation` that is a real
    /// constructed instance), so this distinguishes the two for implicit-`this`
    /// injection (issue #300 — [`Compiler::compile_call`]): a multi-arg message
    /// gets `self` merged in, a single positional gets wrapped as `{self, arg0}`.
    fn call_input_is_arg_message(call: &ball_lang_shared::proto::ball::v1::FunctionCall) -> bool {
        matches!(
            call.input.as_deref(),
            Some(Expression { expr: Some(Expr::MessageCreation(mc)) })
                if mc.type_name.is_empty()
        )
    }

    // ════════════════════════════════════════════════════════════
    // Lexical scope tracking (issue #39, gap #6)
    // ════════════════════════════════════════════════════════════

    /// Enter a new lexical scope (a function/lambda/method body, a `block`, a
    /// loop or `catch` body). Paired with [`Compiler::pop_scope`].
    fn push_scope(&self) {
        self.local_scopes.borrow_mut().push(HashSet::new());
    }

    /// Leave the innermost lexical scope.
    fn pop_scope(&self) {
        self.local_scopes.borrow_mut().pop();
    }

    /// Record `name` (a `let`/parameter/loop/catch binding) as a local in the
    /// innermost scope. Stored sanitized so [`Compiler::is_local`] can be
    /// asked with a raw Ball name.
    fn bind_local(&self, name: &str) {
        if let Some(frame) = self.local_scopes.borrow_mut().last_mut() {
            frame.insert(sanitize_ident(name));
        }
    }

    /// Is `name` a local binding in *any* enclosing scope (as opposed to a
    /// top-level function item, a `ball_lang_shared::runtime` helper, or an enum
    /// namespace static)? See [`Compiler::local_scopes`].
    fn is_local(&self, name: &str) -> bool {
        let sanitized = sanitize_ident(name);
        self.local_scopes
            .borrow()
            .iter()
            .any(|frame| frame.contains(&sanitized))
    }

    fn is_base_module(&self, module: &str) -> bool {
        self.base_modules.contains(module)
    }

    /// Does `function` (a `FunctionCall.function` / `Reference.name`) resolve
    /// to a callable Rust item (a `pub fn`), as opposed to a first-class
    /// function *value* held in a `BallValue`? Drives both the
    /// direct-call-vs-`ball_call_function` choice in
    /// [`Compiler::compile_call`] and the fn-item-vs-`BallValue::Function`
    /// wrapping in [`Compiler::compile_reference`] (issue #39, gap #6).
    fn is_known_callable(&self, function: &str) -> bool {
        self.callable_names.contains(&sanitize_ident(function))
    }

    // ════════════════════════════════════════════════════════════
    // Public API
    // ════════════════════════════════════════════════════════════

    /// Compile [`Self::program`] into a complete, runnable Rust source file:
    /// a `use ball_lang_shared::runtime::*;` import (the base-function runtime
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

        let mut out = self.compile_modules();
        out.push_str(&self.compile_entry_main(entry_func));
        out
    }

    /// Compile [`Self::program`] as a **library** — every module's types and
    /// functions, but **no `fn main()`** and **no requirement that
    /// `entry_function` exist** (issue #39, the self-host route). The
    /// self-hosted engine (`dart/self_host/engine.ball.json`) is not a
    /// runnable program with a top-level entry point but a *library* whose
    /// public surface is the `BallEngine` / `StdModuleHandler` classes — the
    /// runtime wrapper (`rust/engine/src/lib.rs`) instantiates and drives
    /// those, exactly as the TS wrapper drives its own compiled engine's
    /// `BallEngine`/`StdModuleHandler` (`ts/engine/src/index.ts`) instead of
    /// calling a compiled `main`. Structurally identical to [`Self::compile`]
    /// minus the entry-point wrapper: the entry module (still `main` here)
    /// is inlined at the top level so the wrapper can reference its types by
    /// their bare Rust names; every other user module nests under its own
    /// `pub mod`.
    pub fn compile_library(&self) -> String {
        self.compile_modules()
    }

    /// Emit `pub fn __ball_register_types()` — one `ball_register_superclass`
    /// per user class that `extends` another (from `metadata.superclass`), so a
    /// runtime `is`/`as` against a supertype resolves (issue #300). Called once
    /// by `fn main()` (binary mode) or the self-host wrapper (library mode)
    /// before any program runs.
    fn emit_type_registrations(&self) -> String {
        let mut regs = String::new();
        for module in &self.program.modules {
            if self.is_base_module(&module.name) {
                continue;
            }
            for td in &module.type_defs {
                if let Some(superclass) = type_emit::superclass_of(td) {
                    let child = type_emit::type_short_name(&td.name);
                    let parent = type_emit::type_short_name(&superclass);
                    regs.push_str(&format!(
                        "    ball_register_superclass({child:?}, {parent:?});\n"
                    ));
                }
            }
        }
        format!("pub fn __ball_register_types() {{\n{regs}}}\n")
    }

    /// Shared body of [`Self::compile`] and [`Self::compile_library`]: the
    /// preamble (imports) plus every module's types/functions. The entry
    /// module is inlined at the top level; every other non-base module nests
    /// under its own `pub mod`. Emits neither a `fn main()` nor any
    /// entry-function lookup — both callers layer that (or not) on top.
    fn compile_modules(&self) -> String {
        let entry_module = self
            .program
            .modules
            .iter()
            .find(|m| m.name == self.program.entry_module)
            .unwrap_or_else(|| panic!("Entry module \"{}\" not found", self.program.entry_module));

        let mut out = String::new();
        out.push_str(&format!(
            "// Generated by ball compiler (Rust target)\n// Source: {} v{}\n\n",
            self.program.name, self.program.version
        ));
        out.push_str("#![allow(unused_mut, dead_code, unused_variables)]\n\n");
        out.push_str(
            "use ball_lang_shared::{BallFunction, BallList, BallMap, BallMessage, BallValue};\n",
        );
        out.push_str("use ball_lang_shared::runtime::*;\n\n");

        // The Ball-proto oneof-discriminator enum namespaces
        // (`Expression_Expr`, `Literal_Value`, `Statement_Stmt`,
        // `ModuleImport_Source`, `structpb_Value_Kind`) — synthesized enums
        // with no `EnumDescriptorProto`, so `compile_module_types` never emits
        // them, yet the self-hosted engine references them as bare
        // `Expression_Expr.call` (issue #39). Emitted at the crate root so the
        // top-level entry module sees them directly and every nested `mod …
        // { use super::*; }` sees them via its glob import. See
        // `type_emit::oneof_discriminator_enum_defs`.
        out.push_str(&type_emit::oneof_discriminator_enum_defs());
        out.push('\n');

        // The class-hierarchy registration (`BallObject extends BallMap`, …) —
        // a `pub fn __ball_register_types()` the entry point / self-host wrapper
        // calls once so a runtime `is`/`as` against a supertype resolves (issue
        // #300). Emitted at the crate root (visible to `fn main()` and the
        // wrapper alike).
        out.push_str(&self.emit_type_registrations());
        out.push('\n');

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
            let body = self.compile_module_body(module);
            if body.trim().is_empty() {
                // An empty non-base module (no Ball-defined functions or
                // types) is a pure **namespace marker** for a foreign SDK —
                // the self-hosted engine declares `dart_math`, `dart_io`, …
                // this way and then calls into them fully qualified
                // (`dart_math::sqrt(x)`, `dart_io::File(path)`). Re-export the
                // shared runtime so those qualified calls resolve to the
                // matching `ball_lang_shared::runtime` helper (issue #39 gap #2 —
                // the Dart-SDK method/type surface). A `use super::*;` glob
                // would *not* work: it imports privately, so the names would
                // not be reachable as `<mod>::<name>` from the crate root.
                out.push_str(&format!(
                    "pub mod {} {{\n    pub use ball_lang_shared::runtime::*;\n}}\n\n",
                    sanitize_ident(&module.name)
                ));
            } else {
                out.push_str(&format!(
                    "pub mod {} {{\n    use super::*;\n",
                    sanitize_ident(&module.name)
                ));
                out.push_str(&body);
                out.push_str("}\n\n");
            }
        }

        out.push_str(&self.compile_module_body(entry_module));
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
        self.push_scope();
        self.bind_local("input");
        let prologue = self.param_alias_prologue(func);
        let body = match &func.body {
            Some(body) => self.compile_expression(body),
            None => "BallValue::Null".to_string(),
        };
        self.pop_scope();
        format!("pub fn {name}(input: BallValue) -> BallValue {{\n{prologue}{body}\n}}\n")
    }

    /// Compile the entry `FunctionDefinition` as Rust's real `fn main()`,
    /// inlining its body directly (mirrors every reference compiler — see
    /// `CppCompiler::emit_main`). The compiled body is always a
    /// `BallValue`-typed expression (this crate's uniform invariant — see
    /// the module doc comment), so its value is bound to `_` and discarded;
    /// any `print` calls inside it still execute for their side effects.
    fn compile_entry_main(&self, func: &FunctionDefinition) -> String {
        self.push_scope();
        self.bind_local("input");
        let prologue = self.param_alias_prologue(func);
        let body = match &func.body {
            Some(body) => self.compile_expression(body),
            None => "BallValue::Null".to_string(),
        };
        self.pop_scope();
        format!(
            // The entry body runs inside an **IIFE closure** so a top-level
            // `return X` (including one propagated out of a `try` as
            // `BallFlow::Return`) returns from the closure — yielding a
            // `BallValue` — rather than from `fn main()` (which returns `()`,
            // an E0308 type error). Issue #300.
            "fn main() {{\n__ball_register_types();\n{prologue}let _ballvalue_result: BallValue = (|| -> BallValue {{ {body} }})();\n}}\n"
        )
    }

    /// Emit the `let`-bindings a free function's (or lambda's) body needs to
    /// resolve its declared parameter names — a thin wrapper over the shared
    /// [`Compiler::params_binding_prologue`], which handles the full
    /// convention: a lone positional argument passed directly
    /// (`let <name> = input.clone();`, the common single-argument shape like
    /// `fibonacci`'s `n`), multiple positional arguments destructured from the
    /// input message's `arg0`/`arg1`/… fields, and named/optional-named
    /// arguments destructured by their own name — each `let mut` when the body
    /// reassigns it (issue #287). A receiver-less function is always the
    /// "single positional argument passed directly" case for one argument,
    /// hence `single_positional_is_direct = true`.
    fn param_alias_prologue(&self, func: &FunctionDefinition) -> String {
        // A free function/lambda has no receiver, so its lone positional
        // argument is passed directly (see [`Compiler::params_binding_prologue`]
        // for the full multi/named-parameter convention this shares with
        // [`Compiler::method_prologue`]).
        self.params_binding_prologue(func, true)
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
            // A list *literal* builds a **fresh** reference-semantic backing
            // (`BallList::from`) — a distinct list per evaluation, never aliasing
            // (issues #39/#300). Aliasing only happens on a *read* of an existing
            // list (`compile_reference`'s `.clone()`). Spread/`collection_if`/
            // `collection_for` elements are *spliced* (see
            // [`Compiler::compile_list_literal`]).
            Some(LiteralValue::ListValue(list)) => self.compile_list_literal(list),
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
        } else if reference.name == NO_INIT_SENTINEL {
            // `__no_init__` is the encoders' shared sentinel for an
            // uninitialized `late`/nullable local (`int? maybe;`, a
            // multi-variable declaration's not-yet-assigned entry, a
            // for-init counter with no initializer): the encoder emits
            // `reference{name: "__no_init__"}` as the `LetBinding.value`
            // rather than omitting it (see `dart/encoder/lib/encoder.dart`'s
            // `_encodeVarDecl*` and `dart/compiler/lib/compiler.dart`'s
            // `_isNoInit`). It is not a real in-scope binding, so lowering it
            // to `<name>.clone()` produces an unresolved-name error (`cannot
            // find value __no_init__`) — 32 such sites appear in the
            // self-hosted engine alone. Every reference engine binds an
            // uninitialized declaration to `null` (`dart/engine/lib/
            // engine_eval.dart` treats a `__no_init__`-valued let as `null`),
            // so this compiles to `BallValue::Null` — the same value a read
            // of the still-unassigned variable yields.
            "BallValue::Null".to_string()
        } else if let Some(field_key) = self.late_bound_field(&reference.name) {
            // Late-bound instance-field read inside a lambda (issue #39/#300):
            // read through the shared receiver at closure-*call* time. The
            // pre-cloned field alias a `move` closure captures freezes the
            // value at closure-build time — the engine's `_buildStdDispatch`
            // closures (built once at init) then read `_activeException` (and
            // every other scalar field) permanently stale. `__self_recv` is a
            // clone of the reference-semantic instance (`Arc<Mutex>`-backed
            // fields), so this sees the field as of the call — Dart's
            // closure-over-`this` semantics.
            format!("ball_field_get(__self_recv.clone(), {field_key:?})")
        } else if !self.is_local(&reference.name)
            && self
                .top_level_var_names
                .contains(&sanitize_ident(&reference.name))
        {
            // A reference to a top-level variable (`_ballPointerBytes`) is a
            // getter invocation — call its nullary `pub fn` to read the value,
            // rather than tearing it off as a `BallValue::Function` (which then
            // fails arithmetic, "expected a number, got Function"). Issue #300.
            format!("{}(BallValue::Null)", sanitize_ident(&reference.name))
        } else if !self.is_local(&reference.name)
            && self.in_instance_method()
            && self
                .instance_method_names
                .contains(&sanitize_ident(&reference.name))
        {
            // A bare reference to an **instance method** from inside an instance
            // method body is a *bound* method tear-off (`{'print': _stdPrint}`
            // in the engine's `_buildStdDispatch`) — Dart binds `this`. The
            // method dispatcher reads its receiver from the input's `self`, so
            // the tear-off must weave the enclosing receiver (`__self_recv`) into
            // whatever single argument the value is later called with, as
            // `{self, arg0: arg}` (issue #300 — otherwise the dispatcher sees no
            // receiver, or a wrong one, and fails "no method for type"). The
            // receiver is pre-cloned so the `move` closure owns it without moving
            // the enclosing `__self_recv` (which other tear-offs in the same
            // method also capture).
            let name = sanitize_ident(&reference.name);
            format!(
                "{{ let __self_recv = __self_recv.clone(); \
                 BallValue::Function(BallFunction::new({name:?}, move |__ball_arg: BallValue| -> BallValue {{ \
                 {name}(ball_arg0_with_self(__ball_arg, __self_recv.clone())) }})) }}"
            )
        } else if !self.is_local(&reference.name) && self.is_known_callable(&reference.name) {
            // A bare reference (value position, not a call) to a top-level
            // function that is *not* shadowed by a local of the same name: it
            // is being used as a first-class function *value* (`var f =
            // someFunc;`, a callback argument, `builtinResult != _sentinel`).
            // Every user function compiles to a Rust `fn(BallValue) ->
            // BallValue` item, which is not itself a `BallValue`, so
            // `<name>.clone()` here is `error[E0308]` "expected `BallValue`,
            // found fn item". Wrap it as a `BallValue::Function` (the fn item
            // coerces to the stored closure) so it flows as a value and can be
            // invoked via `ball_call_function` (issue #39, gap #6). The
            // `is_local` guard is essential — the self-hosted engine binds
            // locals (`init`, `func`, …) that shadow top-level namesakes, and
            // wrapping such a local (already a `BallValue`) as a fn item would
            // reintroduce the very E0277/E0308 this fixes.
            let name = sanitize_ident(&reference.name);
            format!("BallValue::Function(BallFunction::new({name:?}, {name}))")
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
        // A **Dart-SDK collection constructor** (`LinkedHashMap()`, `Map.from(x)`,
        // `HashSet()`) builds the native `BallValue` collection, not an opaque
        // `BallValue::Message` the map/set runtime helpers reject (issue #300).
        if let Some(collection) = self.sdk_collection_creation(message_creation) {
            return collection;
        }
        // A type with a **body-carrying constructor** (`BallObject.new` runs
        // `_refreshEntries()`; `BallEngine.new` builds its lookup tables) must
        // be built by *invoking that constructor*, not by an inline field map —
        // otherwise the body never runs and the instance is half-built (issue
        // #300). The constructor's own associated fn binds the args, seeds field
        // defaults, runs the body, and writes mutated fields back.
        if let Some(ctor_fn) = self.body_constructor_fn(&message_creation.type_name) {
            let mut args = String::new();
            for field in &message_creation.fields {
                let value = match &field.value {
                    Some(value) => self.compile_expression(value),
                    None => "BallValue::Null".to_string(),
                };
                args.push_str(&format!(
                    "__ball_map.insert({:?}.to_string(), {value});\n",
                    field.name
                ));
            }
            return format!(
                "{ctor_fn}({{ let mut __ball_map = BallMap::new(); {args}BallValue::Map(__ball_map) }})"
            );
        }
        let ctor_params = self.constructor_field_names(&message_creation.type_name);
        let mut inserts = String::new();
        // Which instance fields are explicitly supplied (by real name, after the
        // positional `argN` → parameter-name remap)? Fields *not* supplied get
        // their class's field-level default initializer (`_bindings = {}`, …)
        // so a constructed instance matches Dart's field-initialization
        // semantics rather than leaving every unset field `Null` (issue #300 —
        // e.g. `_Scope(parent)` must still get its `_bindings = {}`).
        let mut explicit_fields: std::collections::HashSet<String> =
            std::collections::HashSet::new();
        for (index, field) in message_creation.fields.iter().enumerate() {
            let field_name = if type_emit::is_positional_arg_name(&field.name) {
                ctor_params
                    .get(index)
                    .map(|(name, _)| name.clone())
                    .unwrap_or_else(|| field.name.clone())
            } else {
                field.name.clone()
            };
            explicit_fields.insert(field_name);
        }
        // Prepend field-level defaults for any instance field the constructor
        // call does not itself set (only for a resolvable user class — a
        // Dart-SDK constructor like `List.filled`/`StringBuffer` has no
        // `TypeDefinition` and is left to its explicit fields / the runtime).
        if let Some(td) = self.type_def_for(&message_creation.type_name) {
            for field in self.all_instance_field_names(td) {
                if explicit_fields.contains(&field) {
                    continue;
                }
                if let Some(default) = self
                    .field_initializer_text(td, &field)
                    .and_then(|init| self.lower_field_initializer(&init, &mut Vec::new()))
                {
                    inserts.push_str(&format!(
                        "__ball_map.insert({field:?}.to_string(), {default});\n"
                    ));
                }
            }
        }
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
            // A typed instance is a reference-semantic `BallMessage` (issue
            // #298) — construct via `BallMessage::new`, which wraps the fields
            // in the shared `Arc<Mutex>` handle (the struct's `fields` are
            // private).
            format!(
                "{{ let mut __ball_map = BallMap::new(); {inserts}BallValue::Message(BallMessage::new({:?}, __ball_map)) }}",
                message_creation.type_name
            )
        }
    }

    /// A Dart-SDK collection constructor → the native `BallValue` collection
    /// (issue #300). `LinkedHashMap()`/`HashMap()` are empty ordered maps;
    /// `Map.from(x)`/`Map.of(x)` copy `x`; `HashSet()`/… are empty (List-backed)
    /// sets; `Set.from(x)` dedups `x`. Returns `None` for any non-SDK-collection
    /// `type_name` (built normally). `BallMap`/`BallList`/… are *user* classes
    /// (they have a `TypeDefinition`) and are left alone.
    fn sdk_collection_creation(&self, mc: &MessageCreation) -> Option<String> {
        let short = type_emit::type_short_name(&mc.type_name);
        let arg0 = || {
            mc.fields
                .iter()
                .find(|f| f.name == "arg0")
                .and_then(|f| f.value.as_ref())
                .map(|v| self.compile_expression(v))
                .unwrap_or_else(|| "BallValue::Null".to_string())
        };
        let arg1 = || {
            mc.fields
                .iter()
                .find(|f| f.name == "arg1")
                .and_then(|f| f.value.as_ref())
                .map(|v| self.compile_expression(v))
                .unwrap_or_else(|| "BallValue::Null".to_string())
        };
        // `BallMap`/`BallList` are the engine's own value-wrapper classes — used
        // pervasively but *not* encoded as `TypeDefinition`s (they live in
        // `ball_value.dart`, outside the self-host part graph), so a `BallMap(x)`
        // otherwise builds an opaque `{arg0: x}` shell with a null `entries`
        // (issue #300). They are thin wrappers over a native `Map`/`List`, so
        // build that directly — `has_arg0` distinguishes `BallMap(x)` (wrap `x`)
        // from `BallMap()` (empty).
        let has_arg0 = || mc.fields.iter().any(|f| f.name == "arg0");
        match short {
            "LinkedHashMap" | "HashMap" | "SplayTreeMap" => {
                Some("BallValue::Map(BallMap::new())".to_string())
            }
            "Map.from" | "Map.of" | "LinkedHashMap.from" | "HashMap.from" => Some(format!(
                "ball_map_merge(BallValue::Map(BallMap::new()), {})",
                arg0()
            )),
            "BallMap" => Some(if has_arg0() {
                format!("ball_map_merge(BallValue::Map(BallMap::new()), {})", arg0())
            } else {
                "BallValue::Map(BallMap::new())".to_string()
            }),
            "HashSet" | "LinkedHashSet" | "SplayTreeSet" => {
                Some("BallValue::List(BallList::new())".to_string())
            }
            "Set.from" | "Set.of" | "HashSet.from" | "LinkedHashSet.from" => {
                Some(format!("ball_set_create({})", arg0()))
            }
            "BallList" => Some(if has_arg0() {
                format!("ball_list_to_list({})", arg0())
            } else {
                "BallValue::List(BallList::new())".to_string()
            }),
            // Dart-SDK `List.filled(n, v)`. The engine's own `_stdListFilled`
            // handler returns `List<Object?>.filled(n, v)` in its body, which the
            // encoder emits as a typed `List.filled` message-creation; without
            // routing it the self-host built an opaque `BallMessage("List.filled",
            // …)` that `for_in`/`.length` rejected ("value is not iterable
            // (List.filled)") — issues #39/#300, fixtures 187/198. Route it to the
            // `filled` runtime helper (an `n`-length list of `v`).
            "List.filled" => Some(format!(
                "filled({{ let mut __ball_map = BallMap::new(); \
                 __ball_map.insert(\"arg0\".to_string(), {}); \
                 __ball_map.insert(\"arg1\".to_string(), {}); \
                 BallValue::Map(__ball_map) }})",
                arg0(),
                arg1()
            )),
            _ => None,
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
        // A `block` is its own lexical scope: its `let` bindings shadow outer
        // ones and are invisible after it. Each binding becomes a local
        // *after* its value is compiled (so `let x = x;` reads the outer `x`),
        // visible to every later statement and the tail — this is what lets a
        // `let bound = <lambda>;` then `bound(input)` route through dynamic
        // dispatch (issue #39, gap #6).
        //
        // **Cascade blocks (issue #300):** the encoder desugars `x..a()..b()`
        // into a block whose first `let` (`__cascade_self__ = x`, tagged
        // `metadata.kind = "cascade"`) is followed by the cascade operations
        // and returns the cascade var. On a **value-semantic** collection a
        // mutating cascade method (`..clear()..addAll(f)`) returns the mutated
        // copy but cannot mutate the receiver in place, so each such call must
        // *reassign* the cascade var, and the accumulated value is written back
        // to the receiver (a simple variable/field) at the block's end — see
        // [`Compiler::block_cascade_receiver`].
        let cascade_var = block.statements.first().and_then(cascade_let_var);
        self.push_scope();
        let mut out = String::from("{\n");
        for (index, statement) in block.statements.iter().enumerate() {
            match &statement.stmt {
                Some(Stmt::Let(let_binding)) => {
                    let name = sanitize_ident(&let_binding.name);
                    let value = match &let_binding.value {
                        Some(value) => self.compile_expression(value),
                        None => "BallValue::Null".to_string(),
                    };
                    self.bind_local(&let_binding.name);
                    // `mut` only when the rest of the block actually reassigns
                    // this binding (e.g. an `assign`-wrapped mutating cascade
                    // method `..clear()`/`..addAll()` whose target is a simple
                    // var). A cascade var is no longer blanket-reassigned to each
                    // op's result (see the cascade-op handling above), so a
                    // cascade whose ops only mutate the shared backing in place
                    // (`..remove()`) needs no `mut`.
                    let mutated = self.rest_mutates_var(
                        &block.statements[index + 1..],
                        block.result.as_deref(),
                        &let_binding.name,
                    );
                    let keyword = if mutated { "let mut" } else { "let" };
                    out.push_str(&format!("{keyword} {name} = {value};\n"));
                }
                Some(Stmt::Expression(expression)) => {
                    let compiled = self.compile_expression(expression);
                    // A cascade operation is evaluated purely for its side
                    // effect: Dart's `x..m()` always evaluates to the *receiver*
                    // `x`, discarding `m()`'s return. With reference-semantic
                    // collections (the #39/#300 List/Map reshape) a mutating
                    // method (`..clear()`/`..addAll()`/`..sort()`/`..remove()`)
                    // mutates the shared backing in place, so the cascade var
                    // must NOT be reassigned to the call's result. The former
                    // `cv = <call>` (a value-semantic-era workaround) corrupted
                    // `cv` for any method that returns something other than the
                    // receiver — e.g. `Map.from(x)..remove('self')`, where
                    // `remove` returns the *removed value*, so `argInput` became
                    // the removed object and `List.generate`'s generator read
                    // back `Null` ("generator is not callable", #39/#300).
                    out.push_str(&compiled);
                    out.push_str(";\n");
                }
                None => {}
            }
        }
        // Cascade write-back: persist the accumulated value onto the receiver
        // (only a simple in-scope variable/field — the overwhelmingly common
        // `entries..…` / `list..…` shape; a complex receiver is left as-is,
        // the documented boundary).
        if let (Some(cv), Some(receiver)) = (&cascade_var, self.block_cascade_receiver(block)) {
            if receiver != *cv {
                out.push_str(&format!("{receiver} = {cv}.clone();\n"));
            }
        }
        let tail = match &block.result {
            Some(result) => self.compile_expression(result),
            None => "BallValue::Null".to_string(),
        };
        out.push_str(&tail);
        out.push_str("\n}");
        self.pop_scope();
        out
    }

    /// The sanitized name of a cascade block's **receiver** (`entries` in
    /// `entries..clear()..addAll(f)`) when it is a simple reference — the
    /// write-back target (issue #300). `None` for a non-cascade block or a
    /// complex receiver expression.
    pub(crate) fn block_cascade_receiver(&self, block: &Block) -> Option<String> {
        let first = block.statements.first()?;
        let Some(Stmt::Let(let_binding)) = &first.stmt else {
            return None;
        };
        if !type_emit::let_is_cascade(let_binding) {
            return None;
        }
        match let_binding.value.as_ref().and_then(|v| v.expr.as_ref()) {
            Some(Expr::Reference(reference)) => Some(sanitize_ident(&reference.name)),
            _ => None,
        }
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
        // Free variables the lambda captures from the enclosing scope: names
        // referenced in the body that are enclosing locals (computed *before*
        // pushing the lambda's own frame, and excluding `input` — the
        // lambda's own parameter). A `move` closure would otherwise *move*
        // each captured local out of the surrounding function (`BallValue` is
        // not `Copy`), making it unavailable afterward — `error[E0382]` "use
        // of moved value" — which the self-hosted engine hits when it builds a
        // per-method closure capturing `func`/`module` and then keeps
        // iterating with them. Pre-clone each captured local into a fresh
        // binding the `move` closure owns, leaving the caller's original
        // intact (the same trick a hand-written Rust closure uses:
        // `{ let func = func.clone(); move || … func … }`).
        let mut referenced = HashSet::new();
        if let Some(body) = &lambda.body {
            self.collect_referenced_names(body, &mut referenced);
        }
        let mut captured: Vec<String> = referenced
            .into_iter()
            .filter(|name| name != "input" && self.is_local(name))
            .collect();
        captured.sort();

        self.push_scope();
        // Record where this lambda's own bindings begin, so instance-field
        // references inside the body resolve late-bound through `__self_recv`
        // unless a lambda-local shadows them (see `late_bound_field`).
        self.lambda_scope_floors
            .borrow_mut()
            .push(self.local_scopes.borrow().len() - 1);
        self.bind_local("input");
        let prologue = self.param_alias_prologue(lambda);
        let body = match &lambda.body {
            Some(body) => self.compile_expression(body),
            None => "BallValue::Null".to_string(),
        };
        self.lambda_scope_floors.borrow_mut().pop();
        self.pop_scope();

        // A lambda is a first-class function *value*: wrap the compiled `move`
        // closure in a `BallValue::Function` so it can be stored in a
        // scope/map, returned, passed as a callback, or compared `is Function`
        // — and later invoked uniformly via `ball_call_function` (issue #39,
        // gap #6). The closure is `Send + Sync + 'static` (it captures owned,
        // already-`.clone()`d `BallValue`s), which `BallFunction`'s `Arc<dyn
        // Fn … + Send + Sync>` requires — keeping `BallValue` `Send` so
        // `ball_throw`'s `panic_any` still type-checks.
        //
        // A captured variable the body **mutates** (`(_) => _nextMutexId++` —
        // the engine's ID counters) makes the `move` closure `FnMut`, not `Fn`:
        // its pre-clone must be `let mut`, and the value wraps via
        // `BallFunction::new_mut` (an interior-`Mutex` `FnMut` adapter) rather
        // than the lighter `Fn` `BallFunction::new` (issue #300).
        let mutated_captures: HashSet<String> = match &lambda.body {
            Some(body) => captured
                .iter()
                .filter(|var| self.expr_mutates_var(body, var))
                .cloned()
                .collect(),
            None => HashSet::new(),
        };
        let ctor = if mutated_captures.is_empty() {
            "BallFunction::new"
        } else {
            "BallFunction::new_mut"
        };
        let name = &lambda.name;
        let closure = format!(
            "BallValue::Function({ctor}({name:?}, move |input: BallValue| -> BallValue {{\n{prologue}{body}\n}}))"
        );
        if captured.is_empty() {
            closure
        } else {
            let preclones: String = captured
                .iter()
                .map(|var| {
                    let ident = sanitize_ident(var);
                    let keyword = if mutated_captures.contains(var) {
                        "let mut"
                    } else {
                        "let"
                    };
                    format!("{keyword} {ident} = {ident}.clone();\n")
                })
                .collect();
            format!("{{\n{preclones}{closure}\n}}")
        }
    }

    /// Collect every identifier *referenced* anywhere in `expr` (reference
    /// reads and call callees, recursing through the whole expression tree)
    /// into `out`. Over-approximates a lambda's free variables for
    /// [`Compiler::compile_lambda`]'s capture pre-cloning: it may include a
    /// name that a nested binding shadows, but the caller keeps only names
    /// that are enclosing locals, and an over-cloned (unused) pre-clone is
    /// harmless (`#![allow(unused_variables)]`). Call callees are included
    /// because a captured function *value* (`op`/`predicate`) is invoked, not
    /// read, so it appears only as a `call.function`, never a `reference`.
    fn collect_referenced_names(&self, expr: &Expression, out: &mut HashSet<String>) {
        match &expr.expr {
            Some(Expr::Reference(reference)) => {
                out.insert(reference.name.clone());
                // A lambda-body reference to an **instance field** compiles to
                // a late-bound `ball_field_get(__self_recv, …)` (see
                // `late_bound_field`), so the closure captures — and must
                // pre-clone — the receiver local. The capture filter keeps
                // `__self_recv` only when it is actually an in-scope local
                // (i.e. the lambda is inside an instance member), so this is
                // harmless for a free function's lambda.
                if self.is_instance_field(&reference.name) {
                    out.insert("__self_recv".to_string());
                }
            }
            Some(Expr::Call(call)) => {
                out.insert(call.function.clone());
                // An implicit-`this` call inside a lambda body injects
                // `__self_recv` (issue #298), so the lambda captures — and must
                // therefore pre-clone — that receiver local (else the `move`
                // closure moves the enclosing `__self_recv` out, E0382). Mark it
                // referenced when the callee names an instance method with no
                // explicit receiver; the capture filter only keeps it when
                // `__self_recv` is actually an in-scope local (i.e. the lambda
                // is inside an instance method), so this is harmless otherwise.
                if self
                    .instance_method_names
                    .contains(&sanitize_ident(&call.function))
                    && !Self::call_input_has_explicit_self(call)
                {
                    out.insert("__self_recv".to_string());
                }
                if let Some(input) = call.input.as_deref() {
                    self.collect_referenced_names(input, out);
                }
            }
            Some(Expr::FieldAccess(field_access)) => {
                if let Some(object) = field_access.object.as_deref() {
                    self.collect_referenced_names(object, out);
                }
            }
            Some(Expr::MessageCreation(message_creation)) => {
                for field in &message_creation.fields {
                    if let Some(value) = &field.value {
                        self.collect_referenced_names(value, out);
                    }
                }
            }
            Some(Expr::Block(block)) => {
                for statement in &block.statements {
                    match &statement.stmt {
                        Some(Stmt::Let(let_binding)) => {
                            if let Some(value) = &let_binding.value {
                                self.collect_referenced_names(value, out);
                            }
                        }
                        Some(Stmt::Expression(expression)) => {
                            self.collect_referenced_names(expression, out);
                        }
                        None => {}
                    }
                }
                if let Some(result) = block.result.as_deref() {
                    self.collect_referenced_names(result, out);
                }
            }
            Some(Expr::Lambda(inner)) => {
                if let Some(body) = inner.body.as_deref() {
                    self.collect_referenced_names(body, out);
                }
            }
            Some(Expr::Literal(literal)) => {
                if let Some(LiteralValue::ListValue(list)) = &literal.value {
                    for element in &list.elements {
                        self.collect_referenced_names(element, out);
                    }
                }
            }
            None => {}
        }
    }
}

/// Format a `double` literal for embedding in generated Rust source (a
/// syntactically valid Rust `f64` expression, not stdout formatting — see
/// `ball_lang_shared::value::format_double` for *that*, used at run time by the
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
/// The sanitized cascade-var name if `statement` is a cascade `let`
/// (`let __cascade_self__ = <receiver>`, tagged `metadata.kind = "cascade"`),
/// else `None`. See [`Compiler::compile_block`] (issue #300).
fn cascade_let_var(statement: &ball_lang_shared::proto::ball::v1::Statement) -> Option<String> {
    match &statement.stmt {
        Some(Stmt::Let(let_binding)) if type_emit::let_is_cascade(let_binding) => {
            Some(sanitize_ident(&let_binding.name))
        }
        _ => None,
    }
}

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
    use ball_lang_shared::proto::ball::v1::{
        FieldValuePair, FunctionCall, ListLiteral, Literal as LiteralMsg, Module,
    };
    use ball_lang_shared::proto::google::protobuf::value::Kind;
    use ball_lang_shared::proto::google::protobuf::{ListValue, Struct, Value};

    fn program_with_std() -> Program {
        Program {
            name: "test".to_string(),
            version: "1.0.0".to_string(),
            modules: vec![ball_lang_shared::build_std_module()],
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
            "BallValue::List(BallList::from(vec![BallValue::Int(1i64), BallValue::Int(2i64)]))"
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

    // ── reference: __no_init__ sentinel (issue #39) ──────────
    #[test]
    fn no_init_sentinel_reference_compiles_to_null() {
        // `int? maybe;` encodes the uninitialized declaration's value as a
        // `reference{name: "__no_init__"}`; it must lower to `BallValue::Null`
        // (the value a read of the still-unassigned variable yields), not to
        // an unresolved `__no_init__.clone()`.
        let program = program_with_std();
        let compiler = Compiler::new(&program);
        assert_eq!(
            compiler.compile_expression(&reference("__no_init__")),
            "BallValue::Null"
        );
        // A `let x = __no_init__;` binding inside a block therefore compiles
        // to a valid, self-contained Rust `let`.
        let block = Block {
            statements: vec![ball_lang_shared::proto::ball::v1::Statement {
                stmt: Some(Stmt::Let(ball_lang_shared::proto::ball::v1::LetBinding {
                    name: "maybe".to_string(),
                    value: Some(reference("__no_init__")),
                    metadata: None,
                })),
            }],
            result: Some(Box::new(reference("maybe"))),
        };
        let compiled = compiler.compile_expression(&Expression {
            expr: Some(Expr::Block(Box::new(block))),
        });
        assert!(compiled.contains("let maybe = BallValue::Null;"));
        assert!(!compiled.contains("__no_init__"));
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
        assert!(compiled.contains("BallValue::Message(BallMessage::new(\"Point\","));
    }

    // ── block ────────────────────────────────────────────────
    #[test]
    fn compiles_block_with_let_bindings_and_result() {
        let program = program_with_std();
        let compiler = Compiler::new(&program);
        let block = Block {
            statements: vec![ball_lang_shared::proto::ball::v1::Statement {
                stmt: Some(Stmt::Let(ball_lang_shared::proto::ball::v1::LetBinding {
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
        // #39: a lambda is a first-class function *value* — the `move`
        // closure is wrapped in a `BallValue::Function` so it can flow as a
        // value and be invoked via `ball_call_function`.
        assert!(compiled.starts_with("BallValue::Function(BallFunction::new("));
    }

    // ── call ─────────────────────────────────────────────────
    /// A call whose callee names a **known** user function compiles to a
    /// direct Rust call. `fibonacci` must actually be declared in the
    /// program for it to be a known callable (issue #39) — otherwise the
    /// compiler treats the name as a first-class function *value* and routes
    /// it through `ball_call_function` (see
    /// [`compiles_function_value_call_via_dynamic_dispatch`]).
    #[test]
    fn compiles_user_function_call() {
        let mut program = program_with_std();
        program.modules.push(Module {
            name: "main".to_string(),
            functions: vec![FunctionDefinition {
                name: "fibonacci".to_string(),
                input_type: "int".to_string(),
                output_type: "int".to_string(),
                body: Some(Box::new(reference("input"))),
                description: String::new(),
                is_base: false,
                metadata: None,
            }],
            ..Default::default()
        });
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

    /// A call whose callee is a **local** binding (not a top-level function)
    /// is a call through a first-class function value and routes through the
    /// dynamic dispatcher `ball_call_function` — the self-hosted engine's
    /// `final bound = scope.lookup(name); bound(input)` shape (issue #39, gap
    /// #6). An unqualified callee that is *not* a local stays a direct call
    /// (a user function or a `ball_lang_shared::runtime` Dart-SDK helper), even
    /// when the same name is unknown to the compiler.
    #[test]
    fn compiles_function_value_call_via_dynamic_dispatch() {
        let program = program_with_std();
        let compiler = Compiler::new(&program);
        let call_bound = Expression {
            expr: Some(Expr::Call(Box::new(FunctionCall {
                module: String::new(),
                function: "bound".to_string(),
                input: Some(Box::new(int_lit(5))),
                type_args: vec![],
            }))),
        };
        // Not a local → direct call (an unknown top-level function / SDK
        // helper), unchanged from before #39.
        assert_eq!(
            compiler.compile_expression(&call_bound),
            "bound(BallValue::Int(5i64))"
        );
        // With `bound` a local binding in scope → dynamic dispatch.
        compiler.push_scope();
        compiler.bind_local("bound");
        assert_eq!(
            compiler.compile_expression(&call_bound),
            "ball_call_function(bound.clone(), BallValue::Int(5i64))"
        );
        compiler.pop_scope();
    }

    /// A bare reference (value position) to a top-level function wraps it as a
    /// `BallValue::Function` so the fn item can flow as a value (issue #39,
    /// gap #6) — but only when it is **not** shadowed by a local of the same
    /// name (the self-hosted engine binds locals that shadow their top-level
    /// namesakes; wrapping such a local — already a `BallValue` — would be a
    /// type error).
    #[test]
    fn reference_to_unshadowed_function_wraps_as_value_but_local_shadow_does_not() {
        let mut program = program_with_std();
        program.modules.push(Module {
            name: "main".to_string(),
            functions: vec![FunctionDefinition {
                name: "helper".to_string(),
                input_type: "int".to_string(),
                output_type: "int".to_string(),
                body: Some(Box::new(reference("input"))),
                description: String::new(),
                is_base: false,
                metadata: None,
            }],
            ..Default::default()
        });
        let compiler = Compiler::new(&program);
        // Unshadowed top-level function used as a value → wrapped.
        assert_eq!(
            compiler.compile_expression(&reference("helper")),
            "BallValue::Function(BallFunction::new(\"helper\", helper))"
        );
        // A plain (non-function) local → unchanged `.clone()`.
        assert_eq!(compiler.compile_expression(&reference("x")), "x.clone()");
        // A local shadowing the function name → treated as the local value,
        // NOT wrapped as a fn item.
        compiler.push_scope();
        compiler.bind_local("helper");
        assert_eq!(
            compiler.compile_expression(&reference("helper")),
            "helper.clone()"
        );
        compiler.pop_scope();
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
        assert!(compiled.contains(
            "use ball_lang_shared::{BallFunction, BallList, BallMap, BallMessage, BallValue};"
        ));
        assert!(compiled.contains("use ball_lang_shared::runtime::*;"));
        assert!(compiled.contains("fn main() {"));
        assert!(!compiled.contains("pub fn main(")); // entry fn is inlined, not emitted as a wrapper
    }

    // ── empty namespace module → runtime re-export (issue #39) ──
    #[test]
    fn empty_namespace_module_reexports_runtime() {
        // A module with no functions/types is a foreign-SDK namespace marker
        // (`dart_math`, `dart_io`) the engine calls into fully qualified
        // (`dart_math::sqrt(x)`). It must re-export the shared runtime so those
        // qualified calls resolve — a private `use super::*;` would not expose
        // the names as `dart_math::…` path members.
        let mut program = program_with_std();
        program.modules.push(Module {
            name: "dart_math".to_string(),
            ..Default::default()
        });
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
        assert!(
            compiled.contains("pub mod dart_math {\n    pub use ball_lang_shared::runtime::*;\n}"),
            "empty namespace module should re-export the runtime, got:\n{compiled}"
        );
    }
}
