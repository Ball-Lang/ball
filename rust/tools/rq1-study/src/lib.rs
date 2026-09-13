//! Tier A of the third-party coverage study — Rust port (issue #493).
//!
//! The Rust sibling of `tools/coverage-study/rq1_study.dart`. For every `.rs`
//! file of a pinned third-party crate, does
//!
//! ```text
//! Rust source -> ball-lang-encoder -> ball-lang-compiler::compile_library
//!             -> Rust source -> ball-lang-encoder
//! ```
//!
//! come back with the same declarations and the same semantic Ball IR? A file
//! is *clean* only when it encodes, compiles back, re-encodes, keeps every
//! declaration it started with, and reaches a **second-generation fixpoint**
//! (compiling the re-encoded program again produces the same Rust and the same
//! metadata-stripped IR). Cleanliness is deliberately strict; the first
//! baselines are expected to be low, and measuring that honestly is the point.
//!
//! # Why the funnel exists
//!
//! The clean percentage alone cannot tell "the encoder rejected the file
//! outright" from "everything worked but generation three drifted". On a
//! pipeline that is not round-trip-closed the whole signal lives in that
//! difference, so the report prints how many scored files survived each stage.
//!
//! # The two load-bearing settings
//!
//! 1. **Library-mode encode + compile, never the runnable pair.** Real library
//!    crates have no `fn main`, and [`ball_lang_encoder::encode`] asserts one
//!    exists. [`ball_lang_encoder::encode_library`] (issue #491) is the opt-in
//!    that accepts them, and [`ball_lang_compiler::Compiler::compile_library`]
//!    compiles the resulting entry-function-less `Program`. Reaching for the
//!    runnable pair here would silently skip exactly the files #493 exists to
//!    look at.
//! 2. **The declaration inventory is walked with `syn` DIRECTLY**, never
//!    through the encoder's own walk, so a bug in the encoder's bookkeeping
//!    cannot hide a lost declaration from the harness.
//! 3. **Crate-aware stage 1** (issue #491). Real crates are `mod` graphs, not
//!    piles of independent files, so each package's graph is walked once and
//!    every file it reached is encoded through
//!    [`ball_lang_encoder::CrateGraph::encode_file_library`] — with the whole
//!    crate's types, `impl` blocks and free functions in hand. `--single-file`
//!    turns that off and reproduces the older per-file measurement exactly, so
//!    a before/after of a crate-aware change is ONE binary over ONE checkout.
//!    Only stage 1 is crate-aware: stages 3 and 5 re-encode the compiler's own
//!    single generated file, which has no `mod` graph of its own.
//!
//! # Panics are data
//!
//! `ball-lang-encoder` and `ball-lang-compiler` fail loud by panicking (issue
//! #55 doctrine) rather than returning `Result`. A measuring instrument must
//! turn each of those into a scored verdict, not die on the first file, so
//! every pipeline call runs inside [`std::panic::catch_unwind`] with a quiet
//! panic hook installed by [`silence_panic_output`].

use std::any::Any;
use std::collections::BTreeSet;
use std::panic::{self, AssertUnwindSafe};
use std::path::{Path, PathBuf};

use ball_lang_compiler::Compiler;
use ball_lang_encoder::CrateGraph;
use ball_lang_shared::DESCRIPTOR_POOL;
use ball_lang_shared::proto::ball::v1::Program;
use prost::Message;
use prost_reflect::DynamicMessage;

/// One file's verdict. Mirrors `rq1_study.dart`'s `FileResult`.
#[derive(Debug, Clone)]
pub struct FileResult {
    pub package: String,
    pub file: String,
    /// False for files with nothing to compile (a `mod`-declarations-only
    /// file, a generated stub). Not counted in the Tier A denominator — a file
    /// with no declarations is not evidence either way.
    pub scored: bool,
    /// Survived every scored stage.
    pub clean: bool,
    /// INFORMATIONAL, not part of `clean`: the metadata-stripped Ball IR of the
    /// re-encoded output is identical to the first pass.
    pub ir_stable: bool,
    /// Taxonomy tag plus detail, e.g. `encode-error: …`.
    pub reason: String,
    /// The Ball module name this file was encoded AS, when the crate's `mod`
    /// graph reached it (issue #491's `encode_crate`). `None` means the file
    /// was encoded with no crate context at all — either the package has no
    /// resolvable crate root, or its `mod` graph does not name this file (a
    /// `#[cfg(test)]` module, an unreferenced leftover). Recorded per file
    /// because "the crate walk never saw it" is a materially different
    /// measurement from "it was measured crate-aware and still failed".
    pub crate_module: Option<String>,
}

impl FileResult {
    /// The report row, keyed exactly like every other Tier A harness's JSON.
    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "package": self.package,
            "file": self.file,
            "scored": self.scored,
            "clean": self.clean,
            "irStable": self.ir_stable,
            "reason": self.reason,
            "crateModule": self.crate_module,
        })
    }
}

/// The funnel rows, in order.
pub const STAGES: [(u8, &str); 5] = [
    (1, "1 encoded"),
    (2, "2 compiled back"),
    (3, "3 re-encoded"),
    (4, "4 declarations kept"),
    (5, "5 fixpoint (clean)"),
];

