//! `impl <Trait> for &T` / `&mut T` — an `impl` block whose self type is a
//! REFERENCE to a named type (issue #767).
//!
//! ## Why this bucket matters
//!
//! `types.rs::type_short_name` accepted only `syn::Type::Path`, so every other
//! self type aborted the whole file at its "unsupported `impl` self type"
//! panic. Measured on the live Tier A funnel
//! (`tools/coverage-study/packages/rust.json`, the same five pins
//! `coverage-study.yml` runs), that is **8 of the 77 scored files**, and the
//! bucket splits cleanly in two:
//!
//! - **4 are a reference to a named type** and are what this slice closes:
//!   `itertools/groupbylazy.rs` (`&'a ChunkBy<K, I, F>`),
//!   `itertools/peeking_take_while.rs` (`&mut I`),
//!   `itertools/rciter_impl.rs` (`&RcIter<I>`) and
//!   `strsim/lib.rs` (`&StringWrapper<'b>`).
//! - **4 are genuinely non-nominal** — `itertools/adaptors/mod.rs`
//!   (`(I::Item,)`), `itertools/tuple_impl.rs` (`(ignore_ident!(l, A),)`),
//!   `itertools/combinations.rs` (`[usize; K]`) and `smallvec/conversions.rs`
//!   (`[T; M]`) — and stay refused, loudly. A tuple or array type has no short
//!   NAME for Ball's class model to key members on, which is a representation
//!   decision rather than a tolerance tweak; both shapes are pinned in
//!   `documented_gaps.rs`.
//!
//! ## Why stripping the reference is sound, not a tolerance
//!
//! Ball has no reference or ownership distinction at all: a Ball value is a
//! value, and `lib.rs::encode_expr` has always encoded `&x` as `x` (its
//! `syn::Expr::Reference` arm). `impl Trait for &Counter` therefore names the
//! *same* Ball class as `impl Trait for Counter` — this is not an
//! approximation of a distinction the IR preserves, because the IR has no such
//! distinction to preserve. That is the whole argument, and it is why this arm
//! does not widen the name-only bias `methods.rs`' module doc comment refuses
//! to widen: nothing here is guessed from a name.
//!
//! What DOES follow is that an inherent `impl Counter { fn f }` and an
//! `impl Trait for &Counter { fn f }` in the same file now register the same
//! member name on the same owner — Rust keeps them distinct, Ball cannot. That
//! is the pre-existing property of a class model keyed on a short name (an
//! `impl Counter` and an `impl Trait for Counter` already collide the same
//! way), not something this slice introduces; it is stated here rather than
//! left for a reader to discover.
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

use ball_lang_compiler::Compiler;

/// An inherent method and a trait method implemented `for &Counter` — the two
/// register on the same Ball class, under distinct names.
const REFERENCE_IMPL_SOURCE: &str = r#"
struct Counter {
    n: i64,
}

impl Counter {
    fn base(&self) -> i64 {
        self.n
    }
}

trait Doubled {
    fn doubled(&self) -> i64;
}

impl Doubled for &Counter {
    fn doubled(&self) -> i64 {
        self.n * 2
    }
}

fn main() {
    let c = Counter { n: 5 };
    println!("{}", c.base() + c.doubled());
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
/// `end_to_end.rs`/`tuple_and_unit_structs.rs` use.
fn compile_and_run(fixture_name: &str, rust_src: &str) -> String {
    let workspace_root = workspace_root();
    let target_dir = workspace_root.join("target");
    let unique = FIXTURE_COUNTER.fetch_add(1, Ordering::Relaxed);
    let slug = format!("{fixture_name}_{}_{unique}", std::process::id());
    let fixture_dir = std::env::temp_dir().join(format!("ball_encoder_ref_impl_fixture_{slug}"));
    fs::create_dir_all(&fixture_dir).unwrap_or_else(|err| {
        panic!(
            "failed to create fixture dir {}: {err}",
            fixture_dir.display()
        )
    });

    let shared_path = workspace_root.join("shared");
    let bin_name = format!("ball_encoder_ref_impl_fixture_{slug}");
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
fn impl_for_a_reference_self_type_encodes_and_round_trips() {
    let program = ball_lang_encoder::encode(REFERENCE_IMPL_SOURCE);
    let main_module = program
        .modules
        .iter()
        .find(|m| m.name == "main")
        .expect("the encoded program must carry a `main` module");

    // ── Members of `impl Doubled for &Counter` land on `main:Counter` ──
    //
    // Asserted POSITIVELY: an encoder that merely SKIPPED the reference impl
    // would also not panic, and would then produce a program whose
    // `c.doubled()` call resolves to nothing. `<module>:<Type>.<method>` is
    // the `class_members_by_owner` naming `rust/compiler/src/type_emit.rs`
    // groups by.
    let member_names: Vec<&str> = main_module
        .functions
        .iter()
        .map(|f| f.name.as_str())
        .collect();
    assert!(
        member_names.contains(&"main:Counter.base")
            && member_names.contains(&"main:Counter.doubled"),
        "both the inherent method and the `for &Counter` trait method must \
         register on the same Ball class owner, got {member_names:?}"
    );

    // ── The real round trip: it compiles to Rust and prints 15 ──
    let compiled = Compiler::new(&program).compile();
    let stdout = compile_and_run("impl_for_reference_self_type", &compiled);
    assert_eq!(
        stdout.trim(),
        "15",
        "Counter {{ n: 5 }}.base() + .doubled() == 5 + 10 == 15\n\
         --- generated main.rs ---\n{compiled}"
    );
}

/// The same rule through `&mut` and a bare generic parameter — the shapes
/// `itertools/peeking_take_while.rs` (`impl<I: Iterator> PeekingNext for &mut
/// I`) is first-blocked on. Encode-only: a generic parameter is not a
/// constructible type, so there is nothing to run.
#[test]
fn impl_for_a_mutable_reference_self_type_encodes() {
    let program = ball_lang_encoder::encode(
        "trait Bumped { fn bumped(&self) -> i64; }\n\
         impl<I> Bumped for &mut I { fn bumped(&self) -> i64 { 1 } }\n\
         fn main() {}",
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
            .any(|f| f.name == "main:I.bumped"),
        "`&mut I`'s members must register under the referent `I`, not be \
         silently dropped: {:?}",
        main_module
            .functions
            .iter()
            .map(|f| f.name.as_str())
            .collect::<Vec<_>>()
    );
}
