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

    let results = ball_rq1_study::study_directory("scratch", &dir.join("src"))
        .expect("the scratch crate has a crate root");
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
// Rust's convention has TWO halves and both are needed: a path rule (the
// PACKAGE-ROOT `tests/`, `benches/`, `examples/` Cargo targets) and a
// REACHABILITY rule (a file the mod graph reaches only by passing through a
// `#[cfg(test)]` module). Neither subsumes the other — `src/tests.rs` is not
// under a package-root `tests/` directory, and a crate may keep unit tests in a
// directory named anything at all.
//
// The negative control is load-bearing, and it has two forms: a library file
// whose NAME merely contains "test" ("la-test", "con-test", "at-test-ation"),
// and a library DIRECTORY literally called `tests` that is not a Cargo target
// (`src/tests/`, declared `pub mod tests;`). Both must still be studied. A
// sloppy substring rule fails the first; a path rule that matches any `tests`
// segment rather than a package-root one fails the second.

/// Builds a scratch **package** — a real Cargo layout, not a bare `src/` tree —
/// and returns its root.
///
/// The layout matters, because the path half of the rule is about the PACKAGE
/// ROOT: `tests/`, `benches/` and `examples/` are separate Cargo targets only
/// as SIBLINGS of `src/`. `src/tests/` is none of those — it is an ordinary
/// module directory, and here it is PUBLIC library code (`pub mod tests;` from
/// `lib.rs`, the shape every crate that ships its fixtures as API takes). A
/// path rule that matched any `tests` segment would take it out of the
/// denominator, which is the silent shrink this rule exists to prevent.
fn scratch_crate(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "ball_rq1_exclusion_{}_{}_{}",
        tag,
        std::process::id(),
        line!()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    for sub in [
        "src/attestation",
        "src/tests",
        "tests",
        "benches",
        "examples",
    ] {
        std::fs::create_dir_all(dir.join(sub)).expect("failed to create the scratch package");
    }

    let write = |rel: &str, source: &str| {
        std::fs::write(dir.join(rel), source).unwrap_or_else(|e| panic!("write {rel}: {e}"));
    };
    // The manifest is what says where the package root IS; without it the path
    // half has no anchor and must not fire at all.
    write(
        "Cargo.toml",
        "[package]\nname = \"scratch\"\nversion = \"0.0.0\"\nedition = \"2021\"\n",
    );
    write(
        "src/lib.rs",
        "pub mod core;\npub mod latest;\npub mod contest;\npub mod attestation;\npub mod tests;\n\
         #[cfg(test)]\nmod internal_tests;\n",
    );
    for rel in ["src/core.rs", "src/latest.rs"] {
        write(rel, "pub fn value() -> i64 { 1 }\n");
    }
    // `contest.rs` is a NON-mod-rs file, and its `#[path]` sits outside any
    // inline block — so the Rust reference resolves it against the declaring
    // FILE's directory (`src/`), NOT against the `src/contest/` directory its
    // plain `mod name;` children would use. Getting that wrong makes the
    // candidate miss, the module go unwalked, and `relocated_tests.rs` stay in
    // the denominator, so this fixture is what keeps the two apart.
    write(
        "src/contest.rs",
        "pub fn value() -> i64 { 1 }\n\
         #[cfg(test)]\n#[path = \"relocated_tests.rs\"]\nmod relocated;\n",
    );
    write("src/attestation/mod.rs", "pub mod verify;\n");
    write("src/attestation/verify.rs", "pub fn ok() -> i64 { 1 }\n");
    // PUBLIC library code that happens to live in a directory called `tests`:
    // `lib.rs` declares it with a plain `pub mod tests;`, so `cargo build`
    // builds it and a user encoding this crate encodes it.
    write("src/tests/mod.rs", "pub mod foo;\n");
    write("src/tests/foo.rs", "pub fn fixture() -> i64 { 1 }\n");
    write(
        "src/internal_tests.rs",
        "#[test]\nfn works() { assert!(true); }\n",
    );
    // Reached only through `contest.rs`'s `#[cfg(test)] #[path] mod`, and
    // living beside it in `src/` — not under `src/contest/`.
    write(
        "src/relocated_tests.rs",
        "#[test]\nfn relocated() { assert!(true); }\n",
    );
    // The package-root Cargo targets: their own crates, which `cargo build`
    // does not build and nobody encodes.
    write("tests/basic.rs", "#[test]\nfn basic() { assert!(true); }\n");
    write("benches/perf.rs", "pub fn bench() {}\n");
    write("examples/demo.rs", "fn main() {}\n");
    dir
}