/// How far a scored file got, from its taxonomy tag. An unknown tag is an
/// error rather than a default, so a new failure mode cannot be silently
/// mis-attributed into the funnel.
pub fn stage_reached(reason: &str) -> Result<u8, String> {
    let tag = reason.split(':').next().unwrap_or("");
    match tag {
        "read-error" | "parse-error" | "encode-error" => Ok(0),
        "compile-error" => Ok(1),
        "reencode-error" => Ok(2),
        "declaration-drift" => Ok(3),
        "fixpoint-error" | "fixpoint-drift" => Ok(4),
        "clean" => Ok(5),
        other => Err(format!(
            "unknown taxonomy tag {other:?} — the funnel would silently lie"
        )),
    }
}

/// Installs a panic hook that prints nothing. The pipeline fails loud by
/// panicking, and a sweep over thousands of third-party files would otherwise
/// bury its own report under panic backtraces. The payload is still captured by
/// `catch_unwind`, so no information is lost — only the noise.
pub fn silence_panic_output() {
    panic::set_hook(Box::new(|_| {}));
}

fn panic_message(payload: Box<dyn Any + Send>) -> String {
    let text = if let Some(s) = payload.downcast_ref::<&str>() {
        (*s).to_string()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "panicked with a non-string payload".to_string()
    };
    first_line(&text)
}

fn first_line(text: &str) -> String {
    let text = text.replace('\r', "");
    let line = text.lines().next().unwrap_or("").to_string();
    if line.chars().count() > 160 {
        format!("{}…", line.chars().take(160).collect::<String>())
    } else {
        line
    }
}

/// Runs `body`, turning a fail-loud panic into an `Err(message)`.
fn caught<T>(body: impl FnOnce() -> T) -> Result<T, String> {
    panic::catch_unwind(AssertUnwindSafe(body)).map_err(panic_message)
}

/// Recursively drops every `metadata` map. Metadata is cosmetic (Ball
/// invariant #2), so two programs that differ only there are semantically
/// identical — the project's own definition of semantic equality.
pub fn strip_metadata(node: serde_json::Value) -> serde_json::Value {
    match node {
        serde_json::Value::Object(map) => serde_json::Value::Object(
            map.into_iter()
                .filter(|(key, _)| key != "metadata")
                .map(|(key, value)| (key, strip_metadata(value)))
                .collect(),
        ),
        serde_json::Value::Array(items) => {
            serde_json::Value::Array(items.into_iter().map(strip_metadata).collect())
        }
        other => other,
    }
}

/// A `Program` as metadata-stripped, key-sorted JSON. `serde_json`'s default
/// object representation is a `BTreeMap`, so the rendering is deterministic.
fn canonical_ir(program: &Program) -> Result<String, String> {
    let descriptor = DESCRIPTOR_POOL
        .get_message_by_name("ball.v1.Program")
        .ok_or_else(|| "ball.v1.Program is not in the descriptor pool".to_string())?;
    let dynamic = DynamicMessage::decode(descriptor, program.encode_to_vec().as_slice())
        .map_err(|err| err.to_string())?;
    let value = serde_json::to_value(&dynamic).map_err(|err| err.to_string())?;
    serde_json::to_string(&strip_metadata(value)).map_err(|err| err.to_string())
}

/// The declaration inventory of `source`: one entry per top-level item, `impl`
/// members included, so a lost method is visible and mere reordering is not.
/// Walked with `syn` directly — independent of the encoder's own walk.
pub fn declaration_inventory(source: &str) -> Result<BTreeSet<String>, String> {
    let file = syn::parse_file(source).map_err(|err| err.to_string())?;
    let mut names = BTreeSet::new();
    for item in &file.items {
        match item {
            syn::Item::Fn(item) => {
                names.insert(format!("fn {}", item.sig.ident));
            }
            syn::Item::Struct(item) => {
                names.insert(format!("struct {}", item.ident));
                for field in &item.fields {
                    if let Some(ident) = &field.ident {
                        names.insert(format!("struct {}.{}", item.ident, ident));
                    }
                }
            }
            syn::Item::Enum(item) => {
                names.insert(format!("enum {}", item.ident));
                for variant in &item.variants {
                    names.insert(format!("enum {}.{}", item.ident, variant.ident));
                }
            }
            syn::Item::Trait(item) => {
                names.insert(format!("trait {}", item.ident));
                for trait_item in &item.items {
                    if let syn::TraitItem::Fn(method) = trait_item {
                        names.insert(format!("trait {}.{}", item.ident, method.sig.ident));
                    }
                }
            }
            syn::Item::Impl(item) => {
                let owner = type_name(&item.self_ty);
                for impl_item in &item.items {
                    if let syn::ImplItem::Fn(method) = impl_item {
                        names.insert(format!("impl {}.{}", owner, method.sig.ident));
                    }
                }
            }
            syn::Item::Const(item) => {
                names.insert(format!("const {}", item.ident));
            }
            syn::Item::Static(item) => {
                names.insert(format!("static {}", item.ident));
            }
            syn::Item::Type(item) => {
                names.insert(format!("type {}", item.ident));
            }
            _ => {}
        }
    }
    Ok(names)
}

