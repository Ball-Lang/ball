//! Converting a `ball-compiler`/`ball-encoder` panic into a [`CliError`]
//! (issue #41).
//!
//! Both crates deliberately `panic!`/`assert!` on a program shape they don't
//! support (see `rust/compiler/src/lib.rs`'s "Scope boundary" and
//! `rust/encoder/src/lib.rs`'s module doc comment) rather than silently
//! degrading — the right behavior for a library, matching invariant "fail
//! loud, never swallow". But letting that panic cross the CLI's `main` would
//! abort the whole process with Rust's own `101` exit code, outside this
//! CLI's documented `0`/`1`/`2`/`3` contract. [`catch_panic_message`] catches
//! it (via [`std::panic::catch_unwind`]) and turns it into a
//! [`CliError::Parse`] carrying the panic's message — "the input could not be
//! turned into a valid/compilable program" is exactly what bucket `2` means.
use std::panic::{self, AssertUnwindSafe};

use crate::error::CliError;

/// Run `f`, catching any panic and converting it to `Err(CliError::Parse)`.
/// The default panic hook is temporarily silenced (and always restored,
/// even on panic) so a caught, intentionally-converted panic doesn't also
/// spam stderr with Rust's own "thread panicked at ..." banner — the
/// resulting `CliError` message is the loud, actionable one.
///
/// `f` is wrapped in [`AssertUnwindSafe`]: `Compiler`/encoder state is
/// discarded immediately after a panic (never inspected post-unwind), so the
/// usual "maybe left in a torn state" concern `UnwindSafe` guards against
/// does not apply here.
pub fn catch_panic_message<T>(f: impl FnOnce() -> T) -> Result<T, CliError> {
    let previous_hook = panic::take_hook();
    panic::set_hook(Box::new(|_| {}));
    let result = panic::catch_unwind(AssertUnwindSafe(f));
    panic::set_hook(previous_hook);
    // `&*payload` (not `&payload`): `payload: Box<dyn Any + Send>` and
    // `Box<dyn Any + Send>` *itself* also implements `Any` (the blanket
    // `impl<T: 'static + ?Sized> Any for T`), so `&payload` coerces to
    // `&(dyn Any + Send)` by treating the **Box value itself** as the `Any`
    // payload (concrete type `Box<dyn Any + Send>`) rather than deref'ing
    // through to the panic's actual payload inside it — `downcast_ref`
    // then always misses, silently falling through to the "unknown panic"
    // branch below. Deref first to reach the real payload.
    result.map_err(|payload| CliError::Parse(panic_message(&*payload)))
}

fn panic_message(payload: &(dyn std::any::Any + Send)) -> String {
    if let Some(s) = payload.downcast_ref::<&str>() {
        (*s).to_string()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "unknown panic (no string payload)".to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ok_value_passes_through() {
        assert_eq!(catch_panic_message(|| 42).unwrap(), 42);
    }

    #[test]
    fn str_panic_becomes_parse_error() {
        let err = catch_panic_message(|| -> i32 { panic!("boom") }).unwrap_err();
        assert!(matches!(&err, CliError::Parse(msg) if msg == "boom"));
        assert_eq!(err.exit_code(), 2);
    }

    #[test]
    fn string_panic_becomes_parse_error() {
        let err =
            catch_panic_message(|| -> i32 { panic!("{}", format!("bad: {}", 7)) }).unwrap_err();
        assert!(matches!(err, CliError::Parse(msg) if msg == "bad: 7"));
    }
}
