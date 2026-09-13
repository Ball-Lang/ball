//! Crate-aware encoding (issue #491): walk a crate's `mod` graph and encode
//! every file against ONE crate-wide symbol table.
//!
//! This is the Rust sibling of `dart/encoder/lib/package_encoder.dart`, added
//! per the epic owner's 2026-09-13 decision on issue #491. The single-file
//! [`crate::encode`] cannot resolve a `receiver.method(args)` whose method is
//! declared in another file — 24 of the 196 files in that issue's real-code
//! study, its largest remaining bucket — because `syn` gives this encoder no
//! semantic model and the call carries no module-qualifying path segment to
//! read the callee's home module off. Seeing the whole crate at once is what
//! supplies the missing fact, and nothing else does.
//!
//! ## Module resolution follows the Rust reference, not a guess
//!
//! <https://doc.rust-lang.org/reference/items/modules.html>, "Module source
//! filenames" and "The `path` attribute":
//!
//! - An out-of-line `mod foo;` loads `<dir>/foo.rs` **or** `<dir>/foo/mod.rs`;
//!   having both is an error ("It is not allowed to have both `util.rs` and
//!   `util/mod.rs`"), and so is having neither.
//! - `<dir>` is the declaring file's own directory when that file is a
//!   **mod-rs** file (the crate root, or any `mod.rs`), and the declaring
//!   file's directory plus a directory named after it otherwise — so
//!   `mod deep;` inside `src/gamma.rs` is `src/gamma/deep.rs`.
//! - `#[path = "..."]` on a module **not inside an inline `mod` block** is
//!   relative to the directory the source file is located in — note that this
//!   is the file's own directory even for a non-mod-rs file, which is why
//!   [`ModuleDir`] tracks the `#[path]` base separately from the out-of-line
//!   base.
//! - Inside an inline `mod` block the two bases coincide, at the mod-rs (or
//!   non-mod-rs-plus-its-own-name) directory extended by the inline module
//!   components.
//!
//! ## Deliberate deviations, each for a stated reason
//!
//! - **`#[cfg(test)]` modules are not walked.** `cargo build` does not compile
//!   them, so neither does this; they are also where `assert!`-heavy code
//!   lives, and one loud panic aborts the whole crate encode. Proven by
//!   `crate_encoding.rs::a_cfg_test_module_is_not_walked`, whose fixture's
//!   test module holds an `assert!` the encoder has no mapping for.
//! - **An inline `mod` block becomes its own Ball module**, not a flattening
//!   into its parent — it is a separate Rust module, and flattening would
//!   collide two same-named items that Rust keeps apart.
//! - **A missing module file is a loud panic**, never a silently dropped
//!   module: dropping one would take every declaration in it with it.
//!
//! ## Resolution is still name-only, now crate-wide
//!
//! This encoder has always resolved by NAME, with no type information — the
//! bias `methods.rs`' module doc records for `.len()`/`.is_empty()` and
//! `.claude/rules/dart.md` records as `_looksLikeTypeName`. Crate mode widens
//! the *scope* of that lookup from one file to the whole crate; it does not
//! change its nature. Two consequences worth knowing, both deliberate:
//!
//! - A same-file declaration still wins, because [`Encoder::seed_from_crate`]
//!   runs BEFORE the file's own pre-pass and the pre-pass overwrites.
//! - A built-in method arm that already defers to a user method of that name
//!   (`.fuse()`, `.is_empty()`) now defers to one declared anywhere in the
//!   crate, not just in this file. That is strictly the more conservative
//!   direction — it routes to the user's own body rather than to a `std`
//!   lowering that might be wrong for their type.
//!
//! ## Output shape
//!
//! One Ball [`Module`] per Rust module, named by its Rust module path
//! (`counter`, `gamma::inner`), except the crate root, which is `main`
//! because `Program.entry_module` must name it and
//! `ball-lang-compiler`'s `compile`/`compile_library` inline that module's
//! items at the crate root. Every *other* user module is emitted by the
//! compiler as its own `pub mod` (issue #38), and a cross-module call carries
//! `FunctionCall.module` — which
//! `rust/compiler/src/type_emit.rs::resolve_user_call_name` turns into the
//! `<mod>::` qualifier. **No compiler change was needed for any of this.**
//!
//! A crate whose root declares `fn main` is runnable (`entry_function =
//! "main"`); one that does not keeps the library-mode semantics issue #569
//! established for a single file — an empty `entry_function`, structurally
//! legal and deliberately not runnable, never a synthesised fake entry point.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::rc::Rc;

