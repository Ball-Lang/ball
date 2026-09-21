//! Issue #705 — a `cargo metadata` dependency EDGE this walk cannot follow must
//! be recorded, exactly as an unreadable dependency FILE or DIRECTORY already is
//! (#678).
//!
//! `deps.rs::direct_dependency_sources` resolves each `resolve.nodes[].deps[]`
//! entry of the root package to a source directory through four lookups: the
//! edge's `name` (the alias a path is written with), its `pkg` (the package id),
//! the `packages[]` entry that id names, and that package's library target's
//! `src_path`. Each of those was a bare `else { continue }` — so a document in
//! which any one of them is missing made that dependency's macros silently
//! unresolvable, and the next `<krate>::<macro>!` reported
//! "no `#[macro_export] macro_rules!` with that name was found in that crate's
//! library target": an assertion the walk had no evidence for, since it never
//! looked in that crate at all.
//!
//! The document is handed in rather than produced by running `cargo`, because
//! `cargo` only ever emits well-formed output — the shapes under test are
//! unreachable through the `cargo`-running entry point, and a harness that
//! re-implemented the resolution would prove nothing about the shipped one.
//! [`MacroTable::seed_from_cargo_metadata_json`] is the same code path
//! `seed_from_cargo_metadata` runs, minus the `Command`.
//!
//! Every case carries the same POSITIVE FLOOR: a well-formed sibling edge in
//! the SAME document must still have contributed its macro. Without it a test
//! would "pass" on a document the resolver rejected outright, having resolved
//! nothing at all.

use ball_lang_macro_expand::{Expansion, MacroError, MacroTable};
use std::path::{Path, PathBuf};

/// A real on-disk crate source directory for the one well-formed dependency in
/// every fabricated document, removed on drop.
///
/// It has to be real: the positive floor asserts the walk actually read it.
struct GoodDependency {
    root: PathBuf,
}

impl GoodDependency {
    fn new(tag: &str) -> GoodDependency {
        let unique = format!(
            "ball-macro-expand-meta-{tag}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("the system clock is after the unix epoch")
                .as_nanos()
        );
        let root = std::env::temp_dir().join(unique);
        let src = root.join("src");
        std::fs::create_dir_all(&src).expect("the fixture's temp directory must be creatable");
        std::fs::write(
            src.join("lib.rs"),
            "#[macro_export]\nmacro_rules! good_dep_macro { () => { const FIXTURE_GOOD: u8 = 1; }; }\n",
        )
        .expect("the fixture's files must be writable");
        GoodDependency { root }
    }

    /// The `src_path` a `cargo metadata` lib target carries — the crate root
    /// FILE, whose parent is the directory the walk descends.
    fn src_path(&self) -> String {
        json_escape(&self.root.join("src").join("lib.rs").display().to_string())
    }
}

impl Drop for GoodDependency {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

/// Windows paths carry `\`, which is an escape inside a JSON string.
fn json_escape(raw: &str) -> String {
    raw.replace('\\', "\\\\").replace('"', "\\\"")
}

/// A whole `cargo metadata --format-version 1` document: the root package, the
/// one well-formed dependency, and whatever `extra_packages` / `extra_deps` the
/// case under test adds.
fn metadata(good: &GoodDependency, extra_packages: &str, extra_deps: &str) -> String {
    format!(
        r#"{{
  "packages": [
    {{
      "id": "root 0.0.0 (path+file:///root)",
      "name": "root",
      "targets": [{{ "kind": ["lib"], "src_path": "/root/src/lib.rs" }}]
    }},
    {{
      "id": "good 1.0.0 (registry+https://example.invalid)",
      "name": "good",
      "targets": [{{ "kind": ["lib"], "src_path": "{good_src}" }}]
    }}{extra_packages}
  ],
  "resolve": {{
    "root": "root 0.0.0 (path+file:///root)",
    "nodes": [
      {{
        "id": "root 0.0.0 (path+file:///root)",
        "deps": [
          {{ "name": "good", "pkg": "good 1.0.0 (registry+https://example.invalid)" }}{extra_deps}
        ]
      }}
    ]
  }}
}}"#,
        good_src = good.src_path(),
    )
}

