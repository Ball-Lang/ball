//! `call` (base-function) compilation — the minimal Phase 2a bootstrap.
//!
//! See the crate-level scope-boundary note in `lib.rs`: this is
//! deliberately **not** the full `std`/`std_collections`/`std_io`/
//! `std_memory` dispatch table (118+ functions) — that is issue #37.
//! [`compile_base_call`] is the extension point #37 will grow; today it
//! wires up only the arithmetic/comparison/logical operators and the
//! `if`/`return` control-flow + `print`/`to_string` calls needed to compile
//! and run `hello_world`, `fibonacci`, `factorial`, and a closures fixture
//! (see `tests/end_to_end.rs`) end to end. Every other base function name
//! compiles to a `panic!(...)` that names the missing function and points
//! at #37, so a program that reaches an unimplemented base function fails
//! loudly at *run time* of the compiled binary — never silently drops a
//! computation (see CLAUDE.md's engine guidance: "Fail loud... never return
//! a placeholder").
use indexmap::IndexMap;

use ball_shared::extract_fields;
use ball_shared::proto::ball::v1::{Expression, FunctionCall};

use crate::Compiler;

impl Compiler<'_> {
    /// `call` — the shared entry point for both node types folded under
    /// `Expression::Call`: a base-module call (dispatches to
    /// [`compile_base_call`]) or a user-module call. A user call always
    /// compiles to plain Rust call syntax `<function>(<input>)`; per Ball's
    /// "one input, one output" convention (invariant #1) there is exactly
    /// one argument, so no argument-list flattening is needed. Because Rust
    /// calls a closure-typed local with the exact same syntax as a function
    /// item, this same path transparently supports calling a `lambda`
    /// that's been `let`-bound in the enclosing scope (Rust's own name
    /// resolution prefers the local shadow, matching Ball's dynamic
    /// lexical scoping) — see `tests/end_to_end.rs`'s closures fixture.
    /// `call.module` empty means "current module" (resolves the same way:
    /// a bare Rust identifier call).
    pub(crate) fn compile_call(&self, call: &FunctionCall) -> String {
        if self.is_base_module(&call.module) {
            return self.compile_base_call(call);
        }
        let name = crate::sanitize_ident(&call.function);
        let input = match &call.input {
            Some(input) => self.compile_expression(input),
            None => "BallValue::Null".to_string(),
        };
        format!("{name}({input})")
    }

    /// `call` (base fn) — dispatch table. See the module doc comment for
    /// the scope boundary: only a minimal bootstrap subset is implemented
    /// here; everything else panics with a message naming both the missing
    /// function and issue #37.
    fn compile_base_call(&self, call: &FunctionCall) -> String {
        let fields = extract_fields(call);
        match call.function.as_str() {
            "print" => self.compile_print(&fields),
            "to_string" => self.compile_to_string(&fields),
            "add" => self.bin_op(&fields, "ball_add"),
            "subtract" => self.bin_op(&fields, "ball_subtract"),
            "multiply" => self.bin_op(&fields, "ball_multiply"),
            "divide" => self.bin_op(&fields, "ball_divide"),
            "modulo" => self.bin_op(&fields, "ball_modulo"),
            "equals" => self.bin_op(&fields, "ball_equals"),
            "not_equals" => self.bin_op(&fields, "ball_not_equals"),
            "less_than" => self.bin_op(&fields, "ball_less_than"),
            "greater_than" => self.bin_op(&fields, "ball_greater_than"),
            "lte" => self.bin_op(&fields, "ball_lte"),
            "gte" => self.bin_op(&fields, "ball_gte"),
            "and" => self.bin_op(&fields, "ball_and"),
            "or" => self.bin_op(&fields, "ball_or"),
            "not" => self.un_op(&fields, "ball_not"),
            "negate" => self.un_op(&fields, "ball_negate"),
            "if" => self.compile_if(&fields),
            "return" => self.compile_return(&fields),
            other => format!(
                "panic!(\"ball-compiler: base function 'std.{other}' is not implemented yet \
                 — full base-function dispatch lands in issue #37\")"
            ),
        }
    }

    fn field_or_null(&self, fields: &IndexMap<String, Expression>, key: &str) -> String {
        match fields.get(key) {
            Some(expr) => self.compile_expression(expr),
            None => "BallValue::Null".to_string(),
        }
    }

    fn bin_op(&self, fields: &IndexMap<String, Expression>, helper: &str) -> String {
        let left = self.field_or_null(fields, "left");
        let right = self.field_or_null(fields, "right");
        format!("{helper}({left}, {right})")
    }

    fn un_op(&self, fields: &IndexMap<String, Expression>, helper: &str) -> String {
        let value = self.field_or_null(fields, "value");
        format!("{helper}({value})")
    }

    /// `print(message)` — always compiles to a `BallValue`-typed block
    /// (this crate's uniform invariant, see the `lib.rs` module doc
    /// comment): the `println!` runs for its side effect and the block's
    /// value is `BallValue::Null`, matching every reference engine's
    /// `print` returning `null`.
    fn compile_print(&self, fields: &IndexMap<String, Expression>) -> String {
        let message = self.field_or_null(fields, "message");
        format!("{{ println!(\"{{}}\", {message}); BallValue::Null }}")
    }

    /// `to_string(value)` — delegates to `BallValue`'s own `Display` impl
    /// (`rust/shared/src/value.rs`), which already matches every reference
    /// engine's stdout formatting (including the `-0.0`/whole-double/NaN
    /// special cases), so this is a single, always-correct helper rather
    /// than a per-type dispatch.
    fn compile_to_string(&self, fields: &IndexMap<String, Expression>) -> String {
        let value = self.field_or_null(fields, "value");
        format!("BallValue::String(format!(\"{{}}\", {value}))")
    }

    /// `if(condition, then, else?)` — lazy by construction: both branches
    /// are Rust `if`/`else` arms, so only the taken branch's compiled code
    /// ever executes (invariant #4 — never eagerly evaluate both branches).
    /// `condition` is unwrapped from `BallValue::Bool` via the
    /// [`BASE_OPS_PREAMBLE`] `ball_truthy` helper. `then`'s compiled value
    /// commonly diverges via `return` (see [`compile_return`]) — a
    /// diverging (`!`-typed) branch unifies with whatever type the other
    /// branch produces, so `then`/`else` don't need to independently agree
    /// on a concrete type in that case.
    fn compile_if(&self, fields: &IndexMap<String, Expression>) -> String {
        let condition = self.field_or_null(fields, "condition");
        let then = self.field_or_null(fields, "then");
        let else_branch = self.field_or_null(fields, "else");
        format!("if ball_truthy({condition}) {{ {then} }} else {{ {else_branch} }}")
    }

    /// `return(value)` — a real Rust `return`, giving genuine early-return
    /// control flow rather than a simulated flow-signal value (unlike the
    /// tree-walking engines, a compiled Rust function can use the host
    /// language's own control flow directly).
    fn compile_return(&self, fields: &IndexMap<String, Expression>) -> String {
        let value = self.field_or_null(fields, "value");
        format!("return {value}")
    }
}

