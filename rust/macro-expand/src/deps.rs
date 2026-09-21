//! Dependency-defined `macro_rules!`, located through `cargo metadata`.
//!
//! A crate can invoke a macro another crate exports (`bitflags::bitflags!`,
//! `mini_bitflags::flags!`). Finding its definition needs two facts a `syn`
//! parse of the invoking file cannot supply: which package the first path
//! segment names, and where that package's sources are on disk.
//! `cargo metadata --format-version 1` supplies both —
//! `packages[].targets[].src_path` for the sources and `resolve.nodes[].deps[]`
//! for the edges, with `deps[].name` being the alias the dependent crate
//! actually writes (which can differ from the package name under
//! `package = "…"`).
//!
//! ## Only `#[macro_export]`ed ones, and only from DIRECT dependencies
//!
//! The Rust Reference, *Macros By Example*: "The `macro_export` attribute
//! exports the macro from the crate and makes it available in the root of the
//! crate for path-based resolution"; "By default, macros only have textual
//! scope and cannot be resolved by path." A non-exported macro in a dependency
//! is unreachable from here, so collecting it would invent resolutions Rust
//! itself would reject. Transitive dependencies are equally unreachable by a
//! plain `<krate>::<macro>!` path.
//!
//! ## Why the whole source directory, not the `mod` graph
//!
//! `#[macro_export]` hoists a macro to the crate root **whatever module
//! declares it**, so which `mod` chain reaches the file is irrelevant to this
//! question — and walking the directory also finds macros in `cfg`-gated
//! modules that a feature this build does not enable would otherwise hide.
//!
//! ## Nothing here is ever silent
//!
//! A missing manifest, a `cargo metadata` that fails, output that does not
//! parse — each records a reason on the table, and the FIRST invocation that
//! would have needed a dependency macro fails loud naming that reason. A
//! single dependency source file `syn` cannot parse is recorded too, and named
//! in the diagnostic of any macro that then fails to resolve.
//!
//! That holds for DIRECTORIES as much as for files (issue #678). A subdirectory
//! whose entries cannot be listed, and an entry whose metadata cannot be read
//! (a dangling symlink), are paths the walk *could not look at* — which is not
//! the same answer as "no definition is there", and the two must never be
//! conflated. Both go through the same `note_unreadable_source`.
//!
//! And it holds one step earlier, for the dependency EDGES themselves (issue
//! #705). Resolving `resolve.nodes[].deps[]` to a source directory takes four
//! lookups — the edge's `name`, its `pkg`, the `packages[]` entry that id
//! names, and that package's library target's `src_path` — plus the library
//! target itself. Each was a bare `else { continue }`, so a malformed document
//! made a dependency's macros unresolvable and the next `<krate>::<macro>!`
//! claimed the crate had no such macro. Each is now a
//! `note_unresolvable_dependency` riding the same list into the same
//! diagnostics. The ONE deliberate silence is a `proc-macro`-only package:
//! that skip is an answer this crate documents, not a drop.

use std::path::{Path, PathBuf};
use std::process::Command;

use crate::{MacroOrigin, MacroTable};

impl MacroTable {
    /// Seed this table with every `#[macro_export] macro_rules!` the direct
    /// dependencies of the crate at `manifest_path` export.
    ///
    /// Never panics and never fails the caller: an unreadable dependency graph
    /// is recorded on the table, and only an invocation that actually needs a
    /// dependency macro turns it into a loud error.
    pub fn seed_from_cargo_metadata(&mut self, manifest_path: &Path) {
        match run_cargo_metadata(manifest_path) {
            Ok(json) => self.seed_from_cargo_metadata_json(&json),
            Err(reason) => self.set_dependencies_unavailable(reason),
        }
    }

