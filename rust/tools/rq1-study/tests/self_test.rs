//! Self-test for the Rust Tier A coverage-study harness (issue #493).
//!
//! A new measuring instrument must not inherit the blind spot it exists to
//! close. The gap #493 documents is that every existing gate is scoped to the
//! project's own single-file, entry-point-shaped conformance fixtures, so real
//! library crates — no `fn main`, declarations split across files — were never
//! looked at. The cheapest way for this harness to inherit that blind spot
//! would be to SKIP such files (by reaching for `ball_lang_encoder::encode`,
//! which asserts an entry point exists) and then report a flattering number
//! over what is left.
//!
//! **What this does and does not prove.** These assertions validate the
//! HARNESS. They are not regression tests for any encoder/compiler defect: the
//! Tier A run itself is report-only (`coverage-study.yml` has no
//! `pull_request:` trigger), so a Rust-pipeline regression it measures would
//! not redden this or any other PR.
//!
//! The Dart original (`rq1_study_self_test.dart`) can assert "a plain file is
//! reported clean" because the Dart round trip is closed — the Dart compiler
//! emits idiomatic Dart the Dart encoder reads back. The Rust round trip is NOT
//! closed: the compiler emits `ball_lang_shared::runtime::*` shapes the encoder
//! does not recognise, which is why the existing `rust-roundtrip` row in
//! conformance-matrix.yml reports an honest 0/321 on the project's own corpus.
//! There is therefore no Rust source this harness can honestly call clean, and
//! asserting one would mean weakening the harness until something passed.
//! `plain_library_file_survives_the_funnel` asserts the funnel instead — the
//! strongest statement true today — and it strengthens by itself the moment the
//! round trip closes.

use std::sync::Once;

use ball_rq1_study::{declaration_inventory, silence_panic_output, stage_reached, study_file};

static SILENCE: Once = Once::new();

fn quiet() {
    // The pipeline fails loud by panicking; the harness scores each panic, so
    // the default printer would bury the test output in backtraces.
    SILENCE.call_once(silence_panic_output);
}

/// A plain helper library: no `fn main`, nothing exotic. Exactly the shape
/// every gate before #493 never looked at, and the shape #491 slice 2's
/// `encode_library` exists to accept.
const HELPER_SOURCE: &str = r#"
pub fn twice(value: i64) -> i64 {
    value * 2
}
"#;

/// A construct the encoder explicitly rejects — an item-level `const` is one of
/// its documented gaps. The negative control: it must be REPORTED with its own
/// taxonomy tag and must stop strictly earlier in the funnel than the plain
/// file, so the harness cannot pass by painting every file with one reason.
const UNSUPPORTED_SOURCE: &str = r#"
pub const LIMIT: i64 = 3;

pub fn limit() -> i64 {
    LIMIT
}
"#;

/// 1 — the whole point of #493: an entry-point-less file is SCORED, never
/// silently skipped. This is also the direct assertion that #491 slice 2's
/// `encode_library` path is the one in use — reaching for `encode` here would
/// make every library file a blanket encode-error.
#[test]
fn entry_point_less_files_are_scored() {
    quiet();
    let result = study_file("synthetic", "helper.rs", HELPER_SOURCE);
    assert!(
        result.scored,
        "an entry-point-less library file was silently skipped (reason {:?}) — \
         the blind spot #493 exists to close",
        result.reason
    );
}

/// 2 — the funnel is real: a plain library file gets PAST encode and
/// compile-back. If the harness were failing everything at stage 1 and calling
/// that a measurement, this would be 0.
#[test]
fn plain_library_file_survives_the_funnel() {
    quiet();
    let result = study_file("synthetic", "helper.rs", HELPER_SOURCE);
    let stage = stage_reached(&result.reason).expect("a known taxonomy tag");
    assert!(
        stage >= 2,
        "a plain library file only reached stage {stage} (reason {:?}); \
         expected it to encode and compile back",
        result.reason
    );
}

