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

/// Read one single-quoted Dart string literal off the front of `rest`,
/// skipping leading whitespace and at most one separating comma.
///
/// Returns the literal's contents and the remaining text, or `None` when the
/// next token is not a plain literal (an adjacent-string description, a `[`,
/// the `_fn(` helper's own parameter list, …).
fn take_literal(rest: &str) -> Option<(String, &str)> {
    let after_ws = rest.trim_start();
    let after_comma = after_ws.strip_prefix(',').unwrap_or(after_ws).trim_start();
    let body = after_comma.strip_prefix('\'')?;
    let end = body.find('\'')?;
    Some((body[..end].to_string(), &body[end + 1..]))
}

/// Every `(name, outputType)` pair the canonical Dart builder for `module`
/// declares, in declaration order.
///
/// `_fn('name', 'inputType', 'outputType', description)` — the first three
/// arguments are always plain single-quoted literals (the description may be an
/// adjacent-string concatenation, which is why only the first three are read).
///
/// This exists because [`assert_matches_dart_source`] compares NAMES only, and
/// a name-only gate cannot see a declared-type drift: `set_add`/`set_remove`
/// were given `outputType: 'bool'` in Dart by issue #545 and stayed `""` here
/// and in C# — a divergence in the very contract that PR green and this crate
/// green (issue #557, PR #562's round-2 review, item 1).
pub(crate) fn dart_declared_function_output_types(module: &str) -> Vec<(String, String)> {
    let path = dart_std_source(module);
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()));

    let mut pairs = Vec::new();
    let mut rest = text.as_str();
    while let Some(i) = rest.find("_fn(") {
        rest = &rest[i + "_fn(".len()..];
        let Some((name, after_name)) = take_literal(rest) else {
            continue; // the `_fn(` helper declaration, not a registration
        };
        let Some((_input_type, after_input)) = take_literal(after_name) else {
            continue;
        };
        let Some((output_type, after_output)) = take_literal(after_input) else {
            continue;
        };
        rest = after_output;
        pairs.push((name, output_type));
    }
    pairs
}

/// Assert this crate's builder for `module` declares the same `outputType` for
/// every function as the canonical Dart builder.
///
/// Runs alongside [`assert_matches_dart_source`], which covers the names; a
/// function present in only one of the two sources is that gate's job to
/// report, so this one silently skips it rather than double-reporting.
pub(crate) fn assert_output_types_match_dart_source(
    module: &str,
    actual: &[crate::FunctionDefinition],
) {
    let expected = dart_declared_function_output_types(module);
    assert!(
        expected.len() >= 10,
        "extracted only {} `_fn(name, input, output, …)` triples from \
         dart/shared/lib/{module}.dart — the scan has stopped matching, so this \
         gate would pass vacuously",
        expected.len(),
    );

    let mut mismatches = Vec::new();
    for (name, expected_output) in &expected {
        let Some(function) = actual.iter().find(|f| &f.name == name) else {
            continue; // a missing function is `assert_matches_dart_source`'s report
        };
        if &function.output_type != expected_output {
            mismatches.push(format!(
                "{name}: Dart declares {expected_output:?}, this crate declares {:?}",
                function.output_type
            ));
        }
    }

    assert!(
        mismatches.is_empty(),
        "`{module}` outputType drifted from dart/shared/lib/{module}.dart\n  {}\n  \
         Port the Dart `outputType` into rust/shared/src/{module}_module.rs — a \
         declared outputType is a cross-target CONTRACT (issue #545/#557), not \
         documentation.",
        mismatches.join("\n  "),
    );
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
