//! `crate::counter` — resolved from `mod counter;` in the crate root as
//! `src/counter.rs` (Rust reference, "Module source filenames").
pub struct Counter {
    pub total: i64,
}

impl Counter {
    /// A receiver-less associated function, reached from `main.rs` as
    /// `Counter::new(2)` after a `use counter::Counter;`.
    pub fn new(start: i64) -> Counter {
        Counter { total: start }
    }

    /// The instance method `main.rs` calls as `c.bump(3)`.
    pub fn bump(&self, by: i64) -> i64 {
        self.total + by
    }
}
