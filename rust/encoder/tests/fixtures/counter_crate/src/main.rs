//! Crate root of the four-file fixture: it declares the other three modules
//! and reaches into BOTH of the shapes a single-file encode cannot resolve,
//! plus the `#[cfg(not(test))]` module issue #626's predicate bug dropped.
mod counter;
mod text;

/// `cargo build` compiles this module — `not(test)` is true for every ordinary
/// build — so the walk must too. Issue #626: the old predicate found the bare
/// `test` ident under the `not(...)` and silently skipped the module.
#[cfg(not(test))]
mod live;

use counter::Counter;
use text::describe;

fn main() {
    let c = Counter::new(2);
    // `receiver.method(args)` whose method is declared in ANOTHER file — the
    // 24-of-196-file bucket of issue #491.
    let total = c.bump(3);
    // A free function declared in a THIRD file, called by its bare name
    // through a `use` — no module-qualifying path segment for a syntax-only
    // encoder to read the callee's home module off. Its result is then passed
    // through the `#[cfg(not(test))]` module, so a dropped `live` cannot pass
    // this fixture: the generated program would not even compile.
    println!("{}", live::stamp(describe(total)));
}