/// Seeds a table from the fabricated document and proves the well-formed half
/// of it was actually resolved and walked.
fn seeded(good: &GoodDependency, extra_packages: &str, extra_deps: &str) -> MacroTable {
    let mut table = MacroTable::new();
    table.seed_from_cargo_metadata_json(&metadata(good, extra_packages, extra_deps));
    assert!(
        table.names().iter().any(|name| name == "good_dep_macro"),
        "positive floor: the WELL-FORMED dependency edge in the same document must have been \
         resolved and its sources walked, otherwise this case would pass on a document the \
         resolver rejected whole. In scope: {:?}",
        table.names()
    );
    table
}

fn invocation(source: &str) -> syn::Macro {
    let item: syn::Item = syn::parse_str(source).expect("the test's own invocation must parse");
    match item {
        syn::Item::Macro(item_macro) => item_macro.mac,
        other => panic!("expected a macro invocation, got {other:?}"),
    }
}

fn expansion_error(table: &MacroTable, source: &str) -> MacroError {
    table
        .expand(&invocation(source), Expansion::Items)
        .expect_err("the fixture defines no such macro, so resolution must fail")
}

/// Every one of the four drops, asserted the same way: the diagnostic of the
/// macro that then fails to resolve must NAME the edge that could not be
/// followed and say what was missing.
fn assert_named(table: &MacroTable, invocation_source: &str, fragments: &[&str]) {
    let err = expansion_error(table, invocation_source);
    let rendered = err.to_string();
    for fragment in fragments {
        assert!(
            rendered.contains(fragment),
            "the diagnostic must name the unusable dependency edge — expected it to contain \
             {fragment:?}; got: {rendered}"
        );
    }
}

/// A `deps[]` entry with no `name` cannot be matched against a path's first
/// segment, so its crate is unreachable — but the walk knows exactly which
/// package was dropped, and must say so.
#[test]
fn a_dependency_edge_with_no_name_is_named_in_the_diagnostic() {
    let good = GoodDependency::new("noname");
    let table = seeded(
        &good,
        "",
        r#",
          { "pkg": "anonymous 1.0.0 (registry+https://example.invalid)" }"#,
    );
    assert_named(
        &table,
        "some_macro_from_the_anonymous_crate!();",
        &["anonymous 1.0.0", "no `name`"],
    );
}

/// A `deps[]` entry with no `pkg` names an alias whose package id is unknown,
/// so its sources cannot be located. The ALIAS is what a reader needs.
#[test]
fn a_dependency_edge_with_no_pkg_is_named_in_the_diagnostic() {
    let good = GoodDependency::new("nopkg");
    let table = seeded(
        &good,
        "",
        r#",
          { "name": "pkgless" }"#,
    );
    assert_named(&table, "pkgless::some_macro!();", &["pkgless", "no `pkg`"]);
}

/// A `pkg` id with no matching `packages[]` entry is a document that disagrees
/// with itself. Silently skipping it turned an inconsistent document into a
/// crate that "has no such macro".
#[test]
fn a_dependency_edge_pointing_at_no_package_is_named_in_the_diagnostic() {
    let good = GoodDependency::new("ghost");
    let table = seeded(
        &good,
        "",
        r#",
          { "name": "ghost", "pkg": "ghost 2.0.0 (registry+https://example.invalid)" }"#,
    );
    assert_named(
        &table,
        "ghost::some_macro!();",
        &["ghost", "ghost 2.0.0", "no entry in `packages[]`"],
    );
}

/// A library target with no `src_path` leaves the walk with nothing to descend.
#[test]
fn a_library_target_with_no_src_path_is_named_in_the_diagnostic() {
    let good = GoodDependency::new("nosrc");
    let table = seeded(
        &good,
        r#",
    {
      "id": "srcless 1.0.0 (registry+https://example.invalid)",
      "name": "srcless",
      "targets": [{ "kind": ["lib"] }]
    }"#,
        r#",
          { "name": "srcless", "pkg": "srcless 1.0.0 (registry+https://example.invalid)" }"#,
    );
    assert_named(
        &table,
        "srcless::some_macro!();",
        &["srcless", "no `src_path`"],
    );
}

