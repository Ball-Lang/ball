//! Crate-aware encoding (issue #491): `ball_lang_encoder::encode_crate` walks a
//! crate's `mod` graph and encodes every file with SHARED knowledge of the
//! crate's types, `impl` blocks and free functions, so a call whose callee is
//! declared in another file resolves into an ordinary Ball call / method
//! dispatch instead of failing loud.
//!
//! ## What a single-file encode could not do, and why
//!
//! `rust/encoder/src/methods.rs`'s catch-all fires for a
//! `receiver.method(args)` whose method is neither a recognized built-in arm
//! nor a same-file `impl` method — **24 of the 196 files** in issue #491's
//! real-code study, the largest remaining bucket, pinned (without being
//! closed) by `documented_gaps.rs::cross_file_method_call_is_a_documented_gap`
//! since PR #589. The free-function fix that landed in #526 worked because
//! `other_file::helper(...)` carries a module-qualifying path segment the
//! encoder can read straight off the syntax; `receiver.method(args)` carries
//! no such qualifier, and this encoder is syntax-only (`syn`, no semantic
//! model), so nothing in ONE file can tell a sibling-file instance method from
//! a typo. The owner's 2026-09-13 decision on #491 was therefore to add a
//! crate-aware entry point — the Rust sibling of Dart's
//! `dart/encoder/lib/package_encoder.dart` — rather than widen the
//! dispatch table or degrade the call into an unresolvable import.
//!
//! ## The proof is end-to-end, not structural
//!
//! The headline test encodes the fixture crate, compiles the resulting Ball
//! program back to Rust with `ball-lang-compiler`, builds it with cargo and
//! **runs it**, asserting the crate's own output. A structural assertion about
//! a `FunctionCall`'s `module` field would pass just as well against a program
//! that does not link; only running it proves the cross-file resolution lands
//! on a real dispatcher. `compile_and_run` mirrors
//! `rust/encoder/tests/end_to_end.rs`'s harness exactly.
use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

use ball_lang_compiler::Compiler;
use ball_lang_shared::proto::ball::v1::Program;

// ════════════════════════════════════════════════════════════
// rustc/cargo execution harness (mirrors rust/encoder/tests/end_to_end.rs)
// ════════════════════════════════════════════════════════════

static FIXTURE_COUNTER: AtomicU64 = AtomicU64::new(0);

fn workspace_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("rust/encoder must have a parent directory")
        .to_path_buf()
}

/// The checked-in fixture crate `name` lives under `rust/encoder/tests/fixtures/`.
fn fixture_crate(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join(name)
}