use ball_lang_shared::proto::ball::v1::{Module, Program};

use crate::types::has_self_receiver;
use crate::{EncodedFile, assemble_program, encode_file_module};

/// One Rust module of a crate, ready to encode.
#[derive(Debug, Clone)]
pub struct CrateModule {
    /// The Ball module name: `main` for the crate root, otherwise the Rust
    /// module path joined with `::` (`counter`, `gamma::inner`).
    pub name: String,
    /// The file this module's items came from. An inline `mod` block shares
    /// its parent's file.
    pub file: PathBuf,
    /// The items themselves. Held as a parsed [`syn::File`] rather than as
    /// source text so an inline `mod` block needs no re-printing round trip.
    pub ast: syn::File,
}

/// Everything the encoder needs to know about the REST of the crate while
/// encoding one of its files: which module declares each free function, each
/// instance method, and each type.
///
/// A name declared in more than one module is recorded as ambiguous rather
/// than rejected outright, and only fails when a *use site* actually needs it
/// resolved across module boundaries — a crate is not broken just because two
/// of its modules both declare a `size`, and a call from inside one of them is
/// unambiguous.
#[derive(Debug, Default, Clone)]
pub struct CrateSymbols {
    /// Every Ball module name in the crate.
    pub(crate) modules: BTreeSet<String>,
    /// Free function short name → the modules declaring it.
    pub(crate) fn_modules: BTreeMap<String, BTreeSet<String>>,
    /// Free function short name → its declared parameter names.
    pub(crate) fn_params: HashMap<String, Vec<String>>,
    /// Instance-method short name → the modules declaring it. Keyed by short
    /// name only, because `ball-lang-compiler`'s own dispatcher
    /// (`compile_method_dispatchers`) resolves by short name too.
    pub(crate) method_modules: BTreeMap<String, BTreeSet<String>>,
    /// Instance-method short name → its non-`self` parameter names.
    pub(crate) method_params: HashMap<String, Vec<String>>,
    /// Type short name → the modules declaring it.
    pub(crate) type_modules: BTreeMap<String, BTreeSet<String>>,
    /// `(owner type, associated fn)` → parameter names, for receiver-less
    /// associated functions.
    pub(crate) static_method_params: HashMap<(String, String), Vec<String>>,
    /// Every tuple struct's short name, crate-wide.
    pub(crate) tuple_struct_names: HashSet<String>,
    /// Every unit struct's short name, crate-wide.
    pub(crate) unit_struct_names: HashSet<String>,
    /// Enum short name → the module declaring it (first wins; an enum is only
    /// ever consulted for a same-module variant read).
    pub(crate) enum_modules: BTreeMap<String, String>,
}

impl CrateSymbols {
    /// Which module should a call to `name` target, seen from
    /// `current_module`? `Ok(None)` means "this module" (an unqualified Ball
    /// call); `Ok(Some(m))` a cross-module call; `Err(modules)` an ambiguity
    /// no syntax-only encoder can resolve.
    fn owner_of<'a>(
        table: &'a BTreeMap<String, BTreeSet<String>>,
        name: &str,
        current_module: &str,
    ) -> Option<Result<Option<&'a str>, &'a BTreeSet<String>>> {
        let owners = table.get(name)?;
        if owners.contains(current_module) {
            return Some(Ok(None));
        }
        let mut iter = owners.iter();
        match (iter.next(), iter.next()) {
            (Some(only), None) => Some(Ok(Some(only.as_str()))),
            (Some(_), Some(_)) => Some(Err(owners)),
            _ => None,
        }
    }

    pub(crate) fn declares_module(&self, name: &str) -> bool {
        self.modules.contains(name)
    }

    /// Which module declares the enum `name`, if any file of the crate does.
    pub(crate) fn enum_module(&self, name: &str) -> Option<&str> {
        self.enum_modules.get(name).map(String::as_str)
    }
}

