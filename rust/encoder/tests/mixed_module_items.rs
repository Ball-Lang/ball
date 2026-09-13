//! Declarations Ball models nothing for, sitting beside real code (issue
//! #491): a top-level `const`/`static`/`type` alias at **module** scope, and
//! an associated `const`/`type` inside a **`trait`** block.
//!
//! ## Why this bucket matters
//!
//! Both sites used to abort the entire file on the first such declaration:
//!
//! - `rust/encoder/src/lib.rs`'s pass-2 `match` had no arm for
//!   `syn::Item::Const`/`Static`/`Type`, so they fell through to the
//!   `unsupported top-level item` panic. A top-level `type` alias is the
//!   FIRST blocker for **7 of the 110 scored files** in the live Tier A
//!   funnel (`tools/coverage-study/packages/rust.json`'s pin set).
//! - `rust/encoder/src/types.rs::encode_item_trait` panicked
//!   (`only method signatures are supported inside a trait block`) the instant
//!   its loop reached a `TraitItem` that was not an `Fn` — **3 of the 110**.
//!
//! The precedent for skipping instead is one level down and already landed:
//! `types.rs::encode_item_impl` skips a non-`Fn` **`impl`** item (see
//! `mixed_impl_items.rs`), and the pre-passes over the very same syntax
//! (`collect_impl_method_params`, `collect_trait_static_params`) have always
//! skipped silently. This makes all of those passes agree.
//!
//! ## Why skipping is safe here — and what keeps it honest
//!
//! Dropping a declaration is exactly the kind of change that can silently
//! produce wrong output, so two things are asserted, not one:
//!
//! 1. A file carrying such declarations beside real code travels encoder →
//!    compiler → `cargo build` → execution and prints the right number. The
//!    expected stdout is hand-computed from the semantics of the original
//!    Rust source, never read off a run.
//! 2. A real *reference* to a skipped module-scope declaration still fails
//!    **loud**. That guard is not free the way `impl`'s is: `Self::CAP` is a
//!    two-segment path and lands on `lib.rs`'s pre-existing "unsupported path
//!    expression" panic on its own, but a bare `LIMIT` is a single-segment
//!    path that `encode_path_expr` would otherwise pass straight through its
//!    `reference(name)` fallback — a dangling reference to a binding nobody
//!    declared. So the encoder records what it skipped and panics at the use
//!    site. The characterization for that lives in
//!    `documented_gaps.rs::reference_to_a_skipped_top_level_const_is_a_documented_gap`.
//!
//! A top-level **macro invocation** is deliberately left panicking — see
//! `documented_gaps.rs::top_level_macro_invocation_is_a_documented_gap`.
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

use ball_lang_compiler::Compiler;

/// Module-scope `const`/`static`/`type` alias and trait-scope associated
/// `const`/`type`, all declared but never referenced, sitting beside a struct
/// with a real method and a default-bodied receiver-less trait fn that IS
/// called. Every one of these declarations used to abort the whole file.
///
/// `Square { side: 3 }.area()` is 9 and `Shape::origin()` is 2, so the
/// program prints 11 — computed from the Rust source above, not from a run.
const MIXED_MODULE_SOURCE: &str = r#"
const LIMIT: i64 = 10;

static GREETING: i64 = 2;

type Coord = i64;

trait Shape {
    const SIDES: i64 = 4;

    type Unit;

    fn origin() -> i64 {
        2
    }

    fn tag(&self) -> i64 {
        1
    }
}

struct Square {
    side: i64,
}

impl Square {
    fn area(&self) -> i64 {
        self.side * self.side
    }
}

fn main() {
    let s = Square { side: 3 };
    println!("{}", s.area() + Shape::origin());
}
"#;

static FIXTURE_COUNTER: AtomicU64 = AtomicU64::new(0);

fn workspace_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("rust/encoder must have a parent directory")
        .to_path_buf()
}