fn type_name(ty: &syn::Type) -> String {
    match ty {
        syn::Type::Path(path) => path
            .path
            .segments
            .last()
            .map(|segment| segment.ident.to_string())
            .unwrap_or_else(|| "<unknown>".to_string()),
        _ => "<unknown>".to_string(),
    }
}

fn verdict(package: &str, file: &str, reason: String) -> FileResult {
    FileResult {
        package: package.to_string(),
        file: file.to_string(),
        scored: true,
        clean: false,
        ir_stable: false,
        reason,
        crate_module: None,
    }
}

/// The crate context one file is measured in: the walked `mod` graph plus the
/// Ball module name this file is encoded as (issue #491).
pub struct CrateContext<'a> {
    pub graph: &'a CrateGraph,
    pub module: String,
}

/// Runs Tier A over one file's `source` with NO crate context — the
/// single-file measurement this harness made before issue #491's crate-aware
/// encoder existed. Kept as its own entry point because the self-test uses it
/// to show what crate-awareness actually changes.
pub fn study_file(package: &str, file: &str, source: &str) -> FileResult {
    study_file_in_crate(package, file, source, None)
}

/// Runs Tier A over one file's `source` and returns its verdict.
///
/// **Only stage 1 is crate-aware, and deliberately so.** Stages 3 and 5
/// re-encode the compiler's OWN output, which is one self-contained generated
/// file with no `mod` graph of its own — feeding it a crate context would
/// resolve names against a crate it did not come from. What the context
/// changes is exactly the thing #491 measured as blocking: whether the
/// original file's cross-file callees resolve at all.
pub fn study_file_in_crate(
    package: &str,
    file: &str,
    source: &str,
    crate_context: Option<&CrateContext<'_>>,
) -> FileResult {
    let mut result = study_file_core(package, file, source, crate_context);
    result.crate_module = crate_context.map(|context| context.module.clone());
    result
}

fn study_file_core(
    package: &str,
    file: &str,
    source: &str,
    crate_context: Option<&CrateContext<'_>>,
) -> FileResult {
    let before = match declaration_inventory(source) {
        Ok(names) => names,
        Err(err) => return verdict(package, file, format!("parse-error: {}", first_line(&err))),
    };
    if before.is_empty() {
        return FileResult {
            package: package.to_string(),
            file: file.to_string(),
            scored: false,
            clean: false,
            ir_stable: false,
            reason: "skipped: no top-level declarations to compile".to_string(),
            crate_module: None,
        };
    }

    // Stage 1 — encode in LIBRARY mode (see the module doc), crate-aware when
    // the caller supplied the crate's symbol table.
    let program = match caught(|| match crate_context {
        Some(context) => context.graph.encode_file_library(source, &context.module),
        None => ball_lang_encoder::encode_library(source),
    }) {
        Ok(program) => program,
        Err(err) => return verdict(package, file, format!("encode-error: {err}")),
    };
    let first_ir = match canonical_ir(&program) {
        Ok(ir) => ir,
        Err(err) => return verdict(package, file, format!("encode-error: {err}")),
    };

    // Stage 2 — compile back in LIBRARY mode.
    let compiled = match caught(|| Compiler::new(&program).compile_library()) {
        Ok(source) => source,
        Err(err) => return verdict(package, file, format!("compile-error: {err}")),
    };
    if compiled.trim().is_empty() {
        return FileResult {
            package: package.to_string(),
            file: file.to_string(),
            scored: false,
            clean: false,
            ir_stable: false,
            reason: "skipped: the file compiles to nothing (no user module)".to_string(),
            crate_module: None,
        };
    }

    // Stage 3 — re-encode the compiled Rust.
    let program2 = match caught(|| ball_lang_encoder::encode_library(&compiled)) {
        Ok(program) => program,
        Err(err) => return verdict(package, file, format!("reencode-error: {err}")),
    };
    let second_ir = match canonical_ir(&program2) {
        Ok(ir) => ir,
        Err(err) => return verdict(package, file, format!("reencode-error: {err}")),
    };
    let ir_stable = first_ir == second_ir;

    // Stage 4 — declaration inventory preserved?
    let after = match declaration_inventory(&compiled) {
        Ok(names) => names,
        Err(err) => {
            return FileResult {
                ir_stable,
                ..verdict(
                    package,
                    file,
                    format!(
                        "reencode-error: the compiler emitted Rust that does not parse — {}",
                        first_line(&err)
                    ),
                )
            };
        }
    };
    let lost: Vec<&String> = before
        .iter()
        .filter(|name| !after.contains(*name))
        .collect();
    if !lost.is_empty() {
        let shown = lost
            .iter()
            .take(3)
            .map(|name| name.as_str())
            .collect::<Vec<_>>()
            .join(", ");
        return FileResult {
            ir_stable,
            ..verdict(
                package,
                file,
                format!(
                    "declaration-drift: lost {} declaration(s) — {shown}",
                    lost.len()
                ),
            )
        };
    }

    // Stage 5 — SECOND-GENERATION FIXPOINT. Generation 1 vs. 2 is not a usable
    // signal (the compiler faithfully lowers Ball's single `input` parameter
    // back to a named local, so almost nothing is stable across the first
    // pass). From generation 2 on that lowering is already applied, so a
    // pipeline that neither loses nor invents meaning must reach a fixpoint.
    let compiled2 = match caught(|| Compiler::new(&program2).compile_library()) {
        Ok(source) => source,
        Err(err) => {
            return FileResult {
                ir_stable,
                ..verdict(
                    package,
                    file,
                    format!("fixpoint-error: generation 2 failed to compile — {err}"),
                )
            };
        }
    };
    let third_ir = match caught(|| ball_lang_encoder::encode_library(&compiled2))
        .and_then(|program3| canonical_ir(&program3))
    {
        Ok(ir) => ir,
        Err(err) => {
            return FileResult {
                ir_stable,
                ..verdict(
                    package,
                    file,
                    format!("fixpoint-error: generation 2 failed to re-encode — {err}"),
                )
            };
        }
    };
    if compiled != compiled2 || second_ir != third_ir {
        return FileResult {
            ir_stable,
            ..verdict(
                package,
                file,
                "fixpoint-drift: recompiling the re-encoded program changed it again".to_string(),
            )
        };
    }

    FileResult {
        package: package.to_string(),
        file: file.to_string(),
        scored: true,
        clean: true,
        ir_stable,
        reason: "clean".to_string(),
        crate_module: None,
    }
}