/// A crate's `mod` graph plus the symbol table built from it.
#[derive(Debug, Clone)]
pub struct CrateGraph {
    modules: Vec<CrateModule>,
    symbols: Rc<CrateSymbols>,
    root_has_main: bool,
}

impl CrateGraph {
    /// Walk the crate rooted at `path` — the directory holding `Cargo.toml`,
    /// the `src` directory, or the root source file itself.
    pub fn load(path: &Path) -> CrateGraph {
        let root = resolve_crate_root(path);
        let mut modules = Vec::new();
        walk_file(&root, Vec::new(), true, &mut modules);
        let symbols = Rc::new(collect_symbols(&modules));
        let root_has_main = modules
            .iter()
            .find(|m| m.name == ROOT_MODULE)
            .map(|m| declares_main(&m.ast))
            .unwrap_or(false);
        CrateGraph {
            modules,
            symbols,
            root_has_main,
        }
    }

    /// Every module of the crate, crate root first.
    pub fn modules(&self) -> &[CrateModule] {
        &self.modules
    }

    /// The Ball module name for a file of this crate, if the walk reached it.
    /// A file the `mod` graph never names (an unreferenced leftover, a
    /// `#[cfg(test)]` module) has none.
    pub fn module_name_for(&self, file: &Path) -> Option<&str> {
        let file = file.canonicalize().unwrap_or_else(|_| file.to_path_buf());
        self.modules
            .iter()
            .find(|m| {
                m.file
                    .canonicalize()
                    .unwrap_or_else(|_| m.file.clone())
                    .as_path()
                    == file
            })
            .map(|m| m.name.as_str())
    }

    /// The crate-wide symbol table, for callers that encode one file at a time
    /// (the Tier A coverage harness) rather than the whole crate.
    pub fn symbols(&self) -> &Rc<CrateSymbols> {
        &self.symbols
    }

    /// Encode the whole crate into one [`Program`]. Runnable when the crate
    /// root declares `fn main`, library-mode (empty `entry_function`)
    /// otherwise — see this module's doc comment.
    pub fn encode(&self) -> Program {
        let entry_function = if self.root_has_main { "main" } else { "" };
        self.encode_with_entry(entry_function)
    }

    /// Encode the whole crate in library mode regardless of whether the root
    /// declares `fn main` (`ball encode --crate --lib`).
    pub fn encode_library(&self) -> Program {
        self.encode_with_entry("")
    }

    fn encode_with_entry(&self, entry_function: &str) -> Program {
        let mut encoded_modules: Vec<Module> = Vec::new();
        let mut unresolved: BTreeSet<String> = BTreeSet::new();
        for module in &self.modules {
            let EncodedFile {
                module: encoded,
                has_main: _,
                unresolved_modules,
            } = encode_file_module(&module.ast, &module.name, Some(self.symbols.clone()));
            unresolved.extend(unresolved_modules);
            encoded_modules.push(encoded);
        }
        assemble_program(encoded_modules, entry_function, &unresolved)
    }

    /// Encode ONE file of this crate as a standalone library-mode program,
    /// with the crate's symbol table in hand. A sibling module's callee
    /// resolves to a real cross-module call, whose module is then a
    /// deliberately unresolved `ModuleImport` because that module is not part
    /// of this one-file program. Used by the Tier A coverage harness, which
    /// scores one file at a time.
    ///
    /// The emitted module KEEPS its own crate module name and
    /// `Program.entry_module` names it — rather than renaming it to `main`,
    /// which would make a call into the crate ROOT (`module: "main"`) look like
    /// a same-module call and emit an unqualified call to a function this
    /// one-file program does not contain. `compile_library` looks the entry
    /// module up by name and inlines it at the crate root; any name works.
    pub fn encode_file_library(&self, source: &str, module_name: &str) -> Program {
        let ast = syn::parse_file(source)
            .unwrap_or_else(|err| panic!("ball-lang-encoder: failed to parse Rust source: {err}"));
        let encoded = encode_file_module(&ast, module_name, Some(self.symbols.clone()));
        let mut program = assemble_program(vec![encoded.module], "", &encoded.unresolved_modules);
        program.entry_module = module_name.to_string();
        program
    }
}