/// Build and run `rust_src` in a scratch cargo package — the same harness
/// `end_to_end.rs`/`static_methods.rs`/`mixed_impl_items.rs` use (unique
/// package/bin name so parallel fixtures never collide; the shared workspace
/// `target/` so the already-built `ball-lang-shared` dependency tree is
/// reused; every artifact cleaned up, including on failure).
fn compile_and_run(fixture_name: &str, rust_src: &str) -> String {
    let workspace_root = workspace_root();
    let target_dir = workspace_root.join("target");
    let unique = FIXTURE_COUNTER.fetch_add(1, Ordering::Relaxed);
    let slug = format!("{fixture_name}_{}_{unique}", std::process::id());
    let fixture_dir =
        std::env::temp_dir().join(format!("ball_encoder_mixed_module_fixture_{slug}"));
    fs::create_dir_all(&fixture_dir).unwrap_or_else(|err| {
        panic!(
            "failed to create fixture dir {}: {err}",
            fixture_dir.display()
        )
    });

    let shared_path = workspace_root.join("shared");
    let bin_name = format!("ball_encoder_mixed_module_fixture_{slug}");
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
        let _ = fs::remove_dir_all(&fixture_dir);
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

#[test]
fn module_and_trait_scope_non_fn_declarations_encode_and_round_trip() {
    let program = ball_lang_encoder::encode(MIXED_MODULE_SOURCE);
    let main_module = program
        .modules
        .iter()
        .find(|m| m.name == "main")
        .expect("the encoded program must carry a `main` module");

    // ── Real code survives the skipped declarations sitting beside it ──
    for member in ["main:Square.area", "main:Shape.origin", "main:Shape.tag"] {
        let found = main_module
            .functions
            .iter()
            .find(|f| f.name == member)
            .unwrap_or_else(|| {
                panic!(
                    "`{member}` must encode even though module- and trait-scope \
                     const/static/type declarations sit beside it; encoded members: {:?}",
                    main_module
                        .functions
                        .iter()
                        .map(|f| f.name.as_str())
                        .collect::<Vec<_>>()
                )
            });
        assert!(found.body.is_some(), "`{member}` must carry its body");
    }

    // ── The skipped declarations leave no phantom behind ──
    for phantom in ["LIMIT", "GREETING", "Coord", "SIDES", "Unit"] {
        assert!(
            !main_module
                .functions
                .iter()
                .any(|f| f.name.contains(phantom)),
            "`{phantom}` must be SKIPPED, never encoded as a member: {:?}",
            main_module
                .functions
                .iter()
                .map(|f| f.name.as_str())
                .collect::<Vec<_>>()
        );
        assert!(
            !main_module
                .type_defs
                .iter()
                .any(|t| t.name.contains(phantom)),
            "`{phantom}` must be SKIPPED, never encoded as a TypeDefinition: {:?}",
            main_module
                .type_defs
                .iter()
                .map(|t| t.name.as_str())
                .collect::<Vec<_>>()
        );
    }

    // ── The real round trip: it compiles to Rust and prints 11 ──
    let compiled = Compiler::new(&program).compile();
    let stdout = compile_and_run("mixed_module_items", &compiled);
    assert_eq!(
        stdout.trim(),
        "11",
        "Square {{ side: 3 }}.area() + Shape::origin() == 9 + 2\n\
         --- generated main.rs ---\n{compiled}"
    );
}

/// The skip is scoped to what it claims: a module-scope declaration whose
/// name IS referenced still fails loud, rather than encoding as a read of a
/// binding nobody declared. Asserted on the message, not just on "it
/// panicked", because the whole point is that the diagnostic names the
/// skipped declaration instead of surfacing as a mystery downstream.
#[test]
fn a_referenced_module_scope_const_fails_loud_naming_the_declaration() {
    for (source, name) in [
        (
            "const LIMIT: i64 = 10;\nfn main() { println!(\"{}\", LIMIT); }",
            "LIMIT",
        ),
        (
            "static GREETING: i64 = 2;\nfn main() { println!(\"{}\", GREETING); }",
            "GREETING",
        ),
    ] {
        let err = std::panic::catch_unwind(|| ball_lang_encoder::encode(source))
            .expect_err("referencing a skipped module-scope declaration must panic");
        let message = err
            .downcast_ref::<String>()
            .map(String::as_str)
            .or_else(|| err.downcast_ref::<&str>().copied())
            .unwrap_or("<non-string panic payload>")
            .to_string();
        assert!(
            message.contains(name) && message.contains("names a top-level `const`"),
            "the panic must name the skipped declaration `{name}`, got: {message}"
        );
    }
}