/// One file Tier A did not score, and the rule that took it out.
///
/// An excluded file is NOT a `skipped` result: it never enters the results list
/// at all, so it is in neither the numerator nor the denominator. It is
/// reported on its own line so a denominator that moves because a RULE moved is
/// visible — which is the entire reason exclusions are named here rather than
/// silently filtered out of the walk.
#[derive(Debug, Clone)]
pub struct Exclusion {
    pub package: String,
    pub file: String,
    pub rule: String,
}

/// Directory names that are a crate's own tests, benches or examples — as
/// PACKAGE-ROOT directories, siblings of `src/`.
///
/// Cargo compiles each of these as its OWN crate against the library's public
/// API, not as part of the library — `cargo build` builds none of them. A user
/// encoding a dependency encodes `src/`, never `tests/`. That is true only of
/// the package-root directories: `src/tests/` is an ordinary module directory,
/// and `src/tests/foo.rs` declared `pub mod tests;` is public library code
/// `cargo build` builds like any other file (see [`test_only_path_rule`]).
const TEST_DIRS: [&str; 3] = ["tests", "benches", "examples"];

/// The PATH half of the Rust test-only rule: the rule excluding
/// `package_relative_path`, or `None` when nothing about its path says "test".
///
/// The argument is the path relative to the PACKAGE ROOT (the directory holding
/// `Cargo.toml`), and only its FIRST segment is matched, because that is the
/// only place a Cargo test/bench/example target can live
/// (<https://doc.rust-lang.org/cargo/guide/project-layout.html>). Matching every
/// parent segment instead — as this rule did until #637 — also excluded a
/// PUBLIC `src/tests/foo.rs` module, which is library code by every measure
/// that matters here: `cargo build` builds it, `mod`-graph reachability keeps
/// it, and a user encoding the crate encodes it. The `#[cfg(test)]`
/// REACHABILITY half is what removes a `src/tests/` that really is test-only
/// (that is how all 34 of `bitflags`' test files are now caught), and it can
/// tell the two apart where a path rule cannot.
///
/// Matched on WHOLE path segments, never as a substring: `latest.rs`,
/// `contest.rs` and `attestation/verify.rs` all contain "test" and are library
/// code, and excluding them would be exactly the silent denominator shrink this
/// rule exists to prevent (`tests/self_test.rs` pins all three).
pub fn test_only_path_rule(package_relative_path: &str) -> Option<String> {
    let mut parts = package_relative_path.split('/');
    let first = parts.next()?;
    // `parts.next()` must also be present: the first segment has to be a
    // DIRECTORY containing the file, not the file itself.
    if parts.next().is_some() && TEST_DIRS.contains(&first) {
        return Some("under a package-root tests/, benches/ or examples/ directory".to_string());
    }
    None
}

/// The package root of `dir`: the nearest ancestor — `dir` itself included —
/// that holds a `Cargo.toml`.
///
/// `None` when there is none, and that is deliberately load-bearing: without a
/// manifest there is no way to know which directory a `tests/` segment would be
/// a Cargo target OF, so [`classify_rust_files`] applies no path rule at all
/// and leaves those files in the denominator. Every exclusion this harness
/// makes must be one it can positively show, so "cannot tell" always means
/// KEEP.
pub fn package_root(dir: &Path) -> Option<PathBuf> {
    normalise(dir)
        .ancestors()
        .find(|ancestor| ancestor.join("Cargo.toml").is_file())
        .map(Path::to_path_buf)
}

/// Where a crate root may live, relative to a STUDIED SUBTREE.
///
/// A pin's studied subtree is normally the crate's `src/` (`lib` defaults to
/// "src"), where the root is `lib.rs` or `main.rs` — but the package ROOT is
/// studied directly too (by `--source-dir`, and by this crate's own self-test),
/// and there it is `src/lib.rs` or `src/main.rs`. Looking in only one of the two
/// places would silently switch the reachability half OFF for the other.
pub const CRATE_ROOT_CANDIDATES: [&str; 4] = ["lib.rs", "main.rs", "src/lib.rs", "src/main.rs"];