/// The Ball module name of a crate root. Fixed, because `Program.entry_module`
/// must name the module `ball-lang-compiler` inlines at the crate root.
pub(crate) const ROOT_MODULE: &str = "main";

/// Encode the crate rooted at `path` into a [`Program`] (`ball encode
/// --crate`). See [`CrateGraph::encode`].
pub fn encode_crate(path: &Path) -> Program {
    CrateGraph::load(path).encode()
}

/// Encode the crate rooted at `path` in library mode, whether or not its root
/// declares `fn main` (`ball encode --crate --lib`).
pub fn encode_crate_library(path: &Path) -> Program {
    CrateGraph::load(path).encode_library()
}

// ════════════════════════════════════════════════════════════
// Crate root + mod graph
// ════════════════════════════════════════════════════════════

/// Resolve a user-supplied path to the crate's ROOT SOURCE FILE. Accepts the
/// directory holding `Cargo.toml`, a `src` directory, or the root file itself
/// — so `ball encode --crate` does not depend on how the path was spelled.
pub(crate) fn resolve_crate_root(path: &Path) -> PathBuf {
    if path.is_file() {
        return path.to_path_buf();
    }
    if !path.is_dir() {
        panic!(
            "ball-lang-encoder: no crate root at `{}` — the path does not exist",
            path.display()
        );
    }
    for candidate in [
        path.join("src/lib.rs"),
        path.join("src/main.rs"),
        path.join("lib.rs"),
        path.join("main.rs"),
    ] {
        if candidate.is_file() {
            return candidate;
        }
    }
    panic!(
        "ball-lang-encoder: no crate root under `{}` — looked for src/lib.rs, src/main.rs, \
         lib.rs and main.rs",
        path.display()
    );
}

/// The two directories a module declaration resolves against. They differ at a
/// file's top level and coincide inside an inline `mod` block — see this
/// module's doc comment for the reference wording.
struct ModuleDir {
    /// Base for an out-of-line `mod foo;` with no `#[path]`.
    out_of_line: PathBuf,
    /// Base for a `#[path = "..."]` attribute.
    path_attr: PathBuf,
}

fn walk_file(file: &Path, module_path: Vec<String>, is_root: bool, out: &mut Vec<CrateModule>) {
    let source = std::fs::read_to_string(file).unwrap_or_else(|err| {
        panic!(
            "ball-lang-encoder: could not read crate file `{}`: {err}",
            file.display()
        )
    });
    let ast = syn::parse_file(&source).unwrap_or_else(|err| {
        panic!(
            "ball-lang-encoder: failed to parse `{}`: {err}",
            file.display()
        )
    });

    let file_dir = file
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .to_path_buf();
    let is_mod_rs = is_root || file.file_name().is_some_and(|name| name == "mod.rs");
    let out_of_line = if is_mod_rs {
        file_dir.clone()
    } else {
        let stem = file
            .file_stem()
            .unwrap_or_else(|| panic!("ball-lang-encoder: `{}` has no file stem", file.display()));
        file_dir.join(stem)
    };
    let dirs = ModuleDir {
        out_of_line,
        path_attr: file_dir,
    };

    out.push(CrateModule {
        name: module_name(&module_path),
        file: file.to_path_buf(),
        ast: ast.clone(),
    });

    walk_items(&ast.items, &module_path, &dirs, file, out);
}

