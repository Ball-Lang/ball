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
//!
//! ## The `trait` sibling (issue #491, this slice)
//!
//! The second fixture below covers the same shape declared inside a `trait`
//! block with a **default body**. That sub-case was previously refused
//! wholesale by `types.rs::encode_item_trait`, whose `!has_self_receiver`
//! guard fired *before* it ever consulted `trait_fn.default.is_some()` — so a
//! single such trait aborted the encoding of the whole file. A genuinely
//! abstract (signature-only) receiver-less trait fn is still refused, and
//! still pinned by
//! `documented_gaps.rs::trait_associated_fn_without_receiver_is_a_documented_gap`.
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

/// A `trait` block whose receiver-less associated functions carry **default
/// bodies**, beside an `impl` block declaring its own receiver-less
/// associated function — so the two owners' `static_method_params` keys are
/// proven to coexist rather than shadow each other.
///
/// `make` takes **two** parameters on purpose. `method_non_self_params`
/// unconditionally `.skip(1)`s the leading `self`, so reusing it for a
/// receiver-less member silently drops the FIRST real parameter — a defect a
/// zero- or one-argument example structurally cannot expose (an empty
/// iterator skips nothing, and a single argument is passed directly rather
/// than packed under a field name). Only a 2+-parameter member surfaces it.
///
/// `Maker::make(3, 4)` is not a call form rustc itself accepts (`error[E0790]`
/// — a trait's default body needs a concrete `impl` to dispatch through), and
/// that is precisely why the compiler emits every Ball class member as an
/// *inherent* `impl` fn rather than a Rust `trait`
/// (`rust/compiler/src/type_emit.rs::compile_type_def`'s doc comment). The
/// encoder is syntax-only, so what it must guarantee is that this path
/// produces a program that RUNS — which is what the round trip below asserts.
/// The real-world win is the declaration side: a file merely *containing*
/// such a trait no longer aborts wholesale.
const TRAIT_STATIC_SOURCE: &str = r#"
trait Maker {
    fn make(n: i64, m: i64) -> i64 {
        n + m
    }

    fn zero() -> i64 {
        0
    }

    fn label(&self) -> i64 {
        1
    }
}

struct Point {
    x: i64,
}

impl Point {
    fn unit() -> Point {
        Point { x: 5 }
    }
}

fn main() {
    let p = Point::unit();
    println!("{}", Maker::make(3, 4) + Maker::zero() + p.x);
}
"#;

