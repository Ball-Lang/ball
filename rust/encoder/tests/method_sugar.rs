//! Two more universally-encodable method-call arms (issue #491, slice 6):
//! `.fuse()` and `.is_empty()`.
//!
//! Both were in `methods.rs`' catch-all "unsupported method call" bucket — the
//! second-largest bucket in the live Tier A funnel (15 of 110 scored files) —
//! and both are resolvable *without any type information*, unlike the rest of
//! that bucket:
//!
//! - `.fuse()` is an identity passthrough. A Ball `List` has no "already
//!   exhausted" state for a fused iterator to preserve, exactly like the
//!   `.iter()`/`.by_ref()` cases the same match arm already accepts.
//! - `.is_empty()` lowers to `std.equals(std.length(receiver), 0)`, reusing
//!   the SAME universal `std.length` dispatch `.len()` already routes through
//!   — so it is receiver-type-agnostic (a `String` and a `Vec` both work) with
//!   no new base function and no type inference.
//!
//! The rest of that bucket stays a documented, permanent carve-out — see
//! `rust/encoder/src/methods.rs`' module doc comment for the list and why.
//!
//! The expected stdout is hand-computed from the semantics of the original
//! Rust source, not read off a run: the fused/collected list still has 3
//! elements, `""` is empty (+10) and `[1, 2, 3]` is not (+0), so 13.
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

use ball_lang_compiler::Compiler;

const METHOD_SUGAR_SOURCE: &str = r#"
fn main() {
    let nums = vec![1, 2, 3];
    let same = nums.iter().fuse().collect();
    let text = "";
    let mut total = same.len();
    if text.is_empty() {
        total += 10;
    }
    if nums.is_empty() {
        total += 100;
    }
    println!("{}", total);
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
/// `end_to_end.rs`/`static_methods.rs` use.
fn compile_and_run(fixture_name: &str, rust_src: &str) -> String {
    let workspace_root = workspace_root();
    let target_dir = workspace_root.join("target");
    let unique = FIXTURE_COUNTER.fetch_add(1, Ordering::Relaxed);
    let slug = format!("{fixture_name}_{}_{unique}", std::process::id());
    let fixture_dir =
        std::env::temp_dir().join(format!("ball_encoder_method_sugar_fixture_{slug}"));
    fs::create_dir_all(&fixture_dir).unwrap_or_else(|err| {
        panic!(
            "failed to create fixture dir {}: {err}",
            fixture_dir.display()
        )
    });

    let shared_path = workspace_root.join("shared");
    let bin_name = format!("ball_encoder_method_sugar_fixture_{slug}");
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
fn fuse_and_is_empty_encode_compile_and_run() {
    let program = ball_lang_encoder::encode(METHOD_SUGAR_SOURCE);
    let compiled = Compiler::new(&program).compile();
    let stdout = compile_and_run("method_sugar", &compiled);
    assert_eq!(
        stdout.trim(),
        "13",
        "`.fuse()` passes the 3-element list through and `\"\".is_empty()` adds 10 while \
         `[1,2,3].is_empty()` adds nothing\n--- generated main.rs ---\n{compiled}"
    );
}
