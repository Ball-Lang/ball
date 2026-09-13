//! Issue #678 — a dependency source PATH the walk cannot look at must be
//! recorded, exactly as an unreadable dependency FILE already is.
//!
//! `deps.rs::rust_files_under` is the one place in the crate where "not found"
//! and "could not look" were conflated: a directory whose `read_dir` failed, an
//! entry whose metadata could not be stat'ed, were both dropped on the floor,
//! while an unreadable or unparseable *file* on the same walk went through
//! `note_unreadable_source` and surfaced in the next failing resolution. A
//! `#[macro_export]`ed macro behind a permission-denied subdirectory therefore
//! reported as "no `macro_rules!` with that name is in scope" — an assertion
//! the walk had no evidence for.
//!
//! Both tests below build a throwaway two-crate cargo tree in the system temp
//! directory and seed a real `MacroTable` from it through
//! `cargo metadata`, so what they exercise is the shipped path, not a stub.
//! Each carries a POSITIVE FLOOR: the readable half of the same dependency must
//! have contributed its macro, otherwise a fixture that simply failed to build
//! would "pass" by producing no definitions at all.

use ball_lang_macro_expand::{Expansion, MacroError, MacroTable};
use std::path::{Path, PathBuf};

/// A two-crate cargo tree — a consumer and one path dependency — in a unique
/// directory under the system temp dir, removed on drop.
///
/// Both manifests carry an explicit empty `[workspace]` table so neither can be
/// adopted by a workspace that happens to live in an ancestor of the temp
/// directory; the tree is never compiled, only read by `cargo metadata`.
struct Fixture {
    root: PathBuf,
}

impl Fixture {
    fn new(tag: &str) -> Fixture {
        let unique = format!(
            "ball-macro-expand-{tag}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("the system clock is after the unix epoch")
                .as_nanos()
        );
        let root = std::env::temp_dir().join(unique);
        let fixture = Fixture { root };

        fixture.write(
            "consumer/Cargo.toml",
            r#"[package]
name = "unreadable_dep_consumer"
version = "0.0.0"
edition = "2021"

[dependencies]
unreadable_dep = { path = "../dependency" }

[workspace]
"#,
        );
        fixture.write("consumer/src/lib.rs", "");

        fixture.write(
            "dependency/Cargo.toml",
            r#"[package]
name = "unreadable_dep"
version = "0.0.0"
edition = "2021"

[workspace]
"#,
        );
        // `#[macro_export]` hoists a macro to the crate root whatever module
        // declares it, so the walk reads every `.rs` file under `src/` — these
        // `mod` declarations are here for realism only.
        fixture.write(
            "dependency/src/lib.rs",
            "pub mod visible;\npub mod locked;\n",
        );
        fixture.write(
            "dependency/src/visible.rs",
            "#[macro_export]\nmacro_rules! visible_dep_macro { () => { const FIXTURE_VISIBLE: u8 = 1; }; }\n",
        );
        fixture.write(
            "dependency/src/locked/mod.rs",
            "#[macro_export]\nmacro_rules! locked_dep_macro { () => { const FIXTURE_LOCKED: u8 = 2; }; }\n",
        );
        fixture
    }

    fn write(&self, relative: &str, contents: &str) {
        let path = self.root.join(relative);
        std::fs::create_dir_all(
            path.parent()
                .expect("every fixture path has a parent directory"),
        )
        .expect("the fixture's temp directory must be creatable");
        std::fs::write(&path, contents).expect("the fixture's files must be writable");
    }

    /// The consumer manifest — what `seed_from_cargo_metadata` is given.
    fn manifest(&self) -> PathBuf {
        self.root.join("consumer").join("Cargo.toml")
    }

    fn dependency_src(&self) -> PathBuf {
        self.root.join("dependency").join("src")
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        // A mode-000 directory cannot be removed recursively until it is
        // readable again; a leaked temp tree would break the NEXT run.
        #[cfg(unix)]
        restore_readability(&self.root);
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[cfg(unix)]
fn restore_readability(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    let Ok(meta) = std::fs::symlink_metadata(path) else {
        return;
    };
    if !meta.is_dir() {
        return;
    }
    let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755));
    let Ok(entries) = std::fs::read_dir(path) else {
        return;
    };
    for entry in entries.flatten() {
        restore_readability(&entry.path());
    }
}