/// Walk one item list's `mod` declarations. Shared by a file's top level and
/// by an inline `mod` block's body.
fn walk_items(
    items: &[syn::Item],
    module_path: &[String],
    dirs: &ModuleDir,
    file: &Path,
    out: &mut Vec<CrateModule>,
) {
    for item in items {
        let syn::Item::Mod(item_mod) = item else {
            continue;
        };
        if is_cfg_test(&item_mod.attrs) {
            continue;
        }
        let name = item_mod.ident.to_string();
        let mut child_path = module_path.to_vec();
        child_path.push(name.clone());

        if let Some((_, inline_items)) = &item_mod.content {
            // An inline `mod` block: its items live in this same file but are
            // a separate Rust module, so they become a separate Ball module.
            out.push(CrateModule {
                name: module_name(&child_path),
                file: file.to_path_buf(),
                ast: syn::File {
                    shebang: None,
                    attrs: Vec::new(),
                    items: inline_items.clone(),
                },
            });
            // Inside an inline block both bases are the same nested directory.
            let nested = dirs.out_of_line.join(&name);
            let child_dirs = ModuleDir {
                out_of_line: nested.clone(),
                path_attr: nested,
            };
            walk_items(inline_items, &child_path, &child_dirs, file, out);
            continue;
        }

        let child_file = match path_attribute(&item_mod.attrs) {
            Some(rel) => {
                let candidate = dirs.path_attr.join(&rel);
                if !candidate.is_file() {
                    panic!(
                        "ball-lang-encoder: could not find the source file for module `{name}` — \
                         its `#[path = \"{rel}\"]` resolves to `{}`, which does not exist",
                        candidate.display()
                    );
                }
                candidate
            }
            None => {
                let as_file = dirs.out_of_line.join(format!("{name}.rs"));
                let as_dir = dirs.out_of_line.join(&name).join("mod.rs");
                match (as_file.is_file(), as_dir.is_file()) {
                    (true, true) => panic!(
                        "ball-lang-encoder: module `{name}` has both `{}` and `{}` — the Rust \
                         reference forbids declaring a module both ways",
                        as_file.display(),
                        as_dir.display()
                    ),
                    (true, false) => as_file,
                    (false, true) => as_dir,
                    (false, false) => panic!(
                        "ball-lang-encoder: could not find the source file for module `{name}` \
                         declared in `{}` — looked for `{}` and `{}`",
                        file.display(),
                        as_file.display(),
                        as_dir.display()
                    ),
                }
            }
        };
        walk_file(&child_file, child_path, false, out);
    }
}

fn module_name(module_path: &[String]) -> String {
    if module_path.is_empty() {
        ROOT_MODULE.to_string()
    } else {
        module_path.join("::")
    }
}

/// `#[path = "..."]`'s value, if present.
fn path_attribute(attrs: &[syn::Attribute]) -> Option<String> {
    for attr in attrs {
        if !attr.path().is_ident("path") {
            continue;
        }
        if let syn::Meta::NameValue(name_value) = &attr.meta {
            if let syn::Expr::Lit(syn::ExprLit {
                lit: syn::Lit::Str(value),
                ..
            }) = &name_value.value
            {
                return Some(value.value());
            }
        }
        panic!("ball-lang-encoder: unsupported `#[path]` attribute — expected `#[path = \"...\"]`");
    }
    None
}

/// Is this item gated on `cfg(test)`? Scans the predicate's token tree for a
/// bare `test` IDENT, so `#[cfg(all(test, unix))]` counts and
/// `#[cfg(feature = "testing")]` (a string literal, not an ident) does not.
fn is_cfg_test(attrs: &[syn::Attribute]) -> bool {
    attrs.iter().any(|attr| {
        attr.path().is_ident("cfg")
            && match &attr.meta {
                syn::Meta::List(list) => contains_test_ident(list.tokens.clone()),
                _ => false,
            }
    })
}

fn contains_test_ident(tokens: proc_macro2::TokenStream) -> bool {
    tokens.into_iter().any(|tree| match tree {
        proc_macro2::TokenTree::Ident(ident) => ident == "test",
        proc_macro2::TokenTree::Group(group) => contains_test_ident(group.stream()),
        _ => false,
    })
}

