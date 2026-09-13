//! Crate root of the three-file fixture: it declares the other two modules and
//! reaches into BOTH of the shapes a single-file encode cannot resolve.
mod counter;
mod text;

use counter::Counter;
use text::describe;

fn main() {
    let c = Counter::new(2);
    // `receiver.method(args)` whose method is declared in ANOTHER file — the
    // 24-of-196-file bucket of issue #491.
    let total = c.bump(3);
    // A free function declared in a THIRD file, called by its bare name
    // through a `use` — no module-qualifying path segment for a syntax-only
    // encoder to read the callee's home module off.
    println!("{}", describe(total));
}
