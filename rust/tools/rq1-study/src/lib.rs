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
    }
}

/// Runs Tier A over one file's `source` and returns its verdict.
pub fn study_file(package: &str, file: &str, source: &str) -> FileResult {
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
        };
    }

    // Stage 1 — encode in LIBRARY mode (see the module doc).
    let program = match caught(|| ball_lang_encoder::encode_library(source)) {
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
    }
}

/// Every `.rs` file under `dir`, sorted.
pub fn rust_files_under(dir: &Path) -> Vec<PathBuf> {
    let mut files = Vec::new();
    collect(dir, &mut files);
    files.sort();
    files
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

/// Runs Tier A over every `.rs` file under `dir`.
pub fn study_directory(package: &str, dir: &Path) -> Vec<FileResult> {
    rust_files_under(dir)
        .into_iter()
        .map(|path| {
            let rel = path
                .strip_prefix(dir)
                .unwrap_or(&path)
                .to_string_lossy()
                .replace('\\', "/");
            // Read as BYTES and decode explicitly: no newline translation, so a
            // semantic lone \r survives into the measurement.
            match std::fs::read(&path) {
                Ok(bytes) => match String::from_utf8(bytes) {
                    Ok(source) => study_file(package, &rel, &source),
                    Err(err) => verdict(package, &rel, format!("read-error: {err}")),
                },
                Err(err) => verdict(package, &rel, format!("read-error: {err}")),
            }
        })
        .collect()
}

/// Prints the same summary shape as every other Tier A harness into `out` and
/// returns the process exit code. A run that scored nothing is a
/// harness/checkout failure, not a 0% result.
pub fn report(
    out: &mut String,
    results: &[FileResult],
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