fn declares_main(ast: &syn::File) -> bool {
    ast.items
        .iter()
        .any(|item| matches!(item, syn::Item::Fn(item_fn) if item_fn.sig.ident == "main"))
}

// ════════════════════════════════════════════════════════════
// The crate-wide symbol table
// ════════════════════════════════════════════════════════════

fn collect_symbols(modules: &[CrateModule]) -> CrateSymbols {
    let mut symbols = CrateSymbols::default();
    for module in modules {
        symbols.modules.insert(module.name.clone());
        for item in &module.ast.items {
            match item {
                syn::Item::Fn(item_fn) => {
                    let name = item_fn.sig.ident.to_string();
                    symbols
                        .fn_modules
                        .entry(name.clone())
                        .or_default()
                        .insert(module.name.clone());
                    // A signature whose parameters cannot be read is still
                    // RESOLVABLE (the call site just packs positionally) — see
                    // `simple_param_names` for why indexing must not fail loud
                    // where encoding does.
                    if let Some(params) = simple_param_names(&item_fn.sig, false) {
                        symbols.fn_params.entry(name).or_insert(params);
                    }
                }
                syn::Item::Struct(item_struct) => {
                    let name = item_struct.ident.to_string();
                    symbols
                        .type_modules
                        .entry(name.clone())
                        .or_default()
                        .insert(module.name.clone());
                    match item_struct.fields {
                        syn::Fields::Unnamed(_) => {
                            symbols.tuple_struct_names.insert(name);
                        }
                        syn::Fields::Unit => {
                            symbols.unit_struct_names.insert(name);
                        }
                        syn::Fields::Named(_) => {}
                    }
                }
                syn::Item::Enum(item_enum) => {
                    let name = item_enum.ident.to_string();
                    symbols
                        .type_modules
                        .entry(name.clone())
                        .or_default()
                        .insert(module.name.clone());
                    symbols
                        .enum_modules
                        .entry(name)
                        .or_insert_with(|| module.name.clone());
                }
                syn::Item::Trait(item_trait) => {
                    symbols
                        .type_modules
                        .entry(item_trait.ident.to_string())
                        .or_default()
                        .insert(module.name.clone());
                    collect_trait_members(item_trait, &module.name, &mut symbols);
                }
                syn::Item::Impl(item_impl) => {
                    collect_impl_members(item_impl, &module.name, &mut symbols);
                }
                _ => {}
            }
        }
    }
    symbols
}

fn collect_impl_members(item_impl: &syn::ItemImpl, module: &str, symbols: &mut CrateSymbols) {
    let Some(owner) = self_type_short_name(&item_impl.self_ty) else {
        return;
    };
    symbols
        .type_modules
        .entry(owner.clone())
        .or_default()
        .insert(module.to_string());
    for item in &item_impl.items {
        let syn::ImplItem::Fn(method) = item else {
            continue;
        };
        record_member(&method.sig, &owner, module, symbols);
    }
}

fn collect_trait_members(item_trait: &syn::ItemTrait, module: &str, symbols: &mut CrateSymbols) {
    let owner = item_trait.ident.to_string();
    for item in &item_trait.items {
        let syn::TraitItem::Fn(method) = item else {
            continue;
        };
        // A signature-only receiver-less trait fn is still a documented gap
        // (`types.rs`), so only a default-bodied one is registered here —
        // exactly the split PR #589 established.
        if method.default.is_none() && method.sig.receiver().is_none() {
            continue;
        }
        record_member(&method.sig, &owner, module, symbols);
    }
}

fn record_member(sig: &syn::Signature, owner: &str, module: &str, symbols: &mut CrateSymbols) {
    let name = sig.ident.to_string();
    // A `self`-receiver method's parameters start AFTER the receiver — reading
    // them from the wrong offset loses the first real parameter. `types.rs`'s
    // module doc records the same trap for `metadata.params`.
    let receiver = has_self_receiver(sig);
    let params = simple_param_names(sig, receiver);
    if receiver {
        symbols
            .method_modules
            .entry(name.clone())
            .or_default()
            .insert(module.to_string());
        if let Some(params) = params {
            symbols.method_params.entry(name).or_insert(params);
        }
    } else {
        // A receiver-less associated function is deliberately NOT registered in
        // `method_modules`: it is never reached as `value.name(...)`, and its
        // call site resolves through its OWNER's module (`resolve_type`), so
        // listing it here would only invent ambiguities between unrelated
        // types' `new`s.
        if let Some(params) = params {
            symbols
                .static_method_params
                .entry((owner.to_string(), name))
                .or_insert(params);
        }
    }
}

