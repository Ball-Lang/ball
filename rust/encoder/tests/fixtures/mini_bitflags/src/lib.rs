//! A `bitflags!`-shaped exported `macro_rules!`, reduced to what the Ball
//! encoder can be held to today.
//!
//! The point is the MACRO FEATURES, not the semantics: this exercises an
//! outer `$(#[$outer:meta])*` repetition, a `$vis:vis` fragment, a nested
//! repetition with its own `$(#[$inner:meta])*` meta capture, `$expr`
//! fragments, doc comments (which `proc_macro2` lexes into `#[doc = "…"]`
//! tokens), and a repetition used in EXPRESSION position (`$(+ $value)*`).
//! Its expansion is deliberately plain, already-encodable Rust — a named
//! struct plus an inherent `impl` — so a failure in this fixture is a failure
//! of macro expansion and never of some unrelated encoder gap.

/// Declare a flags-style struct: one `bits` field plus one accessor per
/// declared flag, and a `sum_bits` total.
#[macro_export]
macro_rules! flags {
    (
        $(#[$outer:meta])*
        $vis:vis struct $name:ident {
            $(
                $(#[$inner:meta])*
                $flag:ident = $value:expr;
            )*
        }
    ) => {
        $(#[$outer])*
        $vis struct $name {
            pub bits: i64,
        }

        impl $name {
            $(
                $(#[$inner])*
                $vis fn $flag(&self) -> i64 {
                    $value
                }
            )*

            /// The raw bits plus every declared flag's value.
            $vis fn sum_bits(&self) -> i64 {
                self.bits $(+ $value)*
            }
        }
    };
}
