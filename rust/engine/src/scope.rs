//! Lexical scope chain and flow signals (issue #39).
//!
//! These are the two runtime mechanisms a tree-walking Ball engine needs that
//! compiled Ball code cannot express natively (see
//! `.claude/skills/new-ball-language/SKILL.md` Phase 4, Option A's component
//! list, and `dart/engine/lib/` — the reference engine's `Scope` + `FlowSignal`):
//!
//! - [`Scope`] — a lexical environment with a parent link. `lookup` walks the
//!   parent chain outward (inner bindings shadow outer ones); `bind` declares
//!   in the current scope; `set` finds-and-updates the nearest existing
//!   binding (falling back to the current scope). Closures capture a `Scope`
//!   handle, so a lambda keeps its defining environment alive — the standard
//!   Ball closure semantics the self-hosted engine's own `_Scope` class
//!   mirrors.
//! - [`FlowSignal`] — the non-local control-flow currency (`return`/`break`/
//!   `continue`/`throw`). A tree-walking evaluator propagates one of these up
//!   through nested expression evaluations until the matching construct
//!   (function boundary, loop, `try`) consumes it — exactly the `FlowSignal`
//!   pattern the Dart reference engine uses.
//!
//! The self-hosted engine (once `compiled_engine.rs` compiles — see the crate
//! doc comment) carries its *own* `_Scope`/exception model compiled from Ball,
//! so these are the wrapper's foundation for the hand-driven paths (CLI
//! entry, and the native base-function callbacks the compiled engine invokes)
//! rather than a second interpreter.

use std::cell::RefCell;
use std::rc::Rc;

use ball_lang_shared::{BallMap, BallValue};

/// A shared handle to a lexical scope. `Rc<RefCell<…>>` because a scope is
/// referenced by both its child scopes (via [`ScopeNode::parent`]) and any
/// closure that captured it, and its bindings mutate in place as the block
/// executes.
pub type Scope = Rc<RefCell<ScopeNode>>;

/// One frame of the lexical environment: this frame's own bindings plus an
/// optional link to the enclosing frame.
#[derive(Debug, Default)]
pub struct ScopeNode {
    bindings: BallMap,
    parent: Option<Scope>,
}

/// Create a fresh root [`Scope`] with no parent.
pub fn new_root_scope() -> Scope {
    Rc::new(RefCell::new(ScopeNode::default()))
}

/// Create a child [`Scope`] whose parent is `parent` (a new block/function/
/// lambda frame layered over its enclosing environment).
pub fn new_child_scope(parent: &Scope) -> Scope {
    Rc::new(RefCell::new(ScopeNode {
        bindings: BallMap::new(),
        parent: Some(Rc::clone(parent)),
    }))
}

/// Declare `name` = `value` in `scope`'s *own* frame (a `let`/parameter
/// binding; shadows any same-named binding in an enclosing frame).
pub fn bind(scope: &Scope, name: &str, value: BallValue) {
    scope.borrow_mut().bindings.insert(name.to_string(), value);
}

/// Look `name` up, walking outward from `scope` through the parent chain.
/// Returns the nearest (innermost) binding, or `None` if unbound anywhere.
pub fn lookup(scope: &Scope, name: &str) -> Option<BallValue> {
    let node = scope.borrow();
    if let Some(value) = node.bindings.get(name) {
        return Some(value.clone());
    }
    match &node.parent {
        Some(parent) => lookup(parent, name),
        None => None,
    }
}

/// Whether `name` is bound anywhere in `scope`'s chain.
pub fn has(scope: &Scope, name: &str) -> bool {
    lookup(scope, name).is_some()
}

/// Assign `name` = `value` into the *nearest existing* binding along the
/// chain (ordinary assignment to an already-declared variable, possibly in an
/// enclosing scope). Falls back to declaring in `scope`'s own frame when the
/// name is not bound anywhere — matching the reference engines' `set`, which
/// never silently drops a write.
pub fn set(scope: &Scope, name: &str, value: BallValue) {
    if set_existing(scope, name, &value) {
        return;
    }
    bind(scope, name, value);
}

fn set_existing(scope: &Scope, name: &str, value: &BallValue) -> bool {
    let node = scope.borrow_mut();
    if node.bindings.contains_key(name) {
        node.bindings.insert(name.to_string(), value.clone());
        return true;
    }
    match &node.parent {
        Some(parent) => set_existing(parent, name, value),
        None => false,
    }
}

/// The non-local control-flow currency of a tree-walking evaluator. An
/// evaluation step returns `Ok(value)` for an ordinary result or
/// `Err(FlowSignal)` to unwind to the construct that consumes the signal (the
/// function boundary for [`FlowSignal::Return`], the innermost/labeled loop for
/// [`FlowSignal::Break`]/[`FlowSignal::Continue`], the nearest `try` for
/// [`FlowSignal::Throw`]).
#[derive(Debug, Clone, PartialEq)]
pub enum FlowSignal {
    /// `return value;` — unwinds to the enclosing function boundary.
    Return(BallValue),
    /// `break [label];` — unwinds to the innermost (or labeled) loop.
    Break(Option<String>),
    /// `continue [label];` — restarts the innermost (or labeled) loop.
    Continue(Option<String>),
    /// `throw value;` — unwinds to the nearest `try`/`catch`.
    Throw(BallValue),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lookup_walks_parent_chain_and_inner_shadows_outer() {
        let root = new_root_scope();
        bind(&root, "x", BallValue::Int(1));
        bind(&root, "y", BallValue::Int(2));

        let child = new_child_scope(&root);
        bind(&child, "x", BallValue::Int(99)); // shadows root's x

        assert_eq!(lookup(&child, "x"), Some(BallValue::Int(99)));
        assert_eq!(lookup(&child, "y"), Some(BallValue::Int(2))); // from parent
        assert_eq!(lookup(&child, "z"), None);
        assert!(has(&child, "y"));
        assert!(!has(&child, "z"));
    }

    #[test]
    fn set_updates_nearest_existing_binding_in_enclosing_scope() {
        let root = new_root_scope();
        bind(&root, "counter", BallValue::Int(0));
        let child = new_child_scope(&root);

        // `set` from the child must update root's binding, not shadow it.
        set(&child, "counter", BallValue::Int(5));
        assert_eq!(lookup(&root, "counter"), Some(BallValue::Int(5)));
        // The child frame did not gain its own `counter`.
        assert!(!child.borrow().bindings.contains_key("counter"));
    }

    #[test]
    fn set_of_unbound_name_declares_in_current_scope() {
        let root = new_root_scope();
        let child = new_child_scope(&root);
        set(&child, "fresh", BallValue::String("v".into()));
        assert_eq!(lookup(&child, "fresh"), Some(BallValue::String("v".into())));
        assert_eq!(lookup(&root, "fresh"), None);
    }

    #[test]
    fn closures_capture_a_live_scope_handle() {
        // A captured scope keeps its environment alive and observes later
        // mutations — the property closures rely on.
        let root = new_root_scope();
        bind(&root, "captured", BallValue::Int(1));
        let captured = Rc::clone(&root);
        set(&root, "captured", BallValue::Int(42));
        assert_eq!(lookup(&captured, "captured"), Some(BallValue::Int(42)));
    }

    #[test]
    fn flow_signal_variants_are_comparable() {
        assert_eq!(
            FlowSignal::Return(BallValue::Int(3)),
            FlowSignal::Return(BallValue::Int(3))
        );
        assert_ne!(
            FlowSignal::Break(None),
            FlowSignal::Break(Some("outer".into()))
        );
    }
}