/// A package with no `lib`/`rlib`/`dylib` target at all — the same drop one
/// branch earlier, and a DIFFERENT answer from "the lib target is malformed".
#[test]
fn a_dependency_with_no_library_target_is_named_in_the_diagnostic() {
    let good = GoodDependency::new("nolib");
    let table = seeded(
        &good,
        r#",
    {
      "id": "binonly 1.0.0 (registry+https://example.invalid)",
      "name": "binonly",
      "targets": [{ "kind": ["bin"], "src_path": "/binonly/src/main.rs" }]
    }"#,
        r#",
          { "name": "binonly", "pkg": "binonly 1.0.0 (registry+https://example.invalid)" }"#,
    );
    assert_named(
        &table,
        "binonly::some_macro!();",
        &["binonly", "no `lib`/`rlib`/`dylib` target"],
    );
}

/// THE NEGATIVE CONTROL for all five. A `proc-macro` dependency exports no
/// `macro_rules!` by construction — its macros are compiled Rust, out of this
/// crate's scope by design — so skipping it is an ANSWER, not a drop, and it
/// must NOT be noted. Without this a lint-happy fix would turn every ordinary
/// proc-macro dependency into diagnostic noise on every failing resolution.
#[test]
fn a_proc_macro_dependency_is_a_documented_skip_not_a_drop() {
    let good = GoodDependency::new("procmacro");
    let table = seeded(
        &good,
        r#",
    {
      "id": "derive_thing 1.0.0 (registry+https://example.invalid)",
      "name": "derive_thing",
      "targets": [{ "kind": ["proc-macro"], "src_path": "/derive_thing/src/lib.rs" }]
    }"#,
        r#",
          { "name": "derive_thing", "pkg": "derive_thing 1.0.0 (registry+https://example.invalid)" }"#,
    );
    let rendered = expansion_error(&table, "no_such_macro_anywhere!();").to_string();
    assert!(
        !rendered.contains("derive_thing"),
        "a proc-macro dependency is skipped BY DESIGN and must not be reported as an unusable \
         edge; got: {rendered}"
    );
}

/// The notes have to reach BOTH resolution failures, not just the bare-name
/// one: a `<krate>::<macro>!` path whose crate contributed nothing takes the
/// `DependenciesUnavailable` arm, whose reason is built separately.
#[test]
fn the_notes_reach_the_qualified_path_diagnostic_too() {
    let good = GoodDependency::new("qualified");
    let table = seeded(
        &good,
        "",
        r#",
          { "name": "ghost", "pkg": "ghost 3.0.0 (registry+https://example.invalid)" }"#,
    );
    let err = expansion_error(&table, "ghost::some_macro!();");
    assert!(
        matches!(err, MacroError::DependenciesUnavailable { .. }),
        "expected a DependenciesUnavailable for the qualified spelling, got {err:?}"
    );
    assert!(
        err.to_string().contains("ghost 3.0.0"),
        "the qualified-path diagnostic must carry the unusable-edge notes too; got: {err}"
    );
}

/// A document `serde_json` cannot parse is a loud
/// [`MacroError::DependenciesUnavailable`], never an empty table that reads as
/// "this crate has no dependencies".
#[test]
fn an_unparseable_document_is_loud() {
    let mut table = MacroTable::new();
    table.seed_from_cargo_metadata_json("{ this is not json");
    let err = expansion_error(&table, "anything::at_all!();");
    let rendered = err.to_string();
    assert!(
        matches!(err, MacroError::DependenciesUnavailable { .. }),
        "expected a DependenciesUnavailable, got {err:?}"
    );
    assert!(
        rendered.contains("could not be parsed"),
        "the diagnostic must say the document could not be parsed; got: {rendered}"
    );
}

/// Keeps the `Path` import honest: the fixture's `src_path` must be an absolute
/// path whose PARENT is the directory the walk descends, which is the contract
/// `direct_dependency_sources` relies on.
#[test]
fn the_fixtures_src_path_parent_is_the_crate_source_directory() {
    let good = GoodDependency::new("shape");
    let src_path = good.root.join("src").join("lib.rs");
    assert_eq!(
        Path::new(&src_path).parent(),
        Some(good.root.join("src").as_path()),
        "the fixture must mirror cargo's own `src_path` shape"
    );
}
