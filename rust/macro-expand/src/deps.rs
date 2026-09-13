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
        let metadata = match run_cargo_metadata(manifest_path) {
            Ok(json) => json,
            Err(reason) => {
                self.set_dependencies_unavailable(reason);
                return;
            }
        };
        match direct_dependency_sources(&metadata) {
            Ok(sources) => {
                for (krate, src_root) in sources {
                    self.collect_exported_macros(&krate, &src_root);
                }
            }
            Err(reason) => self.set_dependencies_unavailable(reason),
        }
    }

    fn collect_exported_macros(&mut self, krate: &str, src_root: &Path) {
        for file in rust_files_under(src_root) {
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

fn run_cargo_metadata(manifest_path: &Path) -> Result<serde_json::Value, String> {
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
    serde_json::from_slice(&output.stdout)
        .map_err(|err| format!("`cargo metadata` output could not be parsed: {err}"))
}

/// `(dependency alias, that dependency's source directory)` for every DIRECT
/// dependency of the resolved root package.
fn direct_dependency_sources(
    metadata: &serde_json::Value,
) -> Result<Vec<(String, PathBuf)>, String> {
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
    let deps = root_node
        .get("deps")
        .and_then(serde_json::Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[]);
    for dep in deps {
        // `deps[].name` is the alias the dependent crate writes in a path
        // (`mini_bitflags::flags!`), which is what resolution here matches on —
        // NOT the package name, which may differ under `package = "…"`.
        let Some(alias) = dep.get("name").and_then(serde_json::Value::as_str) else {
            continue;
        };
        let Some(pkg_id) = dep.get("pkg").and_then(serde_json::Value::as_str) else {
            continue;
        };
        let Some(package) = packages
            .iter()
            .find(|p| p.get("id").and_then(serde_json::Value::as_str) == Some(pkg_id))
        else {
            continue;
        };
        let targets = package
            .get("targets")
            .and_then(serde_json::Value::as_array)
            .map(Vec::as_slice)
            .unwrap_or(&[]);
        // A `proc-macro` target exports no `macro_rules!` — its macros are Rust
        // code compiled into a compiler plugin, out of scope by design.
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
        let Some(src_path) = lib
            .and_then(|target| target.get("src_path"))
            .and_then(serde_json::Value::as_str)
        else {
            continue;
        };
        let src_root = Path::new(src_path)
            .parent()
            .unwrap_or_else(|| Path::new("."))
            .to_path_buf();
        sources.push((alias.to_owned(), src_root));
    }
    Ok(sources)
}

/// Every `.rs` file under `root`, recursively, in a deterministic order.
fn rust_files_under(root: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for path in entries.flatten().map(|entry| entry.path()) {
            if path.is_dir() {
                stack.push(path);
            } else if path.extension().is_some_and(|ext| ext == "rs") {
                out.push(path);
            }
        }
    }
    out.sort();
    out
}
