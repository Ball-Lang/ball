//! Library-mode encoding (issue #491, slice 2): source with **no `fn
//! main()`** — the shape every real library crate has — encoded through
//! [`ball_lang_encoder::encode_library`] and then compiled back into a real
//! Rust **library crate** via `ball-lang-compiler`'s
//! [`Compiler::compile_library`].
//!
//! ## Why this is a round-trip proof, not a shape assertion
//!
//! `rust/encoder/tests/end_to_end.rs` proves the `fn main` path by compiling
//! the encoded `Program` and *running* it. A library has nothing to run — its
//! whole contract is "this is a valid crate other code can call into" — so the
//! equivalent proof here is that `cargo build` accepts the compiled output as a
//! `[lib]` target (the same `cargo`-in-a-scratch-package harness
//! `end_to_end.rs` uses, minus the execution step). A `Program` whose functions
//! encoded to a broken tree would fail to compile, exactly as it would there.
//!
//! ## The deliberate boundary
//!
//! A library-mode `Program` carries `entry_module = "main"` (so
//! `compile_library` can find the module whose items are inlined at the crate
//! root) but an **empty `entry_function`**. That makes it structurally legal
//! (`Program.entry_function` is an unconstrained proto3 string) and
//! deliberately **not runnable**: `ball check` reports "missing
//! entry_function" and `ball run` has nothing to call. That is the documented
//! contract, mirrored exactly by the C# encoder's `EncodeLibrary` — never
//! paper over it by synthesising a fake entry function.
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

use ball_lang_compiler::Compiler;

/// A library-shaped Rust file: no `fn main()`, a mix of `pub` and private
/// top-level functions, and enough surface (arithmetic, control flow, a
/// `Vec` push) that both `std` and `std_collections` must be accumulated.
const LIBRARY_SOURCE: &str = r#"
pub fn double(n: i64) -> i64 {
    n * 2
}

pub fn evens(limit: i64) -> Vec<i64> {
    let mut out = vec![];
    for i in 0..limit {
        if i % 2 == 0 {
            out.push(i);
        }
    }
    out
}

fn describe(n: i64) -> String {
    if n > 0 {
        String::from("positive")
    } else {
        String::from("non-positive")
    }
}
"#;

static FIXTURE_COUNTER: AtomicU64 = AtomicU64::new(0);

fn workspace_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("rust/encoder must have a parent directory")
        .to_path_buf()
}

/// Build `rust_src` as a **library** crate in a scratch cargo package, the
/// same way `end_to_end.rs`'s `compile_and_run` builds a binary one (unique
/// package name so parallel fixtures never collide, the shared workspace
/// `target/` so the already-built `ball-lang-shared` dependency tree is
/// reused). A `[lib]` target produces an `.rlib` under
/// `target/debug/deps/`, which nothing else runs, so there is no executable
/// to clean up — only the scratch source directory.
fn compile_as_library(fixture_name: &str, rust_src: &str) {
    let workspace_root = workspace_root();
    let target_dir = workspace_root.join("target");
    let unique = FIXTURE_COUNTER.fetch_add(1, Ordering::Relaxed);
    let slug = format!("{fixture_name}_{}_{unique}", std::process::id());
    let fixture_dir = std::env::temp_dir().join(format!("ball_encoder_rustlib_fixture_{slug}"));
    fs::create_dir_all(&fixture_dir).unwrap_or_else(|err| {
        panic!(
            "failed to create fixture dir {}: {err}",
            fixture_dir.display()
        )
    });

    let shared_path = workspace_root.join("shared");
    let lib_name = format!("ball_encoder_lib_fixture_{slug}");
    let manifest = format!(
        "[package]\nname = \"{lib_name}\"\nversion = \"0.0.0\"\nedition = \"2024\"\npublish = false\n\n\
         [lib]\nname = \"{lib_name}\"\npath = \"lib.rs\"\n\n\
         [dependencies]\nball-lang-shared = {{ path = {:?} }}\n",
        shared_path
    );
    fs::write(fixture_dir.join("Cargo.toml"), manifest)
        .expect("failed to write fixture Cargo.toml");
    fs::write(fixture_dir.join("lib.rs"), rust_src).expect("failed to write fixture lib.rs");

    let manifest_path = fixture_dir.join("Cargo.toml");
    let build = Command::new("cargo")
        .args(["build", "--quiet"])
        .arg("--manifest-path")
        .arg(&manifest_path)
        .arg("--target-dir")
        .arg(&target_dir)
        .output()
        .expect("failed to spawn `cargo build` — is cargo on PATH?");

    let stdout = String::from_utf8_lossy(&build.stdout).to_string();
    let stderr = String::from_utf8_lossy(&build.stderr).to_string();
    let _ = fs::remove_dir_all(&fixture_dir);

    assert!(
        build.status.success(),
        "fixture '{fixture_name}' failed to COMPILE as a library.\n--- generated lib.rs ---\n{rust_src}\n\
         --- stdout ---\n{stdout}\n--- stderr ---\n{stderr}",
    );
}

