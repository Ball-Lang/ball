//! Non-`Fn` items inside an `impl` block (issue #491, slice 5): an
//! associated `const` or `type` alongside real methods.
//!
//! ## Why this bucket matters
//!
//! `rust/encoder/src/types.rs::encode_item_impl` used to `panic!` the instant
//! its `for impl_item in &item.items` loop reached anything that was not an
//! `ImplItem::Fn` — so ONE associated const killed the whole file, even when
//! every method beside it encoded perfectly. That is 14 of the 110 scored
//! files in the live Tier A funnel (`tools/coverage-study/packages/rust.json`
//! pin set), e.g. `itertools/array_impl.rs`.
//!
//! The sibling pre-pass over the very same syntax,
//! `types.rs::collect_impl_method_params`, has always used `if let
//! syn::ImplItem::Fn(..) = impl_item { .. }` with no `else` — silently
//! skipping non-`Fn` items. So this slice is not new tolerance being
//! invented; it is two passes over one syntax tree being made to agree.
//!
//! ## Why this is a compile-and-run proof, not a shape assertion
//!
//! Dropping a declaration is exactly the kind of change that can silently
//! produce wrong output, so the assertion that matters is that a real Rust
//! file with a mixed `impl` block still travels encoder -> compiler ->
//! `cargo build` -> execution and prints the right number. The expected
//! stdout is hand-computed from the semantics of the original Rust source
//! (`Point { x: 3, y: 4 }`, `get_x() + get_y() == 7`), not read off a run.
//!
//! A real *reference* to the dropped const (`Self::CAP`) still fails loud
//! independently — `lib.rs`'s "unsupported path expression" panic — so
//! skipping the declaration cannot silently change what a program computes.
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

use ball_lang_compiler::Compiler;

/// An `impl` block carrying BOTH non-`Fn` items (an associated const and an
/// associated type) and two ordinary `&self` methods — the exact shape that
/// used to abort the whole file at `types.rs`'s unconditional panic.
const MIXED_IMPL_SOURCE: &str = r#"
struct Point {
    x: i64,
    y: i64,
}

impl Point {
    const CAP: i64 = 4;

    type Coord = i64;

    fn get_x(&self) -> i64 {
        self.x
    }

    fn get_y(&self) -> i64 {
        self.y
    }
}

fn main() {
    let p = Point { x: 3, y: 4 };
    println!("{}", p.get_x() + p.get_y());
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
/// `end_to_end.rs`/`static_methods.rs` use (unique package/bin name so
/// parallel fixtures never collide; the shared workspace `target/` so the
/// already-built `ball-lang-shared` dependency tree is reused; every artifact
/// cleaned up, including on failure).
fn compile_and_run(fixture_name: &str, rust_src: &str) -> String {
    let workspace_root = workspace_root();
    let target_dir = workspace_root.join("target");
    let unique = FIXTURE_COUNTER.fetch_add(1, Ordering::Relaxed);
    let slug = format!("{fixture_name}_{}_{unique}", std::process::id());
    let fixture_dir = std::env::temp_dir().join(format!("ball_encoder_mixed_impl_fixture_{slug}"));
    fs::create_dir_all(&fixture_dir).unwrap_or_else(|err| {
        panic!(
            "failed to create fixture dir {}: {err}",
            fixture_dir.display()
        )
    });

    let shared_path = workspace_root.join("shared");
    let bin_name = format!("ball_encoder_mixed_impl_fixture_{slug}");
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
fn impl_block_with_assoc_const_and_method_encodes_and_round_trips() {
    let program = ball_lang_encoder::encode(MIXED_IMPL_SOURCE);
    let main_module = program
        .modules
        .iter()
        .find(|m| m.name == "main")
        .expect("the encoded program must carry a `main` module");

    // ── Both methods survive the non-`Fn` items sitting beside them ──
    for method in ["main:Point.get_x", "main:Point.get_y"] {
        let member = main_module
            .functions
            .iter()
            .find(|f| f.name == method)
            .unwrap_or_else(|| {
                panic!(
                    "`{method}` must encode even though the same `impl` block declares an \
                     associated const and an associated type"
                )
            });
        assert!(member.body.is_some(), "`{method}` must carry its body");
    }

    // ── The skipped items leave no phantom declaration behind ──
    assert!(
        !main_module.functions.iter().any(|f| f.name.contains("CAP")),
        "the associated const must be SKIPPED, never encoded as a member: {:?}",
        main_module
            .functions
            .iter()
            .map(|f| f.name.as_str())
            .collect::<Vec<_>>()
    );
    assert!(
        !main_module
            .functions
            .iter()
            .any(|f| f.name.contains("Coord")),
        "the associated type must be SKIPPED, never encoded as a member"
    );

    // ── The real round trip: it compiles to Rust and prints 7 ──
    let compiled = Compiler::new(&program).compile();
    let stdout = compile_and_run("mixed_impl_items", &compiled);
    assert_eq!(
        stdout.trim(),
        "7",
        "Point {{ x: 3, y: 4 }}.get_x() + .get_y() == 7\n--- generated main.rs ---\n{compiled}"
    );
}

/// An item-position macro invocation inside an `impl` block
/// (`syn::ImplItem::Macro`) is skipped the same way — encode-only, because
/// what the macro would have expanded to is by definition not visible to a
/// syntactic encoder.
#[test]
fn impl_block_with_item_macro_still_encodes_its_methods() {
    let program = ball_lang_encoder::encode(
        "struct Counter { n: i64 }\n\
         impl Counter {\n\
         some_derive_helper!();\n\
         fn get(&self) -> i64 { self.n }\n\
         }\n\
         fn main() { let c = Counter { n: 1 }; println!(\"{}\", c.get()); }",
    );
    let main_module = program
        .modules
        .iter()
        .find(|m| m.name == "main")
        .expect("the encoded program must carry a `main` module");
    assert!(
        main_module
            .functions
            .iter()
            .any(|f| f.name == "main:Counter.get"),
        "an item-position macro inside an `impl` block must not abort the block's methods"
    );
}