/// The Phase 2a bootstrap runtime: free functions the compiled output calls
/// into for [`Compiler::compile_base_call`]'s minimal dispatch subset, plus
/// [`compile_field_access`](Compiler::compile_field_access)'s
/// `ball_field_get`. Emitted once, verbatim, at the top of every
/// `Compiler::compile()` output. **Not** the full base-function runtime —
/// see the module doc comment.
pub const BASE_OPS_PREAMBLE: &str = r#"// ── Minimal base-function runtime (Phase 2a bootstrap, issue #36) ──────
// NOT the full `std` dispatch table — see ball-compiler's crate docs and
// `base_call.rs`. Issue #37 supersedes this with the full 118-function
// dispatch (string/math/collection ops, bitwise, type ops, loops, try,
// switch, ...).
fn ball_truthy(value: BallValue) -> bool {
    match value {
        BallValue::Bool(b) => b,
        other => panic!("ball-compiler runtime: expected a bool condition, got {:?}", other),
    }
}
fn ball_field_get(value: BallValue, field: &str) -> BallValue {
    match value {
        BallValue::Map(map) => map.get(field).cloned().unwrap_or(BallValue::Null),
        BallValue::Message(message) => message.fields.get(field).cloned().unwrap_or(BallValue::Null),
        other => panic!("ball-compiler runtime: field access on a non-message value: {:?}", other),
    }
}
fn ball_add(left: BallValue, right: BallValue) -> BallValue {
    match (left, right) {
        (BallValue::Int(a), BallValue::Int(b)) => BallValue::Int(a + b),
        (BallValue::Double(a), BallValue::Double(b)) => BallValue::Double(a + b),
        (BallValue::String(a), BallValue::String(b)) => BallValue::String(a + &b),
        (a, b) => panic!("ball-compiler runtime: unsupported operands for add: {:?}, {:?}", a, b),
    }
}
fn ball_subtract(left: BallValue, right: BallValue) -> BallValue {
    match (left, right) {
        (BallValue::Int(a), BallValue::Int(b)) => BallValue::Int(a - b),
        (BallValue::Double(a), BallValue::Double(b)) => BallValue::Double(a - b),
        (a, b) => panic!("ball-compiler runtime: unsupported operands for subtract: {:?}, {:?}", a, b),
    }
}
fn ball_multiply(left: BallValue, right: BallValue) -> BallValue {
    match (left, right) {
        (BallValue::Int(a), BallValue::Int(b)) => BallValue::Int(a * b),
        (BallValue::Double(a), BallValue::Double(b)) => BallValue::Double(a * b),
        (a, b) => panic!("ball-compiler runtime: unsupported operands for multiply: {:?}, {:?}", a, b),
    }
}
fn ball_divide(left: BallValue, right: BallValue) -> BallValue {
    match (left, right) {
        (BallValue::Int(a), BallValue::Int(b)) => BallValue::Int(a / b),
        (BallValue::Double(a), BallValue::Double(b)) => BallValue::Double(a / b),
        (a, b) => panic!("ball-compiler runtime: unsupported operands for divide: {:?}, {:?}", a, b),
    }
}
fn ball_modulo(left: BallValue, right: BallValue) -> BallValue {
    match (left, right) {
        (BallValue::Int(a), BallValue::Int(b)) => BallValue::Int(a % b),
        (BallValue::Double(a), BallValue::Double(b)) => BallValue::Double(a % b),
        (a, b) => panic!("ball-compiler runtime: unsupported operands for modulo: {:?}, {:?}", a, b),
    }
}
fn ball_negate(value: BallValue) -> BallValue {
    match value {
        BallValue::Int(a) => BallValue::Int(-a),
        BallValue::Double(a) => BallValue::Double(-a),
        other => panic!("ball-compiler runtime: unsupported operand for negate: {:?}", other),
    }
}
fn ball_equals(left: BallValue, right: BallValue) -> BallValue {
    BallValue::Bool(left == right)
}
fn ball_not_equals(left: BallValue, right: BallValue) -> BallValue {
    BallValue::Bool(left != right)
}
fn ball_less_than(left: BallValue, right: BallValue) -> BallValue {
    match (left, right) {
        (BallValue::Int(a), BallValue::Int(b)) => BallValue::Bool(a < b),
        (BallValue::Double(a), BallValue::Double(b)) => BallValue::Bool(a < b),
        (a, b) => panic!("ball-compiler runtime: unsupported operands for less_than: {:?}, {:?}", a, b),
    }
}
fn ball_greater_than(left: BallValue, right: BallValue) -> BallValue {
    match (left, right) {
        (BallValue::Int(a), BallValue::Int(b)) => BallValue::Bool(a > b),
        (BallValue::Double(a), BallValue::Double(b)) => BallValue::Bool(a > b),
        (a, b) => panic!("ball-compiler runtime: unsupported operands for greater_than: {:?}, {:?}", a, b),
    }
}
fn ball_lte(left: BallValue, right: BallValue) -> BallValue {
    match (left, right) {
        (BallValue::Int(a), BallValue::Int(b)) => BallValue::Bool(a <= b),
        (BallValue::Double(a), BallValue::Double(b)) => BallValue::Bool(a <= b),
        (a, b) => panic!("ball-compiler runtime: unsupported operands for lte: {:?}, {:?}", a, b),
    }
}
fn ball_gte(left: BallValue, right: BallValue) -> BallValue {
    match (left, right) {
        (BallValue::Int(a), BallValue::Int(b)) => BallValue::Bool(a >= b),
        (BallValue::Double(a), BallValue::Double(b)) => BallValue::Bool(a >= b),
        (a, b) => panic!("ball-compiler runtime: unsupported operands for gte: {:?}, {:?}", a, b),
    }
}
fn ball_and(left: BallValue, right: BallValue) -> BallValue {
    match (left, right) {
        (BallValue::Bool(a), BallValue::Bool(b)) => BallValue::Bool(a && b),
        (a, b) => panic!("ball-compiler runtime: unsupported operands for and: {:?}, {:?}", a, b),
    }
}
fn ball_or(left: BallValue, right: BallValue) -> BallValue {
    match (left, right) {
        (BallValue::Bool(a), BallValue::Bool(b)) => BallValue::Bool(a || b),
        (a, b) => panic!("ball-compiler runtime: unsupported operands for or: {:?}, {:?}", a, b),
    }
}
fn ball_not(value: BallValue) -> BallValue {
    match value {
        BallValue::Bool(a) => BallValue::Bool(!a),
        other => panic!("ball-compiler runtime: unsupported operand for not: {:?}", other),
    }
}
"#;
