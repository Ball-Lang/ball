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

/// The report's positive floor is real: a run that scored nothing exits
/// non-zero rather than printing a flattering 0%.
#[test]
fn an_empty_run_is_a_harness_failure_not_a_zero_percent_result() {
    let mut out = String::new();
    let code = ball_rq1_study::report(&mut out, &[], &[]).expect("the report renders");
    assert_eq!(code, 1);
    assert!(
        out.contains("Results: 0 passed, 0 failed, 0 total"),
        "{out}"
    );
}