/// 3 — every verdict carries a taxonomy tag the funnel knows. An unknown tag
/// makes `stage_reached` fail, so a new failure mode cannot be silently
/// mis-attributed into the funnel.
#[test]
fn every_verdict_carries_a_known_taxonomy_tag() {
    quiet();
    for source in [HELPER_SOURCE, UNSUPPORTED_SOURCE] {
        let result = study_file("synthetic", "file.rs", source);
        assert!(
            result.reason.contains(':'),
            "a bare verdict with no taxonomy detail: {:?}",
            result.reason
        );
        stage_reached(&result.reason).expect("a known taxonomy tag");
    }
}

/// 4 — the negative control: a construct the encoder rejects is scored, not
/// clean, tagged `encode-error`, and stops STRICTLY EARLIER than the plain
/// file. "Same reason for everything" is what this catches.
#[test]
fn the_harness_discriminates_between_failure_modes() {
    quiet();
    let unsupported = study_file("synthetic", "consts.rs", UNSUPPORTED_SOURCE);
    assert!(unsupported.scored && !unsupported.clean, "{unsupported:?}");
    assert!(
        unsupported.reason.starts_with("encode-error:"),
        "expected an encode-error taxonomy tag, got {:?}",
        unsupported.reason
    );

    let plain = study_file("synthetic", "helper.rs", HELPER_SOURCE);
    assert!(
        stage_reached(&unsupported.reason).unwrap() < stage_reached(&plain.reason).unwrap(),
        "the harness is not discriminating between failure modes: \
         {:?} vs {:?}",
        unsupported.reason,
        plain.reason
    );
}

/// The declaration inventory is the harness's own eyes for stage 4. Prove it is
/// a real `syn` walk: it must see `impl` methods and struct fields, and it must
/// actually MISS a declaration that was removed, or stage 4 is a rubber stamp.
#[test]
fn declaration_inventory_is_a_real_syn_walk() {
    let full = declaration_inventory(
        r#"
pub struct Box {
    size: i64,
}

impl Box {
    pub fn area(&self) -> i64 {
        self.size
    }
}

pub fn free(value: i64) -> i64 {
    value
}
"#,
    )
    .expect("the fixture parses");

    let expected: Vec<&str> = vec!["fn free", "impl Box.area", "struct Box", "struct Box.size"];
    assert_eq!(
        full.iter().map(String::as_str).collect::<Vec<_>>(),
        expected
    );

    let pruned = declaration_inventory("pub struct Box { size: i64 }").expect("the fixture parses");
    let lost: Vec<&str> = full
        .iter()
        .filter(|name| !pruned.contains(*name))
        .map(String::as_str)
        .collect();
    assert_eq!(lost, vec!["fn free", "impl Box.area"]);
}