/// The crate root of a studied subtree: the first of [`CRATE_ROOT_CANDIDATES`]
/// that exists under `dir`, or `None`.
///
/// `None` is never a quiet answer — see [`CrateRoot`] and
/// [`classify_rust_files`]: without a root the `#[cfg(test)]` REACHABILITY half
/// of the test-only rule has nothing to walk from, and that half is the one
/// doing all the work on the real pins (34 exclusions by reachability, 0 by
/// path).
pub fn crate_root(dir: &Path) -> Option<PathBuf> {
    CRATE_ROOT_CANDIDATES
        .iter()
        .map(|name| dir.join(name))
        .find(|candidate| candidate.is_file())
}

/// Whether a studied subtree is CLAIMED to have a crate root (issue #648).
///
/// The `#[cfg(test)]` reachability half is anchored on a crate root found under
/// the studied subtree. Before #648 a failed search returned an empty exclusion
/// set and the run continued, so a pin whose `lib` pointed one level too deep, a
/// crate whose root moved, or a refactor of this resolver turned the only
/// working half of the rule OFF — every test-only file re-entered the
/// denominator with nothing saying so, and `coverage_table.py` read the
/// resulting jump in `scored` as an improvement to ratchet UP.
///
/// So the anchorless branch is now declared, per pin, rather than inferred from
/// a failed search.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CrateRoot {
    /// The default: the studied subtree must contain one of
    /// [`CRATE_ROOT_CANDIDATES`], and not finding one is an error.
    #[default]
    Required,
    /// The pin declared `"crateRoot": "none"` (or the CLI was given
    /// `--no-crate-root`): a bare directory of `.rs` files with no crate root to
    /// walk. Nothing can be shown `#[cfg(test)]`-only there, so nothing is
    /// excluded by that half — which is safe only because it was ASKED for.
    Absent,
}

/// Every `.rs` file under `dir`, sorted. Includes test-only files — the split
/// is [`classify_rust_files`]'s job.
pub fn rust_files_under(dir: &Path) -> Vec<PathBuf> {
    let mut files = Vec::new();
    collect(dir, &mut files);
    files.sort();
    files
}

/// Splits every `.rs` file under `dir` into the studied set and the test-only
/// exclusions (the owner's 2026-09-14 methodology decision on issue #491).
///
/// Rust's convention has TWO halves and BOTH are needed, because neither
/// subsumes the other:
///
///  1. a PATH rule — the PACKAGE-ROOT `tests/`, `benches/`, `examples/`
///     directories, which Cargo compiles as their own crates against the
///     library's public API and which `cargo build` does not build at all; and
///  2. a REACHABILITY rule — a file the crate's `mod` graph reaches ONLY by
///     passing through a `#[cfg(test)]` module. `src/tests.rs` is not under a
///     `tests/` directory, and a crate may keep its unit tests in a module
///     named anything at all.
///
/// This row is the reason the decision was made: 34 of the 110 scored Rust
/// files were `bitflags`' `src/tests.rs` and `src/tests/*.rs`, declared by
/// `src/lib.rs`'s `#[cfg(test)] mod tests;`. `crate_graph.rs::walk_items`
/// deliberately does not walk a `#[cfg(test)]` module (#621, matching `cargo
/// build`), so those files were measured with NO crate context — the worst of
/// both worlds, and a third of the denominator. All 34 are caught by the
/// REACHABILITY half; the path half never sees them, because `src/tests/` is
/// not a package-root Cargo target (#637).
///
/// A file the `mod` graph does not reach AT ALL (an unreferenced leftover) is
/// **not** excluded: it is still studied, exactly as before. The rule only ever
/// removes a file it can positively show is test-only, so a package root this
/// walk cannot locate or a `#[path]` it cannot follow can only ever leave the
/// denominator too LARGE, never too small.
///
/// An unresolvable CRATE ROOT is the one case where "too large" is not safe
/// enough to pass over quietly, and since #648 it is an error rather than an
/// empty exclusion set: it disables the half of the rule that does all the work,
/// and the denominator jump it produces is indistinguishable downstream from a
/// corpus that grew. `crate_root_policy` is how a genuinely anchorless subtree
/// declares itself — see [`CrateRoot`].
pub fn classify_rust_files(
    package: &str,
    dir: &Path,
    crate_root_policy: CrateRoot,
) -> Result<(Vec<PathBuf>, Vec<Exclusion>), String> {
    let root = crate_root(dir);
    if root.is_none() && crate_root_policy == CrateRoot::Required {
        return Err(crate_root_error(package, dir));
    }
    let cfg_test_only = match root.as_deref() {
        Some(root) => cfg_test_only_files(root),
        // Only reachable under `CrateRoot::Absent`: the pin DECLARED that there
        // is nothing to anchor on, so this half of the rule excludes nothing.
        None => BTreeSet::new(),
    };
    // The path half is anchored at the package root, so the studied subtree's
    // own position inside the package has to be known: `<checkout>/src` and
    // `<checkout>` must agree that `<checkout>/tests` is the Cargo target and
    // `<checkout>/src/tests` is not. `None` (no manifest anywhere above) turns
    // the path half OFF rather than guessing an anchor.
    let package_prefix = package_root(dir).and_then(|root| {
        normalise(dir)
            .strip_prefix(&root)
            .ok()
            .map(|inside| inside.to_string_lossy().replace('\\', "/"))
    });
    let mut studied = Vec::new();
    let mut excluded = Vec::new();
    for path in rust_files_under(dir) {
        let rel = path
            .strip_prefix(dir)
            .unwrap_or(&path)
            .to_string_lossy()
            .replace('\\', "/");
        let path_rule = package_prefix.as_deref().and_then(|prefix| {
            let package_rel = if prefix.is_empty() {
                rel.clone()
            } else {
                format!("{prefix}/{rel}")
            };
            test_only_path_rule(&package_rel)
        });
        let rule = path_rule.or_else(|| {
            cfg_test_only
                .contains(&normalise(&path))
                .then(|| "reachable only through a #[cfg(test)] module".to_string())
        });
        match rule {
            Some(rule) => excluded.push(Exclusion {
                package: package.to_string(),
                file: rel,
                rule,
            }),
            None => studied.push(path),
        }
    }
    Ok((studied, excluded))
}