#[test]
fn default_bodied_trait_fn_without_receiver_encodes_and_round_trips() {
    let program = ball_lang_encoder::encode(TRAIT_STATIC_SOURCE);
    let main_module = program
        .modules
        .iter()
        .find(|m| m.name == "main")
        .expect("the encoded program must carry a `main` module");

    // ── The trait members ──
    let make = main_module
        .functions
        .iter()
        .find(|f| f.name == "main:Maker.make")
        .expect("a default-bodied receiver-less trait fn must encode as a class member");
    assert!(
        meta_bool(make.metadata.as_ref(), "is_static"),
        "a receiver-less trait member must carry metadata.is_static — the key \
         `type_emit.rs::method_prologue` bypasses its `self` extraction on (issue #288)"
    );
    assert!(
        !meta_bool(make.metadata.as_ref(), "is_abstract"),
        "a DEFAULT-BODIED member is concrete; marking it abstract would drop it from both \
         `compile_struct_def`'s impl block and `compile_method_dispatchers`"
    );
    assert_eq!(
        param_names(make.metadata.as_ref()),
        vec!["n".to_string(), "m".to_string()],
        "every parameter of a receiver-less member is real — none may be skipped as a `self`"
    );
    assert!(
        make.body.is_some(),
        "a default body must be carried through"
    );

    let zero = main_module
        .functions
        .iter()
        .find(|f| f.name == "main:Maker.zero")
        .expect("a 0-parameter default-bodied trait fn must encode too");
    assert!(meta_bool(zero.metadata.as_ref(), "is_static"));
    assert!(param_names(zero.metadata.as_ref()).is_empty());

    // A `&self` default method in the SAME trait keeps its instance shape.
    let label = main_module
        .functions
        .iter()
        .find(|f| f.name == "main:Maker.label")
        .expect("the `&self` default method must still encode");
    assert!(
        !meta_bool(label.metadata.as_ref(), "is_static"),
        "a `&self` trait method must NOT be marked is_static"
    );

    // The `impl`-declared associated fn on a DIFFERENT owner is untouched —
    // `static_method_params` is keyed by `(owner, method)`, so registering a
    // trait's members cannot shadow an `impl`'s.
    let unit = main_module
        .functions
        .iter()
        .find(|f| f.name == "main:Point.unit")
        .expect("the impl-declared associated fn must still encode");
    assert!(meta_bool(unit.metadata.as_ref(), "is_static"));

    // ── The call site: real parameter names, no `self` field ──
    let main_fn = main_module
        .functions
        .iter()
        .find(|f| f.name == "main")
        .expect("`fn main` must encode");
    let body = main_fn.body.as_ref().expect("`main` has a body");
    let Some(Expr::Block(block)) = &body.expr else {
        panic!("`main`'s body is a block");
    };
    let make_call = find_call(block, "make").expect("`Maker::make(3, 4)` must encode as a call");
    assert_eq!(
        make_call.module, "",
        "a local associated call resolves through the compiler's own short-name dispatcher"
    );
    let Some(Expr::MessageCreation(input)) = make_call.input.as_ref().and_then(|i| i.expr.as_ref())
    else {
        panic!("a 2-argument associated call packs its args into a message_creation");
    };
    assert_eq!(
        input
            .fields
            .iter()
            .map(|f| f.name.as_str())
            .collect::<Vec<_>>(),
        vec!["n", "m"],
        "args are packed under the trait member's REAL parameter names, not arg0/arg1 — a \
         dropped first parameter would show up here as [\"m\", \"arg1\"]-shaped drift"
    );
    assert!(
        input.fields.iter().all(|f| f.name != "self"),
        "a receiver-less call must never pack a `self` field"
    );

    // ── The real round trip: it compiles to Rust and prints 12 ──
    let compiled = Compiler::new(&program).compile();
    let stdout = compile_and_run("trait_static_methods", &compiled);
    assert_eq!(
        stdout.trim(),
        "12",
        "Maker::make(3, 4) + Maker::zero() + Point::unit().x == 3 + 4 + 0 + 5\n\
         --- generated main.rs ---\n{compiled}"
    );
}

/// Depth-first search for the first `call` node targeting `function`, so the
/// assertions above don't have to mirror `println!`'s own nesting.
fn find_call<'a>(
    block: &'a ball_lang_shared::proto::ball::v1::Block,
    function: &str,
) -> Option<&'a ball_lang_shared::proto::ball::v1::FunctionCall> {
    fn walk<'a>(
        expr: &'a ball_lang_shared::proto::ball::v1::Expression,
        function: &str,
    ) -> Option<&'a ball_lang_shared::proto::ball::v1::FunctionCall> {
        match expr.expr.as_ref()? {
            Expr::Call(call) => {
                if call.function == function {
                    return Some(call);
                }
                call.input.as_deref().and_then(|i| walk(i, function))
            }
            Expr::Block(inner) => walk_block(inner, function),
            Expr::MessageCreation(creation) => creation
                .fields
                .iter()
                .filter_map(|f| f.value.as_ref())
                .find_map(|v| walk(v, function)),
            Expr::FieldAccess(access) => access.object.as_deref().and_then(|o| walk(o, function)),
            _ => None,
        }
    }

    fn walk_block<'a>(
        block: &'a ball_lang_shared::proto::ball::v1::Block,
        function: &str,
    ) -> Option<&'a ball_lang_shared::proto::ball::v1::FunctionCall> {
        block
            .statements
            .iter()
            .find_map(|statement| match statement.stmt.as_ref()? {
                Stmt::Let(binding) => binding.value.as_ref().and_then(|v| walk(v, function)),
                Stmt::Expression(expr) => walk(expr, function),
            })
            .or_else(|| block.result.as_deref().and_then(|r| walk(r, function)))
    }

    walk_block(block, function)
}
