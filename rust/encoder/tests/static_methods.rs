//! Receiver-less associated functions (issue #491, slice 3): `impl Point { fn
//! new(x, y) -> Point { ... } }` plus a `Point::new(1, 2)` call site — the
//! single largest error class in #491's real-code study (26 of 196 files).
//!
//! ## Why this is a compile-and-run proof, not a shape assertion
//!
//! The encoded shape is only half the claim. `ball-lang-compiler` has
//! supported receiver-less associated functions since issue #288
//! (`type_emit.rs::method_prologue`'s `is_static` bypass +
//! `compile_method_dispatchers`' single-owner static route, proven by
//! `rust/compiler/tests/end_to_end.rs::receiver_less_associated_function_compiles_and_runs`
//! against a HAND-BUILT `Program`). What was missing was the encoder-side
//! mapping onto that shape — so the proof that matters is that a *real Rust
//! source file* now travels encoder -> compiler -> `cargo build` -> execution
//! and prints the right number, exactly the way `end_to_end.rs` proves the
//! `fn main` path.
//!
//! The expected stdout below is hand-computed from the semantics of the
//! original Rust source (`Point::new(3, 4).sum() == 7`, `Point::origin()`'s
//! fields are both 0), not read off a run.
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

use ball_lang_compiler::Compiler;
use ball_lang_shared::proto::ball::v1::expression::Expr;
use ball_lang_shared::proto::ball::v1::statement::Stmt;
use ball_lang_shared::proto::google::protobuf::Struct;
use ball_lang_shared::proto::google::protobuf::value::Kind;

/// A real, idiomatic Rust file whose *only* construction path is Rust's own
/// "constructor" idiom — an associated `fn new` with no `self` receiver —
/// plus a receiver-less associated function that takes no arguments at all
/// (`Point::origin()`), so the 0-argument packing convention is covered too,
/// and an ordinary `&self` method in the same `impl` block, so the new static
/// path is proven not to swallow instance methods.
const STATIC_METHOD_SOURCE: &str = r#"
struct Point {
    x: i64,
    y: i64,
}

impl Point {
    fn new(x: i64, y: i64) -> Point {
        Point { x: x, y: y }
    }

    fn origin() -> Point {
        Point { x: 0, y: 0 }
    }

    fn sum(&self) -> i64 {
        self.x + self.y
    }
}