/// The instrument really is crate-aware now (issue #491), and the difference
/// is visible in its own verdicts: the SAME file that stops at stage 0 with an
/// "unsupported method call" when measured single-file gets past the encode
/// stage when the crate's `mod` graph is walked first. Asserting the delta —
/// not just the crate-aware half — is what keeps a future refactor from
/// silently dropping the context and reporting the old numbers under the new
/// name.
///
/// The crate-aware verdict is deliberately NOT asserted clean: the Rust round
/// trip is not closed (see this file's module doc), so it lands further down
/// the funnel, and demanding "clean" here would mean weakening the harness
/// until something passed.
#[test]
fn a_cross_file_method_call_is_measured_crate_aware() {
    quiet();
    let dir = std::env::temp_dir().join(format!(
        "ball_rq1_crate_aware_{}_{}",
        std::process::id(),
        line!()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("src")).expect("failed to create the scratch crate");
    let caller = "mod counter;\nuse counter::Counter;\n\
                  pub fn total() -> i64 { let c = Counter::new(1); c.bump(2) }\n";
    std::fs::write(dir.join("src/lib.rs"), caller).expect("failed to write lib.rs");
    std::fs::write(
        dir.join("src/counter.rs"),
        "pub struct Counter { pub total: i64 }\n\
         impl Counter {\n\
         pub fn new(start: i64) -> Counter { Counter { total: start } }\n\
         pub fn bump(&self, by: i64) -> i64 { self.total + by }\n\
         }\n",
    )
    .expect("failed to write counter.rs");

    let single_file = study_file("scratch", "src/lib.rs", caller);
    assert_eq!(
        stage_reached(&single_file.reason).expect("a known taxonomy tag"),
        0,
        "measured single-file, the cross-file method call must still block the encode: {}",
        single_file.reason
    );
    assert!(
        single_file.crate_module.is_none(),
        "a single-file measurement has no crate module"
    );

    let results = ball_rq1_study::study_directory("scratch", &dir.join("src"));
    let _ = std::fs::remove_dir_all(&dir);
    let caller_result = results
        .iter()
        .find(|result| result.file == "lib.rs")
        .expect("the crate root must be measured");
    assert_eq!(
        caller_result.crate_module.as_deref(),
        Some("main"),
        "the crate root is encoded as the `main` module"
    );
    assert!(
        stage_reached(&caller_result.reason).expect("a known taxonomy tag") >= 1,
        "measured crate-aware, the same file must get past the encode stage: {}",
        caller_result.reason
    );
}

/// The report's positive floor is real: a run that scored nothing exits
/// non-zero rather than printing a flattering 0%.
#[test]
fn an_empty_run_is_a_harness_failure_not_a_zero_percent_result() {
    let mut out = String::new();
    let code = ball_rq1_study::report(&mut out, &[], &[], &[]).expect("the report renders");
    assert_eq!(code, 1);
    assert!(
        out.contains("Results: 0 passed, 0 failed, 0 total"),
        "{out}"
    );
}

// ── test-only exclusion (the owner's 2026-09-14 decision on #491) ───────────
//
// Tier A scores the LIBRARY code a user would encode; a crate's own test suite
// is a different population and is out of the denominator. This is the row the
// decision was written for: 33 of Rust's 110 scored files were `bitflags`'
// `src/tests/*.rs`, which exist only under `#[cfg(test)] mod tests;` and which
// `crate_graph.rs::walk_items` deliberately does not walk (#621), so they were
// measured with no crate context at all and dragged the whole row down.
//
// Rust's convention has TWO halves and both are needed: a path rule
// (`tests/`, `benches/`, `examples/`) and a REACHABILITY rule (a file the mod
// graph reaches only by passing through a `#[cfg(test)]` module). Neither
// subsumes the other — `src/tests.rs` is not under a `tests/` directory, and a
// crate may keep unit tests in a directory named anything at all.
//
// The negative control is load-bearing: a library file whose NAME merely
// contains "test" ("la-test", "con-test", "at-test-ation") must still be
// studied. A sloppy substring rule passes the exclusion half and fails this
// half, which is the point.

/// Builds a scratch crate with library files, path-excluded test trees and a
/// `#[cfg(test)]`-only module, and returns its root.
fn scratch_crate(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "ball_rq1_exclusion_{}_{}_{}",
        tag,
        std::process::id(),
        line!()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    let src = dir.join("src");
    for sub in ["attestation", "tests", "benches", "examples"] {
        std::fs::create_dir_all(src.join(sub)).expect("failed to create the scratch crate");
    }

    let write = |rel: &str, source: &str| {
        std::fs::write(src.join(rel), source).unwrap_or_else(|e| panic!("write {rel}: {e}"));
    };
    write(
        "lib.rs",
        "pub mod core;\npub mod latest;\npub mod contest;\npub mod attestation;\n\
         #[cfg(test)]\nmod internal_tests;\n",
    );
    for rel in ["core.rs", "latest.rs", "contest.rs"] {
        write(rel, "pub fn value() -> i64 { 1 }\n");
    }
    write("attestation/mod.rs", "pub mod verify;\n");
    write("attestation/verify.rs", "pub fn ok() -> i64 { 1 }\n");
    write(
        "internal_tests.rs",
        "#[test]\nfn works() { assert!(true); }\n",
    );
    write("tests/basic.rs", "#[test]\nfn basic() { assert!(true); }\n");
    write("benches/perf.rs", "pub fn bench() {}\n");
    write("examples/demo.rs", "fn main() {}\n");
    dir
}

/// Every library file — including the three whose names merely contain "test" —
/// is studied, and every test-only file is excluded WITH the rule that excluded
/// it.
#[test]
fn test_only_files_are_excluded_counted_and_named() {
    quiet();
    let dir = scratch_crate("classify");
    let src = dir.join("src");
    let (studied, excluded) = ball_rq1_study::classify_rust_files("scratch", &src);

    let rel = |path: &std::path::Path| {
        path.strip_prefix(&src)
            .unwrap_or(path)
            .to_string_lossy()
            .replace('\\', "/")
    };
    let studied_rel: std::collections::BTreeSet<String> = studied.iter().map(|p| rel(p)).collect();
    let excluded_rel: std::collections::BTreeSet<String> =
        excluded.iter().map(|e| e.file.clone()).collect();

    let library = [
        "lib.rs",
        "core.rs",
        "latest.rs",
        "contest.rs",
        "attestation/mod.rs",
        "attestation/verify.rs",
    ];
    for name in library {
        assert!(
            studied_rel.contains(name),
            "library file {name} was not studied — the rule is excluding library code \
             (studied: {studied_rel:?})"
        );
    }
    assert_eq!(
        studied_rel.len(),
        library.len(),
        "exactly the library files must be studied; got {studied_rel:?}"
    );

    for name in [
        "internal_tests.rs",
        "tests/basic.rs",
        "benches/perf.rs",
        "examples/demo.rs",
    ] {
        assert!(
            excluded_rel.contains(name),
            "test-only file {name} was not excluded (excluded: {excluded_rel:?})"
        );
    }
    assert_eq!(
        excluded_rel.len(),
        4,
        "exactly the test-only files must be excluded; got {excluded_rel:?}"
    );
    assert!(
        excluded.iter().all(|e| !e.rule.is_empty()),
        "every exclusion must name the rule that made it"
    );
    // The cfg(test) half is a REACHABILITY rule, not a path rule: nothing about
    // `internal_tests.rs` looks like a test directory.
    let cfg_rule = excluded
        .iter()
        .find(|e| e.file == "internal_tests.rs")
        .expect("the cfg(test)-only module is excluded")
        .rule
        .clone();
    assert!(
        cfg_rule.contains("cfg(test)"),
        "the cfg(test)-only module must be excluded BY the cfg(test) rule, not by a \
         path rule; got {cfg_rule:?}"
    );

    let results = ball_rq1_study::study_directory("scratch", &src);
    assert!(
        results
            .iter()
            .all(|r| !excluded_rel.contains(r.file.as_str())),
        "an excluded file must never reach the scored results: {:?}",
        results.iter().map(|r| &r.file).collect::<Vec<_>>()
    );

    let mut out = String::new();
    let _ = ball_rq1_study::report(&mut out, &results, &excluded, &[]);
    assert!(
        out.contains("  excluded (test-only): 4\n"),
        "the summary must print the exclusion count so nothing disappears silently; got:\n{out}"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

/// A run that excluded nothing STILL prints the line: a missing line is
/// indistinguishable from a rule that vanished, and `summarize.sh` fails on it.
#[test]
fn the_exclusion_count_is_printed_even_when_zero() {
    quiet();
    let results = vec![study_file("scratch", "helper.rs", HELPER_SOURCE)];
    let mut out = String::new();
    let _ = ball_rq1_study::report(&mut out, &results, &[], &[]);
    assert!(
        out.contains("  excluded (test-only): 0\n"),
        "a zero exclusion count must still be printed; got:\n{out}"
    );
}