/// Build `rust_src` as a one-file cargo package against the workspace's own
/// `ball-lang-shared`, run it, and return its stdout. Every fixture package's
/// name is unique (pid + counter) because all of them share one workspace
/// `target/` — see `end_to_end.rs`'s own note on why a constant bin name raced.
fn compile_and_run(fixture_name: &str, rust_src: &str) -> String {
    let workspace_root = workspace_root();
    let target_dir = workspace_root.join("target");
    let unique = FIXTURE_COUNTER.fetch_add(1, Ordering::Relaxed);
    let slug = format!("{fixture_name}_{}_{unique}", std::process::id());
    let fixture_dir = std::env::temp_dir().join(format!("ball_crate_rustc_fixture_{slug}"));
    fs::create_dir_all(&fixture_dir).unwrap_or_else(|err| {
        panic!(
            "failed to create fixture dir {}: {err}",
            fixture_dir.display()
        )
    });

    let shared_path = workspace_root.join("shared");
    let bin_name = format!("ball_crate_fixture_{slug}");
    let manifest = format!(
        "[package]\nname = \"{bin_name}\"\nversion = \"0.0.0\"\nedition = \"2024\"\npublish = false\n\n\
         [[bin]]\nname = \"{bin_name}\"\npath = \"main.rs\"\n\n\
         [dependencies]\nball-lang-shared = {{ path = {:?} }}\n",
        shared_path
    );
    fs::write(fixture_dir.join("Cargo.toml"), manifest)
        .expect("failed to write fixture Cargo.toml");
    fs::write(fixture_dir.join("main.rs"), rust_src).expect("failed to write fixture main.rs");

    let manifest_path = fixture_dir.join("Cargo.toml");
    let build = Command::new("cargo")
        .args(["build", "--quiet"])
        .arg("--manifest-path")
        .arg(&manifest_path)
        .arg("--target-dir")
        .arg(&target_dir)
        .output()
        .expect("failed to spawn `cargo build` — is cargo on PATH?");

    if !build.status.success() {
        panic!(
            "fixture '{fixture_name}' failed to COMPILE.\n--- generated main.rs ---\n{rust_src}\n\
             --- stdout ---\n{}\n--- stderr ---\n{}",
            String::from_utf8_lossy(&build.stdout),
            String::from_utf8_lossy(&build.stderr),
        );
    }

    let exe = target_dir.join("debug").join(if cfg!(windows) {
        format!("{bin_name}.exe")
    } else {
        bin_name.clone()
    });
    let output = Command::new(&exe).output().unwrap_or_else(|err| {
        panic!(
            "fixture '{fixture_name}' built but its binary {} could not be run: {err}",
            exe.display()
        )
    });

    let _ = fs::remove_dir_all(&fixture_dir);
    let _ = fs::remove_file(&exe);
    for sidecar in ["d", "pdb"] {
        let _ = fs::remove_file(
            target_dir
                .join("debug")
                .join(format!("{bin_name}.{sidecar}")),
        );
    }

    if !output.status.success() {
        panic!(
            "fixture '{fixture_name}' failed to run.\n--- generated main.rs ---\n{rust_src}\n\
             --- stdout ---\n{}\n--- stderr ---\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }

    String::from_utf8(output.stdout).expect("fixture stdout must be valid UTF-8")
}

fn module_names(program: &Program) -> BTreeSet<String> {
    program.modules.iter().map(|m| m.name.clone()).collect()
}

// ════════════════════════════════════════════════════════════
// The headline proof: a three-file crate encodes, compiles and RUNS
// ════════════════════════════════════════════════════════════

/// `main.rs` calls `c.bump(3)` — a method declared in `counter.rs` — and
/// `describe(total)`, a free function declared in `text.rs` and reached by its
/// bare name through a `use`. Neither resolves in a single-file encode; both
/// must resolve here. The result is then passed through `live::stamp`, which
/// lives in the `#[cfg(not(test))]` module `live.rs` — a module `cargo build`
/// compiles and issue #626's predicate bug silently DROPPED, so a regression
/// there cannot reach this assertion: the generated program would not compile
/// at all. The crate must actually print `total=5 live`.
///
/// `2 + 3 = 5` is hand-computed from the fixture's own Rust source, not read
/// off any run — the same discipline `end_to_end.rs` documents for its own
/// expected values.
#[test]
fn the_fixture_crate_encodes_compiles_and_runs() {
    let program = ball_lang_encoder::encode_crate(&fixture_crate("counter_crate"));
    assert_eq!(
        program.entry_function, "main",
        "the crate root declares `fn main`, so the encoded program is runnable"
    );
    let compiled = Compiler::new(&program).compile();
    let stdout = compile_and_run("counter_crate", &compiled);
    assert_eq!(
        stdout.trim(),
        "total=5 live",
        "the cross-file method call, the cross-file free call and the \
         `#[cfg(not(test))]` module must all resolve.\n--- generated main.rs ---\n{compiled}"
    );
}

/// A `#[cfg(not(test))]` module is part of every ordinary `cargo build`, so the
/// walk must keep it. Issue #626: the predicate scanned the whole token tree
/// for a bare `test` ident, matched the one inside `not(...)`, and dropped the
/// module — its symbols vanished from the crate table with no diagnostic, which
/// is exactly the silent scope loss this module's "a missing module is a loud
/// panic" posture exists to prevent.
#[test]
fn a_cfg_not_test_module_is_walked() {
    let program = ball_lang_encoder::encode_crate(&fixture_crate("counter_crate"));
    let names = module_names(&program);
    assert!(
        names.contains("live"),
        "`#[cfg(not(test))] mod live;` is compiled by `cargo build` and must be encoded: {names:?}"
    );
}

/// The crate root may be given three ways — the directory holding `Cargo.toml`,
/// the `src` directory, or the root source file itself — and all three must
/// produce the identical program. Anything else would make `ball encode
/// --crate` depend on how the user happened to spell the path.
#[test]
fn the_crate_root_may_be_a_manifest_dir_a_src_dir_or_the_root_file() {
    let from_manifest_dir = ball_lang_encoder::encode_crate(&fixture_crate("counter_crate"));
    let from_src_dir = ball_lang_encoder::encode_crate(&fixture_crate("counter_crate").join("src"));
    let from_root_file =
        ball_lang_encoder::encode_crate(&fixture_crate("counter_crate").join("src/main.rs"));
    assert_eq!(from_manifest_dir, from_src_dir);
    assert_eq!(from_manifest_dir, from_root_file);
}

/// One Ball module per Rust module, named by its Rust module path — the crate
/// root is `main` (what `Program.entry_module` must name), every other module
/// keeps its `::`-joined path. The compiler's `compile` already nests every
/// non-entry user module under its own `pub mod` (issue #38), which is what
/// makes cross-module dispatch resolve without any compiler change.
#[test]
fn every_rust_module_becomes_its_own_ball_module() {
    let program = ball_lang_encoder::encode_crate(&fixture_crate("counter_crate"));
    let names = module_names(&program);
    for expected in ["main", "counter", "text", "live"] {
        assert!(
            names.contains(expected),
            "module `{expected}` is missing from {names:?}"
        );
    }
}

// ════════════════════════════════════════════════════════════
// mod-graph resolution, per the Rust reference
// ════════════════════════════════════════════════════════════

/// Every out-of-line resolution shape the Rust reference documents
/// (<https://doc.rust-lang.org/reference/items/modules.html>), in one crate:
///
/// | declaration | in | resolves to |
/// | --- | --- | --- |
/// | `pub mod alpha;` | `src/lib.rs` (mod-rs) | `src/alpha/mod.rs` |
/// | `#[path = "renamed.rs"] pub mod beta;` | `src/lib.rs` | `src/renamed.rs` |
/// | `pub mod gamma;` | `src/lib.rs` | `src/gamma.rs` |
/// | `pub mod deep;` | `src/gamma.rs` (non-mod-rs) | `src/gamma/deep.rs` |
/// | `pub mod inner { … }` | `src/gamma.rs` | the same file, own module |
#[test]
fn the_mod_graph_walk_covers_every_documented_resolution_shape() {
    let program = ball_lang_encoder::encode_crate(&fixture_crate("modgraph_crate"));
    let names = module_names(&program);
    for expected in [
        "main",
        "alpha",
        "beta",
        "gamma",
        "gamma::deep",
        "gamma::inner",
    ] {
        assert!(
            names.contains(expected),
            "module `{expected}` is missing from {names:?}"
        );
    }
}

/// `#[path]` on an **inline** `mod` block rebases the modules declared inside
/// it. The Rust reference's own combined example
/// (<https://doc.rust-lang.org/reference/items/modules.html>, "The `path`
/// attribute"), quoted verbatim:
///
/// ```text
/// #[path = "thread_files"]
/// mod thread {
///     // Load the `local_data` module from `thread_files/tls.rs` relative to
///     // this source file's directory.
///     #[path = "tls.rs"]
///     mod local_data;
/// }
/// ```
///
/// Before issue #626 the walker ignored the `#[path]` on the inline block and
/// looked for `<dir>/thread/tls.rs`, so this crate failed loud with "could not
/// find the source file for module `local_data`" — a documented-nowhere
/// deviation from the reference.
#[test]
fn a_path_attribute_on_an_inline_mod_block_rebases_its_children() {
    let dir = scratch_crate(
        "inline_path_base",
        &[
            (
                "src/main.rs",
                "#[path = \"thread_files\"]\n\
                 mod thread {\n\
                     #[path = \"tls.rs\"]\n\
                     pub mod local_data;\n\
                 }\n\
                 fn main() {}",
            ),
            ("src/thread_files/tls.rs", "pub fn key() -> i64 { 7 }"),
        ],
    );
    let program = ball_lang_encoder::encode_crate(&dir);
    let names = module_names(&program);
    assert!(
        names.contains("thread::local_data"),
        "`#[path = \"thread_files\"]` on the inline block must rebase its child to \
         `thread_files/tls.rs`: {names:?}"
    );
    let local_data = program
        .modules
        .iter()
        .find(|m| m.name == "thread::local_data")
        .expect("the module is present, per the assertion above");
    assert!(
        local_data.functions.iter().any(|f| f.name == "key"),
        "the rebased module must carry the declarations of `thread_files/tls.rs`, not an empty \
         shell: {:?}",
        local_data
            .functions
            .iter()
            .map(|f| f.name.clone())
            .collect::<Vec<_>>()
    );
}

/// `cargo build` does not compile a `#[cfg(test)]` module and neither does the
/// walk. The fixture's `src/tests.rs` contains an `assert!`, which the encoder
/// has no mapping for — so if the walk ever picked it up, this test would fail
/// loud with "unsupported macro invocation" rather than quietly gaining a
/// module.
#[test]
fn a_cfg_test_module_is_not_walked() {
    let program = ball_lang_encoder::encode_crate(&fixture_crate("modgraph_crate"));
    let names = module_names(&program);
    assert!(
        !names.contains("tests"),
        "a `#[cfg(test)]` module must not be encoded: {names:?}"
    );
}

/// A crate with no `fn main` is encoded with the library-mode semantics #569
/// established for a single file: an empty `entry_function`, structurally legal
/// and deliberately not runnable, never a synthesised fake entry point. The
/// entry MODULE is still `main` because `compile_library` inlines that module's
/// items at the crate root.
#[test]
fn a_crate_without_a_main_encodes_in_library_mode() {
    let program = ball_lang_encoder::encode_crate(&fixture_crate("modgraph_crate"));
    assert_eq!(program.entry_module, "main");
    assert_eq!(
        program.entry_function, "",
        "a library crate has no entry point to run"
    );
    let compiled = Compiler::new(&program).compile_library();
    for expected in ["pub fn one", "pub fn two", "pub fn three", "pub fn four"] {
        assert!(
            compiled.contains(expected),
            "`{expected}` is missing from the compiled library:\n{compiled}"
        );
    }
}

/// `rust/encoder/src/lib.rs`'s module doc listed this as a **known limitation**
/// of the single-file cross-file-call fallback: a `crate::`/`self::`-qualified
/// call was treated as external, so `crate::helper(1)` became an unresolved
/// `crate` import instead of resolving to a real function. A crate walk knows
/// what `crate` and `self` name, so both resolve here — and `crate::` paths are
/// how real multi-file crates address each other, which makes this the shape
/// the sweep meets most often after the method call itself.
#[test]
fn crate_and_self_qualified_calls_resolve_within_the_crate() {
    let dir = scratch_crate(
        "qualified_paths",
        &[
            (
                "src/main.rs",
                "mod helpers;\n\
                 fn twice(n: i64) -> i64 { n * 2 }\n\
                 fn main() { println!(\"{}\", crate::helpers::bump(self::twice(4))); }",
            ),
            ("src/helpers.rs", "pub fn bump(n: i64) -> i64 { n + 1 }"),
        ],
    );
    let program = ball_lang_encoder::encode_crate(&dir);
    assert!(
        !program
            .modules
            .iter()
            .any(|m| m.name == "crate" || m.name == "self"),
        "`crate`/`self` are path qualifiers, never modules of their own: {:?}",
        module_names(&program)
    );
    let compiled = Compiler::new(&program).compile();
    assert_eq!(compile_and_run("qualified_paths", &compiled).trim(), "9");
}

// ════════════════════════════════════════════════════════════
// The boundary the crate walk NARROWS but does not remove
// ════════════════════════════════════════════════════════════

/// Crate-awareness closes "the callee is in another file of this crate"; it
/// does not and cannot close "the callee is nowhere". A method no file in the
/// crate declares still fails loud — a syntax-only encoder has no way to tell
/// that from a typo or an unsupported built-in, and silently inventing a
/// dispatch target is exactly the degradation this crate's fail-loud posture
/// exists to prevent.
#[test]
#[should_panic(expected = "unsupported method call")]
fn a_method_no_file_in_the_crate_declares_still_fails_loud() {
    let dir = scratch_crate(
        "undeclared_method",
        &[
            (
                "src/main.rs",
                "mod counter;\nuse counter::Counter;\n\
                 fn main() { let c = Counter::new(1); println!(\"{}\", c.nope()); }",
            ),
            (
                "src/counter.rs",
                "pub struct Counter { pub total: i64 }\n\
                 impl Counter { pub fn new(start: i64) -> Counter { Counter { total: start } } }",
            ),
        ],
    );
    let _ = ball_lang_encoder::encode_crate(&dir);
}

/// A `mod foo;` whose file is absent is a loud error naming both candidate
/// paths, never a silently missing module — a dropped module would take every
/// declaration in it with it.
#[test]
#[should_panic(expected = "could not find the source file for module")]
fn a_mod_declaration_with_no_file_fails_loud() {
    let dir = scratch_crate(
        "missing_mod_file",
        &[("src/main.rs", "mod ghost;\nfn main() {}")],
    );
    let _ = ball_lang_encoder::encode_crate(&dir);
}

/// Two files declaring the same instance-method short name is genuinely
/// ambiguous for a syntax-only encoder: the compiler's dispatcher resolves by
/// short name within a module, so picking one would silently dispatch a call on
/// a value of the OTHER type to the wrong body. It fails loud instead, naming
/// both modules.
#[test]
#[should_panic(expected = "declared in more than one module")]
fn an_ambiguous_cross_file_method_name_fails_loud() {
    let dir = scratch_crate(
        "ambiguous_method",
        &[
            (
                "src/main.rs",
                "mod a;\nmod b;\nuse a::A;\nfn main() { let v = A::new(1); println!(\"{}\", v.size()); }",
            ),
            (
                "src/a.rs",
                "pub struct A { pub n: i64 }\n\
                 impl A { pub fn new(n: i64) -> A { A { n } } pub fn size(&self) -> i64 { self.n } }",
            ),
            (
                "src/b.rs",
                "pub struct B { pub n: i64 }\n\
                 impl B { pub fn size(&self) -> i64 { self.n } }",
            ),
        ],
    );
    let _ = ball_lang_encoder::encode_crate(&dir);
}

/// Writes a throwaway crate under the OS temp dir and returns its root. The
/// loud-failure shapes MUST use this rather than a checked-in fixture — a
/// checked-in crate that cannot encode reads as a broken fixture rather than as
/// an asserted boundary — and the one-shape positive cases use it too, rather
/// than growing a third checked-in crate for a two-file point.
fn scratch_crate(name: &str, files: &[(&str, &str)]) -> PathBuf {
    let unique = FIXTURE_COUNTER.fetch_add(1, Ordering::Relaxed);
    let dir = std::env::temp_dir().join(format!(
        "ball_crate_scratch_{name}_{}_{unique}",
        std::process::id()
    ));
    let _ = fs::remove_dir_all(&dir);
    for (rel, source) in files {
        let path = dir.join(rel);
        fs::create_dir_all(path.parent().expect("a fixture file has a parent"))
            .expect("failed to create the scratch crate directory");
        fs::write(&path, source).expect("failed to write a scratch crate file");
    }
    write_scratch_manifest(&dir, name);
    dir
}

fn write_scratch_manifest(dir: &Path, name: &str) {
    let manifest = format!(
        "[package]\nname = \"ball-scratch-{name}\"\nversion = \"0.0.0\"\n\
         edition = \"2024\"\npublish = false\n"
    );
    fs::write(dir.join("Cargo.toml"), manifest).expect("failed to write the scratch manifest");
}
