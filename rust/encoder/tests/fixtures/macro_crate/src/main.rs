//! The macro-expansion fixture's crate root (issue #629).
//!
//! `make_point!` is a LOCAL `macro_rules!` — declared here, invoked here, at
//! item position — producing both a `struct` and an inherent `impl` for it.
//! That is the shape #629 names as the reason an item-level macro can never be
//! skipped: the macro is the thing that DEFINES the type the rest of the file
//! calls into.
//!
//! `flags` (see `flags.rs`) is the same story for a DEPENDENCY-defined macro.

mod flags;

/// Declare a point-like struct whose `total` sums every declared field.
///
/// Exercises, on purpose: an outer `$(#[$outer:meta])*` meta repetition, a
/// `$vis:vis` fragment, a repetition with a separator plus an optional
/// trailing one (`$($field:ident),* $(,)?`), the same repetition transcribed
/// into BOTH item position (the field list) and expression position
/// (`0 $(+ self.$field)*`), and a doc comment at the invocation site.
macro_rules! make_point {
    (
        $(#[$outer:meta])*
        $vis:vis struct $name:ident { $($field:ident),* $(,)? }
    ) => {
        $(#[$outer])*
        $vis struct $name {
            $(pub $field: i64,)*
        }

        impl $name {
            /// Every field, summed.
            $vis fn total(&self) -> i64 {
                0 $(+ self.$field)*
            }
        }
    };
}

make_point! {
    /// A 2-D point.
    pub struct Point { x, y }
}

fn main() {
    let p = Point { x: 20, y: 22 };
    println!("{}", p.total());
    println!("{}", flags::describe());
}
