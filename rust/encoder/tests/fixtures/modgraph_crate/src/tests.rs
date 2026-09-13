//! The `#[cfg(test)]` module `src/lib.rs` declares. It is never walked, so its
//! `assert!` — a macro the encoder has no mapping for, and therefore a loud
//! panic if it were ever encoded — is what proves the skip is real rather than
//! merely claimed.
#[test]
fn the_parts_add_up() {
    assert!(crate::total() == 10);
}