    /// Seed this table from a `cargo metadata --format-version 1` document that
    /// has already been produced.
    ///
    /// [`seed_from_cargo_metadata`](Self::seed_from_cargo_metadata) is this plus
    /// running `cargo`. It is split out because the *shape* of that document is
    /// a contract this crate depends on and cannot be exercised any other way:
    /// `cargo` only ever emits well-formed output, so a `deps[]` node missing a
    /// field — the case that decides whether a dependency's macros resolve or
    /// vanish — is unreachable through the `cargo`-running entry point. Handing
    /// the document in is what makes those shapes testable against the SHIPPED
    /// code instead of a re-implementation of it.
    pub fn seed_from_cargo_metadata_json(&mut self, metadata: &str) {
        let metadata: serde_json::Value = match serde_json::from_str(metadata) {
            Ok(value) => value,
            Err(err) => {
                self.set_dependencies_unavailable(format!(
                    "`cargo metadata` output could not be parsed: {err}"
                ));
                return;
            }
        };
        match direct_dependency_sources(&metadata) {
            Ok(graph) => {
                for (what, reason) in graph.unusable {
                    self.note_unresolvable_dependency(&what, &reason);
                }
                for (krate, src_root) in graph.sources {
                    self.collect_exported_macros(&krate, &src_root);
                }
            }
            Err(reason) => self.set_dependencies_unavailable(reason),
        }
    }

    fn collect_exported_macros(&mut self, krate: &str, src_root: &Path) {
        let walk = rust_files_under(src_root);
        for (path, reason) in walk.unreadable {
            self.note_unreadable_source(&path.display().to_string(), &reason);
        }
        for file in walk.files {
            let source = match std::fs::read_to_string(&file) {
                Ok(source) => source,
                Err(err) => {
                    self.note_unreadable_source(&file.display().to_string(), &err.to_string());
                    continue;
                }
            };
            let ast = match syn::parse_file(&source) {
                Ok(ast) => ast,
                Err(err) => {
                    self.note_unreadable_source(&file.display().to_string(), &err.to_string());
                    continue;
                }
            };
            self.collect_exported_items(krate, &ast.items);
        }
    }

    fn collect_exported_items(&mut self, krate: &str, items: &[syn::Item]) {
        for item in items {
            match item {
                syn::Item::Macro(item_macro) if item_macro.ident.is_some() => {
                    let exported = item_macro
                        .attrs
                        .iter()
                        .any(|attr| attr.path().is_ident("macro_export"));
                    if !exported {
                        continue;
                    }
                    // A definition the engine cannot parse is RECORDED, not
                    // swallowed: the next invocation that needs it says so.
                    if let Err(err) = self.insert_macro_rules(
                        item_macro,
                        MacroOrigin::Dependency {
                            krate: krate.to_owned(),
                        },
                    ) {
                        let name = item_macro
                            .ident
                            .as_ref()
                            .expect("checked by the match guard");
                        self.note_unreadable_source(&format!("{krate}::{name}"), &err.to_string());
                    }
                }
                syn::Item::Mod(item_mod) => {
                    if let Some((_, inner)) = &item_mod.content {
                        self.collect_exported_items(krate, inner);
                    }
                }
                _ => {}
            }
        }
    }
}

/// The `cargo` binary this build was launched with, falling back to whatever is
/// on `PATH`.
/// <https://doc.rust-lang.org/cargo/reference/environment-variables.html>
fn cargo_binary() -> PathBuf {
    std::env::var_os("CARGO")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("cargo"))
}

