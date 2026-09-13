//! A DEPENDENCY-defined `macro_rules!` at item position.
//!
//! `mini_bitflags::flags!` is reached by a two-segment path, so it resolves
//! through `cargo metadata` → the dependency's lib target → its
//! `#[macro_export] macro_rules!` items. Nothing about `bitflags` is
//! special-cased anywhere in the encoder; this fixture is only a stand-in for
//! the general dependency-macro path.

mini_bitflags::flags! {
    /// Permission bits.
    pub struct Perms {
        /// Read access.
        read_bit = 1;
        /// Write access.
        write_bit = 2;
    }
}

/// The fixture's cross-module callee: 4 raw bits + 1 + 2 == 7.
pub fn describe() -> i64 {
    let p = Perms { bits: 4 };
    p.sum_bits()
}