/// The message a missing crate root fails with: every path searched, the
/// package root it DID find (or did not), and the one way to declare the
/// subtree genuinely anchorless.
///
/// A failure a reader cannot act on gets muted, so this names all three.
fn crate_root_error(package: &str, dir: &Path) -> String {
    let searched = CRATE_ROOT_CANDIDATES.join(", ");
    let manifest = match package_root(dir) {
        Some(root) => format!(
            "The package root (nearest Cargo.toml) is {}.",
            root.display()
        ),
        None => "No Cargo.toml was found at or above it either.".to_string(),
    };
    format!(
        "{package}: no crate root under {}: searched {searched} (relative to that \
         directory). {manifest} The #[cfg(test)] reachability half of the test-only rule is \
         anchored on the crate root — without one it can show NOTHING to be test-only, so \
         every test-only file silently re-enters the denominator and the published ratchet \
         reads that jump in `scored` as an improvement (issue #648). Point the pin's `lib` \
         (or --source-dir) at the crate's source root; if this really is a bare directory of \
         .rs files with no crate root, declare it — \"crateRoot\": \"none\" in the pin, or \
         --no-crate-root on the command line.",
        dir.display()
    )
}

/// `std::fs::canonicalize` when it works, the path as given otherwise — the
/// `mod`-graph walk and the file walk must agree on identity, and a failure to
/// canonicalise must not silently turn into "not test-only" for one and
/// "test-only" for the other.
fn normalise(path: &Path) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

/// The files the crate rooted at `root` reaches ONLY through a `#[cfg(test)]`
/// module.
///
/// Walked with `syn` DIRECTLY rather than through `ball_lang_encoder`'s own
/// `CrateGraph`, for the same reason the declaration inventory is: a harness
/// that asks the encoder which files matter cannot measure the encoder. It also
/// could not answer this question through `CrateGraph` even if it wanted to —
/// that walk skips `#[cfg(test)]` modules outright, so it cannot distinguish
/// "test-only" from "not reached at all", and those two must not be conflated.
///
/// The root is resolved by [`crate_root`] and passed IN, so the "no root at
/// all" case is decided once, by [`classify_rust_files`], where it can fail
/// loud — never here, where an empty return would read as "nothing is
/// test-only" (#648).
fn cfg_test_only_files(root: &Path) -> BTreeSet<PathBuf> {
    let mut walk = ModWalk {
        library: BTreeSet::new(),
        test: BTreeSet::new(),
        seen: BTreeSet::new(),
    };
    walk.file(root, false);
    walk.test.difference(&walk.library).cloned().collect()
}

struct ModWalk {
    /// Files reachable without passing through a `#[cfg(test)]` module.
    library: BTreeSet<PathBuf>,
    /// Files reachable through one.
    test: BTreeSet<PathBuf>,
    /// (file, under_cfg_test) pairs already walked — a crate may declare the
    /// same file from both sides, and it must be walked once per side.
    seen: BTreeSet<(PathBuf, bool)>,
}

impl ModWalk {
    /// Walks one file, resolving its `mod` children per the Rust reference's
    /// module-file rules — the same rules `rust/encoder/src/crate_graph.rs`
    /// follows, re-implemented here rather than borrowed (see
    /// [`cfg_test_only_files`]).
    fn file(&mut self, path: &Path, under_cfg_test: bool) {
        let key = (normalise(path), under_cfg_test);
        if !self.seen.insert(key.clone()) {
            return;
        }
        if under_cfg_test {
            self.test.insert(key.0);
        } else {
            self.library.insert(key.0);
        }
        let Ok(source) = std::fs::read_to_string(path) else {
            return;
        };
        let Ok(ast) = syn::parse_file(&source) else {
            // An unparseable file blocks the walk below it. That leaves the
            // denominator too large, never too small — the safe direction.
            return;
        };
        let file_dir = path.parent().map(Path::to_path_buf).unwrap_or_default();
        // A "mod-rs" file (`lib.rs`, `main.rs`, `mod.rs`) owns its own
        // directory; any other file owns a subdirectory named after its stem.
        let stem = path
            .file_stem()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_default();
        let mod_dir = if matches!(stem.as_str(), "lib" | "main" | "mod") {
            file_dir.clone()
        } else {
            file_dir.join(&stem)
        };
        // OUTSIDE an inline block a `#[path]` is relative to the directory of
        // the declaring FILE — which is NOT `mod_dir` for a non-mod-rs file.
        // Inside one it is relative to the nested module directory, which is
        // why `items` passes the new `mod_dir` as both.
        self.items(&ast.items, &mod_dir, &file_dir, under_cfg_test);
    }