#[test]
fn library_mode_encodes_without_main_and_compiles_as_a_rust_library() {
    let program = ball_lang_encoder::encode_library(LIBRARY_SOURCE);

    // ── The deliberate non-runnable boundary ───────────────────────────────
    assert_eq!(
        program.entry_function, "",
        "library mode must leave entry_function empty (non-runnable by design)"
    );
    assert_eq!(
        program.entry_module, "main",
        "entry_module still names the module whose items compile_library inlines"
    );

    // ── Every top-level item is encoded, `pub` or not ──────────────────────
    let main_module = program
        .modules
        .iter()
        .find(|m| m.name == "main")
        .expect("library mode must still emit the `main` module");
    let names: Vec<&str> = main_module
        .functions
        .iter()
        .map(|f| f.name.as_str())
        .collect();
    assert_eq!(names, ["double", "evens", "describe"]);
    assert!(
        main_module.functions.iter().all(|f| f.body.is_some()),
        "every encoded library function must carry a body"
    );

    // Visibility round-trips as cosmetic metadata (invariant #2).
    let describe = main_module
        .functions
        .iter()
        .find(|f| f.name == "describe")
        .expect("`describe` must be encoded");
    assert!(
        describe
            .metadata
            .as_ref()
            .map(|m| !m.fields.contains_key("is_public"))
            .unwrap_or(true),
        "a private fn must not be marked is_public"
    );
    let double = main_module
        .functions
        .iter()
        .find(|f| f.name == "double")
        .expect("`double` must be encoded");
    assert!(
        double
            .metadata
            .as_ref()
            .expect("a `pub fn` carries metadata")
            .fields
            .contains_key("is_public"),
        "a `pub fn` must round-trip metadata.is_public"
    );

    // ── Std accumulation ran, exactly as `encode()`'s does ─────────────────
    let std_module = program
        .modules
        .iter()
        .find(|m| m.name == "std")
        .expect("library mode must attach the `std` base module");
    assert!(
        !std_module.functions.is_empty(),
        "`std` must declare the base functions the library actually calls"
    );
    let collections = program
        .modules
        .iter()
        .find(|m| m.name == "std_collections")
        .expect("library mode must attach `std_collections` (the library calls list_push)");
    assert!(
        collections
            .functions
            .iter()
            .any(|f| f.name == "list_push" && f.is_base),
        "`std_collections` must declare list_push as a base function"
    );

    // ── The real round trip: it compiles as a Rust library crate ───────────
    let compiled = Compiler::new(&program).compile_library();
    assert!(
        !compiled.contains("fn main()"),
        "compile_library must not emit an entry point:\n{compiled}"
    );
    compile_as_library("library_mode", &compiled);
}

#[test]
#[should_panic(expected = "requires a `fn main()` entry point")]
fn default_encode_still_requires_fn_main() {
    // The default contract is unchanged — library mode is strictly opt-in.
    let _ = ball_lang_encoder::encode(LIBRARY_SOURCE);
}