/// The package-root files under `tests/`, `benches/` and `examples/` plus the
/// two `#[cfg(test)]`-only modules are excluded WITH the rule that excluded
/// them; every library file — the three whose names merely contain "test" and
/// the public `src/tests/` module among them — is studied.
#[test]
fn test_only_files_are_excluded_counted_and_named() {
    quiet();
    let dir = scratch_crate("classify");
    let (studied, excluded) =
        ball_rq1_study::classify_rust_files("scratch", &dir, ball_rq1_study::CrateRoot::Required)
            .expect("the scratch package root resolves src/lib.rs");

    let rel = |path: &std::path::Path| {
        path.strip_prefix(&dir)
            .unwrap_or(path)
            .to_string_lossy()
            .replace('\\', "/")
    };
    let studied_rel: std::collections::BTreeSet<String> = studied.iter().map(|p| rel(p)).collect();
    let excluded_rel: std::collections::BTreeSet<String> =
        excluded.iter().map(|e| e.file.clone()).collect();

    let library = [
        "src/lib.rs",
        "src/core.rs",
        "src/latest.rs",
        "src/contest.rs",
        "src/attestation/mod.rs",
        "src/attestation/verify.rs",
        "src/tests/mod.rs",
        "src/tests/foo.rs",
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
        "src/internal_tests.rs",
        "src/relocated_tests.rs",
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
        5,
        "exactly the test-only files must be excluded; got {excluded_rel:?}"
    );
    assert!(
        excluded.iter().all(|e| !e.rule.is_empty()),
        "every exclusion must name the rule that made it"
    );
    // The path half is a PACKAGE-ROOT rule: the `tests/` Cargo target is
    // excluded by it, and the public `src/tests/` module is not excluded at all.
    let path_rule = excluded
        .iter()
        .find(|e| e.file == "tests/basic.rs")
        .expect("the package-root tests/ target is excluded")
        .rule
        .clone();
    assert!(
        path_rule.contains("package-root"),
        "the package-root Cargo target must be excluded BY the path rule; got {path_rule:?}"
    );
    // The cfg(test) half is a REACHABILITY rule, not a path rule: nothing about
    // `internal_tests.rs` looks like a test directory.
    let cfg_rule = excluded
        .iter()
        .find(|e| e.file == "src/internal_tests.rs")
        .expect("the cfg(test)-only module is excluded")
        .rule
        .clone();
    assert!(
        cfg_rule.contains("cfg(test)"),
        "the cfg(test)-only module must be excluded BY the cfg(test) rule, not by a \
         path rule; got {cfg_rule:?}"
    );
    // And the walk resolves `#[path]` the way the Rust reference does: outside
    // an inline block, relative to the declaring FILE's directory. Getting that
    // wrong makes the candidate miss, the module go unwalked, and a test file
    // stay in the denominator — which is why it is asserted rather than assumed.
    assert!(
        excluded
            .iter()
            .any(|e| e.file == "src/relocated_tests.rs" && e.rule.contains("cfg(test)")),
        "a `#[cfg(test)] #[path = \"…\"] mod` must resolve and be excluded by the \
         cfg(test) rule; got {excluded_rel:?}"
    );

    let results = ball_rq1_study::study_directory("scratch", &dir)
        .expect("the scratch package root resolves src/lib.rs");
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
        out.contains("  excluded (test-only): 5\n"),
        "the summary must print the exclusion count so nothing disappears silently; got:\n{out}"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

/// The shape every pin actually uses: `lib` is `src`, so the studied subtree is
/// the crate's `src/` and the package-root Cargo targets are not even walked.
///
/// A public `src/tests/` module must survive THIS invocation too — it is the
/// one the published numbers come from — and the `#[cfg(test)]` reachability
/// half must still find the crate root.
#[test]
fn a_public_src_tests_module_survives_the_pin_shaped_subtree() {
    quiet();
    let dir = scratch_crate("subtree");
    let src = dir.join("src");
    let (studied, excluded) =
        ball_rq1_study::classify_rust_files("scratch", &src, ball_rq1_study::CrateRoot::Required)
            .expect("the studied src/ subtree resolves lib.rs");

    let studied_rel: std::collections::BTreeSet<String> = studied
        .iter()
        .map(|path| {
            path.strip_prefix(&src)
                .unwrap_or(path)
                .to_string_lossy()
                .replace('\\', "/")
        })
        .collect();
    let excluded_rel: std::collections::BTreeSet<String> =
        excluded.iter().map(|e| e.file.clone()).collect();

    for name in ["tests/mod.rs", "tests/foo.rs"] {
        assert!(
            studied_rel.contains(name),
            "the PUBLIC src/{name} module was not studied — the path half is matching a \
             `tests` segment that is not a package-root Cargo target (studied: {studied_rel:?})"
        );
    }
    assert_eq!(
        excluded_rel,
        [
            "internal_tests.rs".to_string(),
            "relocated_tests.rs".to_string()
        ]
        .into_iter()
        .collect::<std::collections::BTreeSet<String>>(),
        "only the cfg(test)-only modules are test-only inside src/; got {excluded_rel:?}"
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

// ── the crate-root anchor must be DECLARED, never silently absent (#648) ────
//
// The `#[cfg(test)]` reachability half above is anchored on a crate root, and
// on the real pins it is the half that does all the work: all 34 of `bitflags`'
// exclusions come from it, 0 from the path half. That anchor is resolved by
// looking for `lib.rs` / `main.rs` / `src/lib.rs` / `src/main.rs` under the
// STUDIED SUBTREE — so a pin whose `lib` points one level too deep, a crate
// whose root moved, or a refactor of the resolver leaves it unfound.
//
// "Unfound" must not mean "exclude nothing and carry on". That switches the only
// working half of the rule OFF, every test-only file silently re-enters the
// denominator, and the published ratchet reads the resulting jump in `scored` as
// an improvement — it raises the floors on a population nobody chose. The
// exclusion is opt-out only by an explicit `"crateRoot": "none"` in the pin (the
// genuinely-anchorless "bare directory of .rs files" case), declared per pin
// rather than inferred from a failed search.

/// A checkouts directory holding ONE package whose studied subtree contains no
/// crate root, and whose `#[cfg(test)]`-only module lives inside that subtree.
///
/// `src/deep/mod.rs` declares `#[cfg(test)] mod deep_tests;`, so `deep_tests.rs`
/// IS test-only — but nothing under `src/deep` is a crate root (`mod.rs` is not
/// one), so the reachability walk has nothing to start from. This is the `lib` /
/// `--source-dir` "one level too deep" shape, reproduced exactly.
fn anchorless_checkouts(tag: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "ball_rq1_anchorless_{}_{}_{}",
        tag,
        std::process::id(),
        line!()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    let package = dir.join("deepcrate");
    std::fs::create_dir_all(package.join("src/deep")).expect("failed to create the scratch crate");
    let write = |rel: &str, source: &str| {
        std::fs::write(package.join(rel), source).unwrap_or_else(|e| panic!("write {rel}: {e}"));
    };
    write(
        "Cargo.toml",
        "[package]\nname = \"deepcrate\"\nversion = \"0.0.0\"\nedition = \"2021\"\n",
    );
    write("src/lib.rs", "pub mod deep;\n");
    write(
        "src/deep/mod.rs",
        "pub fn value() -> i64 { 1 }\n#[cfg(test)]\nmod deep_tests;\n",
    );
    write(
        "src/deep/deep_tests.rs",
        "#[test]\nfn works() { assert!(true); }\n",
    );
    dir
}

/// Writes a pin file naming the one package of [`anchorless_checkouts`], plus
/// whatever `extra` pin fields the caller wants on it.
fn anchorless_pins(dir: &std::path::Path, extra: &str) -> std::path::PathBuf {
    let path = dir.join("pins.json");
    std::fs::write(
        &path,
        format!(
            "{{\n  \"packages\": [\n    \
             {{ \"name\": \"deepcrate\", \"lib\": \"src/deep\"{extra} }}\n  ]\n}}\n"
        ),
    )
    .expect("failed to write the pin file");
    path
}

fn run_harness(args: &[&str]) -> std::process::Output {
    std::process::Command::new(env!("CARGO_BIN_EXE_rq1-study"))
        .args(args)
        .output()
        .expect("failed to run the rq1-study binary")
}

/// The negative control for #648: a studied subtree with a `#[cfg(test)]`-only
/// module and NO resolvable crate root must FAIL the run, naming the paths it
/// searched — never print a note and measure on with the reachability half off.
#[test]
fn an_unresolvable_crate_root_fails_the_run() {
    let dir = anchorless_checkouts("fatal");
    let pins = anchorless_pins(&dir, "");
    let json = dir.join("tier_a.json");
    let out = run_harness(&[
        "--pins",
        &pins.to_string_lossy(),
        "--checkouts",
        &dir.to_string_lossy(),
        "--json",
        &json.to_string_lossy(),
    ]);
    let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    let _ = std::fs::remove_dir_all(&dir);

    assert!(
        !out.status.success(),
        "a pin whose crate root does not resolve must FAIL the run — with the \
         reachability half silently off its #[cfg(test)]-only file re-enters the \
         denominator and the ratchet reads that as an improvement (#648).\n\
         stdout:\n{stdout}\nstderr:\n{stderr}"
    );
    let expected = ["deepcrate", "lib.rs", "main.rs", "src/lib.rs", "src/main.rs", "crateRoot"];
    for needle in expected {
        assert!(
            stderr.contains(needle),
            "the failure must name {needle:?} — the searched paths and the opt-in are \
             what make it actionable; got:\n{stderr}"
        );
    }
}

/// …and the opt-out is EXPLICIT and per pin: `"crateRoot": "none"` declares a
/// subtree that genuinely has no crate root, and the run then proceeds with the
/// `#[cfg(test)]` module STUDIED — nothing can be shown test-only without an
/// anchor, and this harness only ever excludes what it can positively show.
#[test]
fn the_declared_anchorless_opt_in_lets_the_run_proceed() {
    let dir = anchorless_checkouts("optin");
    let pins = anchorless_pins(&dir, ", \"crateRoot\": \"none\"");
    let json = dir.join("tier_a.json");
    let out = run_harness(&[
        "--pins",
        &pins.to_string_lossy(),
        "--checkouts",
        &dir.to_string_lossy(),
        "--json",
        &json.to_string_lossy(),
    ]);
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
    let report = std::fs::read_to_string(&json).unwrap_or_default();
    let _ = std::fs::remove_dir_all(&dir);

    assert!(
        out.status.success(),
        "an explicitly anchorless pin must be allowed to run.\n\
         stdout:\n{stdout}\nstderr:\n{stderr}"
    );
    assert!(
        stdout.contains("  excluded (test-only): 0\n"),
        "an anchorless pin excludes nothing, and the count must still be printed; got:\n{stdout}"
    );
    assert!(
        stdout.contains("2 total"),
        "both files of the anchorless subtree must be scored, the #[cfg(test)]-only \
         module included — the rule only removes what it can positively show; got:\n{stdout}"
    );
    assert!(
        report.contains("deep_tests.rs") && report.contains("\"excludedTestOnly\": 0"),
        "the JSON report must show the cfg(test)-only module studied and nothing \
         excluded; got:\n{report}"
    );
}

/// The same opt-in exists for the one-off `--package/--source-dir` mode, in the
/// same shape: fatal by default, allowed only when declared. An opt-in that
/// lived only in the pin file would leave the ad-hoc invocation — the one a
/// human actually types, and the one the issue's `--source-dir` case names —
/// with the old silent fallback.
#[test]
fn the_source_dir_mode_has_the_same_explicit_opt_in() {
    let dir = anchorless_checkouts("srcdir");
    let deep = dir.join("deepcrate/src/deep");
    let fatal = run_harness(&[
        "--package",
        "deepcrate",
        "--source-dir",
        &deep.to_string_lossy(),
    ]);
    let allowed = run_harness(&[
        "--package",
        "deepcrate",
        "--source-dir",
        &deep.to_string_lossy(),
        "--no-crate-root",
    ]);
    let fatal_err = String::from_utf8_lossy(&fatal.stderr).into_owned();
    let allowed_out = String::from_utf8_lossy(&allowed.stdout).into_owned();
    let _ = std::fs::remove_dir_all(&dir);

    assert!(
        !fatal.status.success() && fatal_err.contains("--no-crate-root"),
        "--source-dir must fail on an unresolvable crate root and name its opt-in; \
         got status {:?}, stderr:\n{fatal_err}",
        fatal.status.code()
    );
    assert!(
        allowed.status.success() && allowed_out.contains("  excluded (test-only): 0\n"),
        "--no-crate-root must let the same run proceed; got status {:?}, stdout:\n{allowed_out}",
        allowed.status.code()
    );
}
