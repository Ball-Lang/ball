//! An inherent `impl` and a trait `impl ... for &T` colliding on one Ball
//! member name (issue #835).
//!
//! ## What is being pinned
//!
//! `types.rs::type_short_name` (issue #767) looks through `&T`/`&mut T`/`&'a
//! T` to the referent, so `impl Counter { fn f(&self) }` and
//! `impl SomeTrait for &Counter { fn f(&self) }` in the same file both
//! register the member `f` under the short name `Counter` via
//! `collect_impl_method_params`/`encode_item_impl`. Ball's class model keys
//! members by short name only — there is no per-trait namespace — so the
//! two impl blocks collide on one Ball class: the ENCODED `Program` carries
//! TWO `FunctionDefinition`s both named `main:Counter.f`, and
//! `rust/compiler`'s `class_members_by_owner` groups both into the SAME
//! native `impl main_Counter { .. }` block it emits, which `rustc` then
//! rejects outright (`error[E0201]: duplicate definitions with name 'f'`).
//!
//! That is the loud, documented failure mode this module doc comment's own
//! defence names — and, before this file, untested: nothing observed
//! whether the collision really surfaces that way, or whether one method
//! silently wins and the other is swallowed with no diagnostic at all (the
//! issue #55 class of bug). This is NOT a new defect introduced by #767 —
//! an inherent `impl Counter { fn f }` plus `impl SomeTrait for Counter {
//! fn f }` (no reference at all) collide identically, by the very same
//! mechanism, and always have. #767 only widened the self types that reach
//! it.
//!
//! See `rust/encoder/tests/impl_for_reference_self_type.rs` for the
//! non-colliding sibling (distinct method names) this slice already pins.
use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

use ball_lang_compiler::Compiler;

/// An inherent method and a trait method implemented `for &Counter`,
/// deliberately sharing the SAME name — the one shape #835 is about.
const COLLIDING_SOURCE: &str = r#"
struct Counter {
    n: i64,
}

impl Counter {
    fn f(&self) -> i64 {
        self.n
    }
}

trait Doubled {
    fn f(&self) -> i64;
}

impl Doubled for &Counter {
    fn f(&self) -> i64 {
        self.n * 2
    }
}

fn main() {
    let c = Counter { n: 5 };
    println!("{}", c.n);
}
"#;

static FIXTURE_COUNTER: AtomicU64 = AtomicU64::new(0);

fn workspace_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("rust/encoder must have a parent directory")
        .to_path_buf()
}

/// Build (never run — the point is whether `cargo build` ACCEPTS the
/// compiled output) `rust_src` in a scratch cargo package and return its
/// stderr, whichever way the build goes. Mirrors
/// `impl_for_reference_self_type.rs`'s harness, minus the run step this test
/// never reaches.
fn try_build(fixture_name: &str, rust_src: &str) -> (bool, String) {
    let workspace_root = workspace_root();
    let target_dir = workspace_root.join("target");
    let unique = FIXTURE_COUNTER.fetch_add(1, Ordering::Relaxed);
    let slug = format!("{fixture_name}_{}_{unique}", std::process::id());
    let fixture_dir = std::env::temp_dir().join(format!("ball_encoder_collision_fixture_{slug}"));
    fs::create_dir_all(&fixture_dir).unwrap_or_else(|err| {
        panic!(
            "failed to create fixture dir {}: {err}",
            fixture_dir.display()
        )
    });

    let shared_path = workspace_root.join("shared");
    let bin_name = format!("ball_encoder_collision_fixture_{slug}");
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

    let _ = fs::remove_dir_all(&fixture_dir);

    (
        build.status.success(),
        String::from_utf8_lossy(&build.stderr).into_owned(),
    )
}

/// The headline proof: encoding never panics, BOTH methods survive into the
/// `Program` (so the collision is not silently resolved at the encoder
/// layer — the issue #55 class, swallowing one method with no diagnostic at
/// all), and the recompiled Rust fails to BUILD with rustc's own
/// duplicate-definition diagnostic, not some other error and not a silent
/// miscompile.
#[test]
fn colliding_impl_members_survive_encoding_and_fail_loud_at_build() {
    let program = ball_lang_encoder::encode(COLLIDING_SOURCE);
    let main_module = program
        .modules
        .iter()
        .find(|m| m.name == "main")
        .expect("the encoded program must carry a `main` module");

    let f_members: Vec<&str> = main_module
        .functions
        .iter()
        .filter(|f| f.name == "main:Counter.f")
        .map(|f| f.name.as_str())
        .collect();
    assert_eq!(
        f_members.len(),
        2,
        "BOTH the inherent `f` and the `for &Counter` trait `f` must register on \
         `main:Counter` — a count of 1 would mean one was silently swallowed with no \
         diagnostic at all (the issue #55 class), got functions: {:?}",
        main_module
            .functions
            .iter()
            .map(|f| f.name.as_str())
            .collect::<Vec<_>>()
    );

    let compiled = Compiler::new(&program).compile();
    assert!(
        compiled.matches("fn f(").count() >= 2,
        "the compiled Rust must emit BOTH colliding method bodies (never drop one \
         silently), got:\n{compiled}"
    );

    let (succeeded, stderr) = try_build("impl_member_name_collision", &compiled);
    assert!(
        !succeeded,
        "a name collision between an inherent impl and a trait impl `for &T` must \
         fail the BUILD, not silently compile and run with one method missing:\n\
         --- generated main.rs ---\n{compiled}"
    );
    assert!(
        stderr.contains("duplicate definitions with name"),
        "the build must fail with rustc's own duplicate-definition diagnostic \
         (E0201), not some other, unrelated error:\n--- stderr ---\n{stderr}\n\
         --- generated main.rs ---\n{compiled}"
    );
}