    fn items(
        &mut self,
        items: &[syn::Item],
        mod_dir: &Path,
        path_base: &Path,
        under_cfg_test: bool,
    ) {
        for item in items {
            let syn::Item::Mod(item_mod) = item else {
                continue;
            };
            let nested_cfg_test = under_cfg_test || is_cfg_test(&item_mod.attrs);
            let name = item_mod.ident.to_string();
            // `#[path]` ON an inline block replaces the directory component
            // that block would otherwise contribute.
            let nested_dir = match path_attr(&item_mod.attrs) {
                Some(explicit) if item_mod.content.is_some() => path_base.join(explicit),
                _ => mod_dir.join(&name),
            };
            if let Some((_, inner)) = &item_mod.content {
                // An inline `mod a { … }` is its own module — one directory
                // deeper — but introduces no new FILE. Inside it, a `#[path]`
                // resolves against that nested directory.
                self.items(inner, &nested_dir, &nested_dir, nested_cfg_test);
                continue;
            }
            let candidates: Vec<PathBuf> = match path_attr(&item_mod.attrs) {
                Some(explicit) => vec![path_base.join(explicit)],
                None => vec![
                    mod_dir.join(format!("{name}.rs")),
                    mod_dir.join(&name).join("mod.rs"),
                ],
            };
            for candidate in candidates {
                if !candidate.is_file() {
                    continue;
                }
                self.file(&candidate, nested_cfg_test);
                break;
            }
        }
    }
}

/// `#[path = "…"]` on a `mod` declaration.
fn path_attr(attrs: &[syn::Attribute]) -> Option<String> {
    for attr in attrs {
        if !attr.path().is_ident("path") {
            continue;
        }
        if let syn::Meta::NameValue(nv) = &attr.meta
            && let syn::Expr::Lit(syn::ExprLit {
                lit: syn::Lit::Str(value),
                ..
            }) = &nv.value
        {
            return Some(value.value());
        }
    }
    None
}

/// Whether these attributes gate the item behind `cfg(test)`.
///
/// Deliberately the same semantics `rust/encoder/src/crate_graph.rs` documents
/// and tests for its own walk — `#[cfg(test)]` and `#[cfg(all(test, …))]` are
/// test-gated; `#[cfg(not(test))]`, `#[cfg(any(test, …))]` and a feature merely
/// NAMED "testing" are not — but implemented here rather than borrowed, because
/// a harness that asks the encoder what to measure cannot measure the encoder.
fn is_cfg_test(attrs: &[syn::Attribute]) -> bool {
    attrs.iter().any(|attr| {
        attr.path().is_ident("cfg")
            && attr
                .parse_args::<syn::Meta>()
                .is_ok_and(|meta| meta_is_test(&meta))
    })
}

fn meta_is_test(meta: &syn::Meta) -> bool {
    match meta {
        syn::Meta::Path(path) => path.is_ident("test"),
        syn::Meta::List(list) if list.path.is_ident("all") => list
            .parse_args_with(
                syn::punctuated::Punctuated::<syn::Meta, syn::Token![,]>::parse_terminated,
            )
            .is_ok_and(|nested| nested.iter().any(meta_is_test)),
        _ => false,
    }
}

fn collect(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            if path.file_name().is_some_and(|name| name == ".git") {
                continue;
            }
            collect(&path, out);
        } else if path.extension().is_some_and(|ext| ext == "rs") {
            out.push(path);
        }
    }
}

/// Runs Tier A over every `.rs` file under `dir`, CRATE-AWARE where possible
/// (issue #491).
///
/// The `mod` graph rooted at `dir` is walked once per package, and each file
/// the walk reached is then encoded with the whole crate's symbol table in
/// hand — which is what lets a `receiver.method(args)` or a bare-name call
/// whose callee lives in a sibling file resolve instead of failing loud. A file
/// the walk did not reach (a `#[cfg(test)]` module, an unreferenced leftover)
/// is still measured, with no crate context, exactly as before; so is every
/// file of a package whose `mod` graph could not be walked at all. Both cases
/// are visible per file in the JSON report's `crateModule`, never silently
/// folded into the crate-aware count. A package whose CRATE ROOT does not
/// resolve is a different matter and stops the run — see [`CrateRoot`].
pub fn study_directory(package: &str, dir: &Path) -> Result<Vec<FileResult>, String> {
    study_directory_with(package, dir, true, CrateRoot::Required)
}