fn main() {
    let p = Point::new(3, 4);
    let o = Point::origin();
    println!("{}", p.sum() + o.x + o.y);
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
/// `end_to_end.rs::compile_and_run` uses (unique package/bin name so parallel
/// fixtures never collide; the shared workspace `target/` so the already-built
/// `ball-lang-shared` dependency tree is reused; every artifact cleaned up,
/// including on failure).
fn compile_and_run(fixture_name: &str, rust_src: &str) -> String {
    let workspace_root = workspace_root();
    let target_dir = workspace_root.join("target");
    let unique = FIXTURE_COUNTER.fetch_add(1, Ordering::Relaxed);
    let slug = format!("{fixture_name}_{}_{unique}", std::process::id());
    let fixture_dir = std::env::temp_dir().join(format!("ball_encoder_static_fixture_{slug}"));
    fs::create_dir_all(&fixture_dir).unwrap_or_else(|err| {
        panic!(
            "failed to create fixture dir {}: {err}",
            fixture_dir.display()
        )
    });

    let shared_path = workspace_root.join("shared");
    let bin_name = format!("ball_encoder_static_fixture_{slug}");
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

/// `metadata.params`' `name` entries as a plain `Vec<String>`, in declaration
/// order.
fn param_names(metadata: Option<&Struct>) -> Vec<String> {
    let Some(meta) = metadata else {
        return Vec::new();
    };
    let Some(Kind::ListValue(list)) = meta.fields.get("params").and_then(|v| v.kind.as_ref())
    else {
        return Vec::new();
    };
    list.values
        .iter()
        .filter_map(|v| match &v.kind {
            Some(Kind::StructValue(s)) => {
                match s.fields.get("name").and_then(|n| n.kind.as_ref()) {
                    Some(Kind::StringValue(name)) => Some(name.clone()),
                    _ => None,
                }
            }
            _ => None,
        })
        .collect()
}

fn meta_bool(metadata: Option<&Struct>, key: &str) -> bool {
    matches!(
        metadata
            .and_then(|m| m.fields.get(key))
            .and_then(|v| v.kind.as_ref()),
        Some(Kind::BoolValue(true))
    )
}

#[test]
fn receiver_less_associated_function_encodes_and_round_trips() {
    let program = ball_lang_encoder::encode(STATIC_METHOD_SOURCE);
    let main_module = program
        .modules
        .iter()
        .find(|m| m.name == "main")
        .expect("the encoded program must carry a `main` module");

    // ── The member itself: an `is_static` class member with real param names ──
    let point_new = main_module
        .functions
        .iter()
        .find(|f| f.name == "main:Point.new")
        .expect("`Point::new` must encode as the class member `main:Point.new`");
    assert!(
        meta_bool(point_new.metadata.as_ref(), "is_static"),
        "a receiver-less associated fn must carry metadata.is_static — the shape \
         `rust/compiler/src/type_emit.rs` keys its `self`-extraction bypass off (issue #288)"
    );
    assert_eq!(
        param_names(point_new.metadata.as_ref()),
        vec!["x".to_string(), "y".to_string()],
        "metadata.params must list every declared parameter (there is no `self` to skip)"
    );
    assert!(point_new.body.is_some(), "`Point::new` must carry its body");

    let point_origin = main_module
        .functions
        .iter()
        .find(|f| f.name == "main:Point.origin")
        .expect("a 0-parameter associated fn must encode too");
    assert!(meta_bool(point_origin.metadata.as_ref(), "is_static"));
    assert!(
        param_names(point_origin.metadata.as_ref()).is_empty(),
        "a 0-parameter associated fn declares no metadata.params"
    );

    // An instance method in the SAME impl block still encodes as an instance
    // method — the new static path must not swallow it.
    let point_sum = main_module
        .functions
        .iter()
        .find(|f| f.name == "main:Point.sum")
        .expect("the `&self` method in the same impl block must still encode");
    assert!(
        !meta_bool(point_sum.metadata.as_ref(), "is_static"),
        "a `&self` method must NOT be marked is_static"
    );

    // ── The call site: short name, no `self` field, real parameter names ──
    let main_fn = main_module
        .functions
        .iter()
        .find(|f| f.name == "main")
        .expect("`fn main` must encode");
    let body = main_fn.body.as_ref().expect("`main` has a body");
    let Some(Expr::Block(block)) = &body.expr else {
        panic!("`main`'s body is a block");
    };
    let Some(Stmt::Let(binding)) = &block.statements[0].stmt else {
        panic!("`let p = Point::new(3, 4);` is a let binding");
    };
    let Some(Expr::Call(call)) = binding.value.as_ref().and_then(|v| v.expr.as_ref()) else {
        panic!("`Point::new(3, 4)` encodes as a call");
    };
    assert_eq!(
        call.module, "",
        "a local associated call resolves through the compiler's own short-name dispatcher, \
         so it carries no module qualifier"
    );
    assert_eq!(
        call.function, "new",
        "the call targets the member's SHORT name — the name \
         `compile_method_dispatchers` emits a free `pub fn` for"
    );
    let Some(Expr::MessageCreation(input)) = call.input.as_ref().and_then(|i| i.expr.as_ref())
    else {
        panic!("a 2-argument associated call packs its args into a message_creation");
    };
    assert_eq!(
        input
            .fields
            .iter()
            .map(|f| f.name.as_str())
            .collect::<Vec<_>>(),
        vec!["x", "y"],
        "args are packed under the callee's REAL parameter names, not arg0/arg1"
    );
    assert!(
        input.fields.iter().all(|f| f.name != "self"),
        "a receiver-less call must never pack a `self` field (issue #288's whole point)"
    );

    // A 0-argument associated call passes no input at all.
    let Some(Stmt::Let(origin_binding)) = &block.statements[1].stmt else {
        panic!("`let o = Point::origin();` is a let binding");
    };
    let Some(Expr::Call(origin_call)) = origin_binding.value.as_ref().and_then(|v| v.expr.as_ref())
    else {
        panic!("`Point::origin()` encodes as a call");
    };
    assert_eq!(origin_call.function, "origin");
    assert!(
        origin_call.input.is_none(),
        "a 0-argument call carries no input"
    );

    // ── The real round trip: it compiles to Rust and prints 7 ──
    let compiled = Compiler::new(&program).compile();
    let stdout = compile_and_run("static_methods", &compiled);
    assert_eq!(
        stdout.trim(),
        "7",
        "Point::new(3, 4).sum() + Point::origin().x + .y == 7\n--- generated main.rs ---\n{compiled}"
    );
}