fn run_cargo_metadata(manifest_path: &Path) -> Result<String, String> {
    if !manifest_path.is_file() {
        return Err(format!(
            "no crate manifest at `{}`",
            manifest_path.display()
        ));
    }
    let output = Command::new(cargo_binary())
        .arg("metadata")
        .arg("--format-version")
        .arg("1")
        .arg("--manifest-path")
        .arg(manifest_path)
        .output()
        .map_err(|err| format!("could not run `cargo metadata`: {err}"))?;
    if !output.status.success() {
        return Err(format!(
            "`cargo metadata --manifest-path {}` failed ({}): {}",
            manifest_path.display(),
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    String::from_utf8(output.stdout)
        .map_err(|err| format!("`cargo metadata` output is not UTF-8: {err}"))
}

/// What `cargo metadata`'s dependency edges resolved to — and every edge that
/// could not be resolved.
struct DependencyGraph {
    /// `(dependency alias, that dependency's source directory)` for every
    /// DIRECT dependency of the resolved root package whose sources were
    /// located.
    sources: Vec<(String, PathBuf)>,
    /// `(what, reason)` for every `deps[]` edge that named a dependency this
    /// walk could not locate sources for. Never a silent skip: each becomes a
    /// note on the table and is carried into the diagnostic of any macro that
    /// then fails to resolve.
    unusable: Vec<(String, String)>,
}

/// Resolve the DIRECT dependencies of the root package to their source
/// directories.
fn direct_dependency_sources(metadata: &serde_json::Value) -> Result<DependencyGraph, String> {
    let resolve = metadata
        .get("resolve")
        .ok_or_else(|| "`cargo metadata` reported no dependency resolution".to_owned())?;
    let root = resolve
        .get("root")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| {
            "`cargo metadata` reported no root package — a virtual workspace manifest has no \
             dependencies of its own"
                .to_owned()
        })?;
    let nodes = resolve
        .get("nodes")
        .and_then(serde_json::Value::as_array)
        .ok_or_else(|| "`cargo metadata`'s `resolve.nodes` is not an array".to_owned())?;
    let root_node = nodes
        .iter()
        .find(|node| node.get("id").and_then(serde_json::Value::as_str) == Some(root))
        .ok_or_else(|| {
            format!("`cargo metadata` has no resolve node for the root package {root}")
        })?;

    let packages = metadata
        .get("packages")
        .and_then(serde_json::Value::as_array)
        .ok_or_else(|| "`cargo metadata`'s `packages` is not an array".to_owned())?;

    let mut sources = Vec::new();
    let mut unusable: Vec<(String, String)> = Vec::new();
    let deps = root_node
        .get("deps")
        .and_then(serde_json::Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[]);
    for dep in deps {
        let declared_pkg = dep.get("pkg").and_then(serde_json::Value::as_str);
        // `deps[].name` is the alias the dependent crate writes in a path
        // (`mini_bitflags::flags!`), which is what resolution here matches on —
        // NOT the package name, which may differ under `package = "…"`.
        //
        // Every arm below is an edge whose CRATE this walk never looked in, so
        // none of them may be silent (issue #705): without a note, the next
        // `<krate>::<macro>!` would report "no macro with that name is in that
        // crate" — a claim the walk has no evidence for.
        let Some(alias) = dep.get("name").and_then(serde_json::Value::as_str) else {
            unusable.push((
                declared_pkg
                    .unwrap_or("<a `deps[]` entry carrying neither `name` nor `pkg`>")
                    .to_owned(),
                "this `resolve.nodes[].deps[]` entry has no `name`, so there is no alias to \
                 match a `<krate>::<macro>!` path against and its macros cannot be reached"
                    .to_owned(),
            ));
            continue;
        };
        let Some(pkg_id) = declared_pkg else {
            unusable.push((
                alias.to_owned(),
                "this `resolve.nodes[].deps[]` entry has no `pkg`, so the package it names \
                 cannot be found and its sources cannot be located"
                    .to_owned(),
            ));
            continue;
        };
        let Some(package) = packages
            .iter()
            .find(|p| p.get("id").and_then(serde_json::Value::as_str) == Some(pkg_id))
        else {
            unusable.push((
                alias.to_owned(),
                format!(
                    "its `pkg` id `{pkg_id}` has no entry in `packages[]` — the `cargo metadata` \
                     document disagrees with itself, so this crate's sources cannot be located"
                ),
            ));
            continue;
        };
        let targets = package
            .get("targets")
            .and_then(serde_json::Value::as_array)
            .map(Vec::as_slice)
            .unwrap_or(&[]);
        // A `proc-macro` target exports no `macro_rules!` — its macros are Rust
        // code compiled into a compiler plugin, out of scope by design. That
        // skip is an ANSWER, not a drop, so it is deliberately NOT noted:
        // recording it would put every ordinary `#[derive]` dependency into the
        // diagnostic of every failing resolution.
        let lib = targets.iter().find(|target| {
            target
                .get("kind")
                .and_then(serde_json::Value::as_array)
                .is_some_and(|kinds| {
                    kinds
                        .iter()
                        .any(|kind| matches!(kind.as_str(), Some("lib" | "rlib" | "dylib")))
                })
        });
        let Some(lib) = lib else {
            if !has_proc_macro_target(targets) {
                unusable.push((
                    alias.to_owned(),
                    format!(
                        "its package `{pkg_id}` declares no `lib`/`rlib`/`dylib` target, so there \
                         is no library source tree to walk for `#[macro_export]`ed definitions"
                    ),
                ));
            }
            continue;
        };
        let Some(src_path) = lib.get("src_path").and_then(serde_json::Value::as_str) else {
            unusable.push((
                alias.to_owned(),
                format!(
                    "the library target of its package `{pkg_id}` has no `src_path`, so the \
                     directory holding its sources is unknown"
                ),
            ));
            continue;
        };
        let src_root = Path::new(src_path)
            .parent()
            .unwrap_or_else(|| Path::new("."))
            .to_path_buf();
        sources.push((alias.to_owned(), src_root));
    }
    Ok(DependencyGraph { sources, unusable })
}

/// Does this package declare a `proc-macro` target?
///
/// A package with one and no library target is the documented out-of-scope
/// case, not a drop: its macros are compiled Rust, not `macro_rules!`.
fn has_proc_macro_target(targets: &[serde_json::Value]) -> bool {
    targets.iter().any(|target| {
        target
            .get("kind")
            .and_then(serde_json::Value::as_array)
            .is_some_and(|kinds| kinds.iter().any(|kind| kind.as_str() == Some("proc-macro")))
    })
}

/// What walking a dependency's source directory found — and what it could not
/// even look at.
struct SourceWalk {
    /// Every `.rs` file under the root, recursively, in a deterministic order.
    files: Vec<PathBuf>,
    /// `(path, reason)` for every path the walk could not inspect: a directory
    /// whose entries could not be listed, an entry that could not be read out of
    /// its directory, a path whose metadata could not be stat'ed. Sorted, so the
    /// diagnostic is deterministic.
    unreadable: Vec<(PathBuf, String)>,
}

/// Walk `root` for `.rs` files, recording — never swallowing — every path that
/// could not be looked at.
fn rust_files_under(root: &Path) -> SourceWalk {
    let mut files = Vec::new();
    let mut unreadable = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let entries = match std::fs::read_dir(&dir) {
            Ok(entries) => entries,
            Err(err) => {
                unreadable.push((dir, err.to_string()));
                continue;
            }
        };
        for entry in entries {
            let path = match entry {
                Ok(entry) => entry.path(),
                Err(err) => {
                    // The directory opened but one of its entries did not read.
                    // The offending name is exactly what is unavailable, so the
                    // directory is the most specific path there is to report.
                    unreadable.push((dir.clone(), err.to_string()));
                    continue;
                }
            };
            // `metadata` follows symlinks, as the `Path::is_dir` this replaces
            // did. The difference is that its failure is now an ANSWER — this
            // path could not be looked at — instead of a silent `false` that
            // dropped a dangling symlink on the floor.
            match std::fs::metadata(&path) {
                Ok(meta) if meta.is_dir() => stack.push(path),
                Ok(_) => {
                    if path.extension().is_some_and(|ext| ext == "rs") {
                        files.push(path);
                    }
                }
                Err(err) => unreadable.push((path, err.to_string())),
            }
        }
    }
    files.sort();
    unreadable.sort();
    SourceWalk { files, unreadable }
}
