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
use ball_lang_shared::proto::ball::v1::expression::Expr;
use ball_lang_shared::proto::ball::v1::statement::Stmt;

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

/// The guard that keeps slice 6 from WIDENING the encoder's built-in-name bias.
///
/// Every other built-in arm in `methods.rs` matches on the method name alone, so
/// a user-declared `fn len(&self)` is silently encoded as `std.length`. That is
/// a pre-existing, documented hazard; adding a new instance of it is not
/// justified by consistency. A `Vec`-backed struct's own `is_empty` lowered to
/// `std.length(struct) == 0` would be exactly the silently-wrong output this
/// crate's fail-loud posture exists to prevent — so the `.is_empty()` arm defers
/// to a same-file `impl` method of that name.
#[test]
fn user_declared_is_empty_wins_over_the_builtin_arm() {
    let program = ball_lang_encoder::encode(
        "struct Bag { items: Vec<i64> }\n\
         impl Bag { fn is_empty(&self) -> bool { false } }\n\
         fn main() { let b = Bag { items: vec![] }; let e = b.is_empty(); println!(\"{}\", e); }",
    );
    let main_module = program
        .modules
        .iter()
        .find(|m| m.name == "main")
        .expect("the encoded program must carry a `main` module");
    let main_fn = main_module
        .functions
        .iter()
        .find(|f| f.name == "main")
        .expect("`fn main` must encode");
    let Some(Expr::Block(block)) = main_fn.body.as_ref().and_then(|b| b.expr.as_ref()) else {
        panic!("`main`'s body is a block");
    };
    let Some(Stmt::Let(binding)) = &block.statements[1].stmt else {
        panic!("`let e = b.is_empty();` is a let binding");
    };
    let value = binding
        .value
        .as_ref()
        .expect("the let binding carries a value");
    let Some(Expr::Call(call)) = &value.expr else {
        panic!("`b.is_empty()` encodes as a call, not {:?}", value.expr);
    };
    assert_eq!(
        call.module, "",
        "a user instance-method call resolves through the compiler's short-name dispatcher, so it \
         carries no module qualifier — `std` here would mean the built-in \
         `std.equals(std.length(receiver), 0)` lowering swallowed the user's own method"
    );
    assert_eq!(
        call.function, "is_empty",
        "a same-file `fn is_empty(&self)` must dispatch to the USER's method"
    );
    let Some(Expr::MessageCreation(input)) = call.input.as_ref().and_then(|i| i.expr.as_ref())
    else {
        panic!("a user method call packs its receiver into a message_creation");
    };
    assert!(
        input.fields.iter().any(|f| f.name == "self"),
        "an instance-method call packs its receiver under `self`"
    );
}