/// [`study_directory`], with the crate walk switchable off (`rq1-study
/// --single-file`) and the crate-root policy declared (`--no-crate-root`).
///
/// The switchable walk exists so the before/after of issue #491's crate-aware
/// slice is reproducible **with one binary over one checkout**, rather than by
/// comparing two builds of the harness and hoping nothing else moved. Off, it
/// is exactly the measurement this harness made before `encode_crate` existed.
pub fn study_directory_with(
    package: &str,
    dir: &Path,
    crate_aware: bool,
    crate_root_policy: CrateRoot,
) -> Result<Vec<FileResult>, String> {
    Ok(study_package(package, dir, crate_aware, crate_root_policy)?.results)
}

/// One package's whole Tier A outcome: what was scored, and what the test-only
/// rule took out of the denominator.
///
/// The two travel together because they come from ONE
/// [`classify_rust_files`] pass — classifying twice would walk the `mod` graph
/// twice and, worse, could report an exclusion set that does not match the
/// files actually measured.
pub struct PackageStudy {
    pub results: Vec<FileResult>,
    pub excluded: Vec<Exclusion>,
}

/// [`study_directory_with`], keeping the exclusions the same pass produced.
pub fn study_package(
    package: &str,
    dir: &Path,
    crate_aware: bool,
    crate_root_policy: CrateRoot,
) -> Result<PackageStudy, String> {
    let (studied, excluded) = classify_rust_files(package, dir, crate_root_policy)?;
    let graph = if !crate_aware {
        None
    } else {
        match caught(|| ball_lang_encoder::CrateGraph::load(dir)) {
            Ok(graph) => Some(graph),
            Err(err) => {
                // Not a silent fallback: the whole package is about to be
                // measured the OLD way, and a reader of the numbers has to
                // know that.
                eprintln!(
                    "note: {package}: no crate-aware measurement — the mod graph under {} could \
                     not be walked ({err}); every file is measured single-file",
                    dir.display()
                );
                None
            }
        }
    };
    let results = studied
        .into_iter()
        .map(|path| {
            let rel = path
                .strip_prefix(dir)
                .unwrap_or(&path)
                .to_string_lossy()
                .replace('\\', "/");
            let context = graph.as_ref().and_then(|graph| {
                graph.module_name_for(&path).map(|module| CrateContext {
                    graph,
                    module: module.to_string(),
                })
            });
            // Read as BYTES and decode explicitly: no newline translation, so a
            // semantic lone \r survives into the measurement.
            match std::fs::read(&path) {
                Ok(bytes) => match String::from_utf8(bytes) {
                    Ok(source) => study_file_in_crate(package, &rel, &source, context.as_ref()),
                    Err(err) => verdict(package, &rel, format!("read-error: {err}")),
                },
                Err(err) => verdict(package, &rel, format!("read-error: {err}")),
            }
        })
        .collect();
    Ok(PackageStudy { results, excluded })
}

/// Prints the same summary shape as every other Tier A harness into `out` and
/// returns the process exit code. A run that scored nothing is a
/// harness/checkout failure, not a 0% result.
pub fn report(
    out: &mut String,
    results: &[FileResult],
    excluded: &[Exclusion],
    missing_pins: &[String],
) -> Result<i32, String> {
    use std::collections::BTreeMap;
    use std::fmt::Write as _;

    let scored: Vec<&FileResult> = results.iter().filter(|r| r.scored).collect();
    let total = scored.len();
    let clean = scored.iter().filter(|r| r.clean).count();
    let ir_stable = scored.iter().filter(|r| r.ir_stable).count();

    let mut by_reason: BTreeMap<&str, usize> = BTreeMap::new();
    for result in &scored {
        *by_reason
            .entry(result.reason.split(':').next().unwrap_or(""))
            .or_default() += 1;
    }
    let mut tags: Vec<(&str, usize)> = by_reason.into_iter().collect();
    tags.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(b.0)));
    for (tag, count) in tags {
        let _ = writeln!(out, "  {tag}: {count}");
    }
    let skipped = results.len() - total;
    if skipped > 0 {
        let _ = writeln!(out, "  skipped (no declarations, not scored): {skipped}");
    }
    // ALWAYS printed, zero included: a missing line is indistinguishable from
    // an exclusion rule that vanished, and summarize.sh fails the job on it.
    let _ = writeln!(out, "  excluded (test-only): {}", excluded.len());
    if !missing_pins.is_empty() {
        let _ = writeln!(
            out,
            "  unreachable pins (not scored): {}",
            missing_pins.join(", ")
        );
    }

    if total > 0 {
        let _ = writeln!(out, "Funnel (scored files that survived each stage):");
        for (threshold, label) in STAGES {
            let mut reached = 0;
            for result in &scored {
                if stage_reached(&result.reason)? >= threshold {
                    reached += 1;
                }
            }
            let _ = writeln!(out, "  {label}: {reached}/{total}");
        }
    }

    let pct = if total == 0 {
        0
    } else {
        ((clean as f64) * 100.0 / (total as f64)).round() as usize
    };
    let _ = writeln!(out, "Tier A: {clean}/{total} clean ({pct}%)");
    let _ = writeln!(
        out,
        "Tier A (IR fixpoint, informational): {ir_stable}/{total} stable"
    );
    let _ = writeln!(
        out,
        "Results: {clean} passed, {} failed, {total} total",
        total - clean
    );

    if total < 1 {
        return Ok(1);
    }
    Ok(0)
}