/// A table seeded from the fixture's consumer crate, with the readable half of
/// the dependency proven to have been walked.
fn seeded(fixture: &Fixture) -> MacroTable {
    let mut table = MacroTable::new();
    table.seed_from_cargo_metadata(&fixture.manifest());
    assert!(
        table.names().iter().any(|name| name == "visible_dep_macro"),
        "positive floor: the READABLE half of the fixture dependency must have been walked, \
         otherwise this test would pass on a tree `cargo metadata` never resolved at all. \
         In scope: {:?}",
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
        .expect_err("the fixture's macro is behind a path the walk could not read")
}

/// A `read_dir` the process is not permitted to perform is "could not look",
/// not "not there" — and the resolution failure that follows must say so.
///
/// `#[cfg(unix)]`: mode bits are the portable way to make a directory
/// unreadable to its own owner, and Windows has no equivalent one-call
/// equivalent (an ACL denying the owner needs `icacls`/Win32 and is undone by
/// the owner's WRITE_DAC right anyway). The Rust CI job runs on
/// `ubuntu-latest`, so this is gated, never skipped — and `dangling_symlink…`
/// below covers the same conflation on EVERY OS.
#[cfg(unix)]
#[test]
fn unreadable_dependency_directory_is_named_in_the_diagnostic() {
    use std::os::unix::fs::PermissionsExt;

    let fixture = Fixture::new("locked");
    let locked = fixture.dependency_src().join("locked");
    std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o000))
        .expect("the fixture's own directory must be chmod-able");
    assert!(
        std::fs::read_dir(&locked).is_err(),
        "precondition: this test must run as an unprivileged user — root ignores mode 000, so \
         the directory at {} would be walked and the conflation under test could not occur",
        locked.display()
    );

    let table = seeded(&fixture);
    let locked_path = locked.display().to_string();

    // Bare name: the macro is `#[macro_export]`ed, so `use unreadable_dep::
    // locked_dep_macro;` makes this the ordinary spelling.
    let bare = expansion_error(&table, "locked_dep_macro!();");
    assert!(
        matches!(bare, MacroError::Unresolved { .. }),
        "expected an Unresolved for the bare spelling, got {bare:?}"
    );
    assert!(
        bare.to_string().contains(&locked_path),
        "the diagnostic must name the directory that could not be read ({locked_path}); got: {bare}"
    );

    // Qualified path: a different variant, and it used to state outright that
    // the crate's library target has no such macro — which the walk could not
    // know once part of that target was unreadable.
    let qualified = expansion_error(&table, "unreadable_dep::locked_dep_macro!();");
    assert!(
        matches!(qualified, MacroError::DependenciesUnavailable { .. }),
        "expected a DependenciesUnavailable for the qualified spelling, got {qualified:?}"
    );
    assert!(
        qualified.to_string().contains(&locked_path),
        "the diagnostic must name the directory that could not be read ({locked_path}); \
         got: {qualified}"
    );
}

/// The walk classifies entries with `Path::is_dir`, which follows symlinks
/// (`std::fs::metadata`), so a symlink whose target is gone is a path the walk
/// cannot look at — on every OS. It is neither a directory it can descend nor a
/// file it can read, and before #678 it was dropped without a word.
#[test]
fn dangling_symlink_in_dependency_sources_is_named_in_the_diagnostic() {
    let fixture = Fixture::new("dangling");
    let dangling = fixture.dependency_src().join("gone");
    symlink_dir(
        &fixture.dependency_src().join("no_such_directory"),
        &dangling,
    );
    assert!(
        std::fs::metadata(&dangling).is_err(),
        "precondition: the fixture symlink at {} must dangle",
        dangling.display()
    );

    let table = seeded(&fixture);
    let dangling_path = dangling.display().to_string();
    let err = expansion_error(&table, "macro_behind_the_dangling_link!();");
    assert!(
        err.to_string().contains(&dangling_path),
        "the diagnostic must name the path that could not be looked at ({dangling_path}); \
         got: {err}"
    );
}

/// Create a directory symlink, failing LOUD rather than skipping: a test that
/// quietly opts out on one platform is a fake green.
///
/// On Windows this needs `SeCreateSymbolicLinkPrivilege` — granted by Developer
/// Mode or an elevated shell. The repository's Rust surface is Linux/WSL and
/// CI's `rust` job is `ubuntu-latest`, so the panic is a configuration message,
/// not an expected outcome.
fn symlink_dir(target: &Path, link: &Path) {
    #[cfg(unix)]
    let result = std::os::unix::fs::symlink(target, link);
    #[cfg(windows)]
    let result = std::os::windows::fs::symlink_dir(target, link);
    #[cfg(not(any(unix, windows)))]
    let result: std::io::Result<()> = Err(std::io::Error::other(
        "no symlink API is known for this platform",
    ));
    result.unwrap_or_else(|err| {
        panic!(
            "could not create the fixture symlink {} -> {}: {err}. On Windows this needs \
             symlink-creation privilege (enable Developer Mode, or run elevated).",
            link.display(),
            target.display()
        )
    });
}
