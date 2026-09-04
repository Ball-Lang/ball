//! Test-only: cross-check the Rust std module builders against the CANONICAL
//! Dart source, name for name.
//!
//! Each `std_*_module.rs` used to assert only a hardcoded function count. A
//! bare number is a documented expectation, not a gate: it can only catch a
//! change made *here*, and it says nothing when the Dart side moves. Issue #505
//! is the proof — `dart/shared/lib/std.dart` and `std_collections.dart` were
//! missing thirteen functions the encoder had been routing to for a long time,
//! and when they were finally declared, this crate silently fell thirteen
//! behind while its count assertions stayed green. (C#'s
//! `StdModuleBuilderTests` reads the Dart source and caught it immediately;
//! this module is the Rust equivalent.)
//!
//! Deliberately dependency-free: it scans for `_fn(` followed by a quoted name
//! rather than pulling in `regex`, and reads the Dart file straight off disk
//! relative to `CARGO_MANIFEST_DIR`.

use std::path::PathBuf;

/// Path to `dart/shared/lib/<module>.dart`, resolved from this crate's root.
fn dart_std_source(module: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../dart/shared/lib")
        .join(format!("{module}.dart"))
}

/// Every function name the canonical Dart builder for `module` declares, in
/// declaration order.
///
/// Extracts the name literal from each `_fn('name', …)` registration —
/// tolerating the multi-line form `dart format` produces for long entries, and
/// skipping the `FunctionDefinition _fn(` helper declaration itself (whose
/// first non-space token after `(` is not a quote).
pub(crate) fn dart_declared_function_names(module: &str) -> Vec<String> {
    let path = dart_std_source(module);
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()));

    let mut names = Vec::new();
    let mut rest = text.as_str();
    while let Some(i) = rest.find("_fn(") {
        rest = &rest[i + "_fn(".len()..];
        let after_ws = rest.trim_start();
        let Some(body) = after_ws.strip_prefix('\'') else {
            continue; // the `_fn(` helper declaration, not a registration
        };
        let Some(end) = body.find('\'') else {
            continue; // unterminated literal — cannot be a real registration
        };
        names.push(body[..end].to_string());
    }
    names
}

/// Assert this crate's builder for `module` declares exactly the same function
/// names as the canonical Dart builder — same count, same set.
pub(crate) fn assert_matches_dart_source(module: &str, actual: &[String]) {
    let mut expected = dart_declared_function_names(module);
    assert!(
        expected.len() >= 10,
        "extracted only {} function names from dart/shared/lib/{module}.dart — \
         the scan has stopped matching, so this gate would pass vacuously",
        expected.len(),
    );

    let mut actual_sorted: Vec<String> = actual.to_vec();
    expected.sort();
    actual_sorted.sort();

    let missing: Vec<&String> = expected
        .iter()
        .filter(|n| !actual_sorted.contains(n))
        .collect();
    let extra: Vec<&String> = actual_sorted
        .iter()
        .filter(|n| !expected.contains(n))
        .collect();

    assert!(
        missing.is_empty() && extra.is_empty(),
        "`{module}` drifted from dart/shared/lib/{module}.dart\n  \
         declared in Dart but missing here: {missing:?}\n  \
         declared here but not in Dart: {extra:?}\n  \
         Port the Dart declarations into rust/shared/src/{module}_module.rs \
         (see issue #505).",
    );
}