/// Every parameter's name, skipping a leading `self` receiver when
/// `skip_receiver` — or `None` when any parameter is not a simple identifier
/// (a destructuring pattern, a documented encoder gap).
///
/// **Indexing must not fail loud, even though ENCODING must.** The crate walk
/// catalogues the whole crate before any one file is encoded, so reaching for
/// `param_names_and_types`/`method_non_self_params` here — both of which panic
/// on a destructuring parameter, correctly, at their own encode sites — turns
/// ONE unsupported signature into "this entire crate gets no crate-aware
/// measurement". That is exactly what the first real sweep showed:
/// `itertools`' `fn cmp(&self, (c, t): ...)` cost all 60 of its files their
/// crate context. A signature this cannot read simply goes unrecorded, and a
/// call site that needed it falls back to the positional `argN` convention an
/// unknown signature has always used — while the *encode* of the declaring
/// file still fails loud at the real gap, unchanged.
fn simple_param_names(sig: &syn::Signature, skip_receiver: bool) -> Option<Vec<String>> {
    let mut names = Vec::new();
    for arg in sig.inputs.iter().skip(usize::from(skip_receiver)) {
        let syn::FnArg::Typed(pat_type) = arg else {
            return None;
        };
        match pat_type.pat.as_ref() {
            syn::Pat::Ident(syn::PatIdent {
                ident,
                subpat: None,
                ..
            }) => names.push(ident.to_string()),
            _ => return None,
        }
    }
    Some(names)
}

fn self_type_short_name(ty: &syn::Type) -> Option<String> {
    match ty {
        syn::Type::Path(path) => path
            .path
            .segments
            .last()
            .map(|segment| segment.ident.to_string()),
        _ => None,
    }
}

// ════════════════════════════════════════════════════════════
// Resolution, as seen from one module being encoded
// ════════════════════════════════════════════════════════════

/// How a cross-file name resolved.
pub(crate) enum Resolved {
    /// Declared in the module currently being encoded — an unqualified call.
    Here,
    /// Declared in exactly one other module.
    In(String),
    /// Not declared anywhere in the crate.
    Unknown,
}

impl CrateSymbols {
    /// Which module declares the free function `name`?
    pub(crate) fn resolve_fn(&self, name: &str, current_module: &str) -> Resolved {
        Self::resolve(&self.fn_modules, name, current_module, "function")
    }

    /// Which module declares the instance method `name`?
    pub(crate) fn resolve_method(&self, name: &str, current_module: &str) -> Resolved {
        Self::resolve(&self.method_modules, name, current_module, "method")
    }

    /// Which module declares the type `name`?
    pub(crate) fn resolve_type(&self, name: &str, current_module: &str) -> Resolved {
        Self::resolve(&self.type_modules, name, current_module, "type")
    }

    fn resolve(
        table: &BTreeMap<String, BTreeSet<String>>,
        name: &str,
        current_module: &str,
        kind: &str,
    ) -> Resolved {
        match Self::owner_of(table, name, current_module) {
            None => Resolved::Unknown,
            Some(Ok(None)) => Resolved::Here,
            Some(Ok(Some(module))) => Resolved::In(module.to_string()),
            Some(Err(owners)) => panic!(
                "ball-lang-encoder: the {kind} `{name}` is declared in more than one module of \
                 this crate ({}) and is used from `{current_module}`, which declares none of \
                 them — a syntax-only encoder cannot tell which one is meant, and picking one \
                 would silently dispatch to the wrong body",
                owners.iter().cloned().collect::<Vec<_>>().join(", ")
            ),
        }
    }
}
