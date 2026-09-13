//! The macro-expansion pre-pass (issue #629).
//!
//! `ball-lang-macro-expand` knows how to expand ONE invocation. This module is
//! the driver: it collects the definitions in scope, walks a module's parsed
//! items replacing invocations with their expansions, and iterates to a fixed
//! point.
//!
//! ## Why it is a PRE-pass
//!
//! It runs before the encoder's own pre-pass (`fn_params`/`enum_names`/
//! `method_params` collection) and before `crate_graph::collect_symbols`,
//! because an expansion can introduce a struct, an impl or a free function that
//! those passes must see. `bitflags!` producing the `TestFlags` that the rest of
//! a file calls into is exactly that shape, and it is why an item-level macro
//! can never simply be skipped.
//!
//! ## The fixed point is required, not an optimisation
//!
//! A self-referential macro comes back from the engine with its own invocation
//! still in place — measured, and pinned by `ball-lang-macro-expand`'s
//! `a_self_recursive_macro_is_not_fully_expanded_in_one_pass`. The real corpus
//! has one that recurses twelve deep (`itertools`' `impl_cons_iter!`). So the
//! driver repeats until a pass replaces nothing.
//!
//! The depth limit is **128**, matching rustc: the Rust Reference, *Limits* —
//! "The `recursion_limit` attribute may be applied at the crate level to set the
//! maximum depth for potentially infinitely-recursive compile-time operations
//! like macro expansion"; "The default in `rustc` is 128." Exceeding it is a
//! loud error naming the chain, never a partial expansion.
//!
//! ## What is NOT expanded
//!
//! - The builtin/std macro family (`println!`, `vec!`, `assert!`, `write!`, …).
//!   Their real bodies bottom out in compiler builtins with no `macro_rules!`
//!   definition anywhere, so `methods.rs::encode_macro` lowers them
//!   semantically instead. A builtin that `encode_macro` does not model keeps
//!   its **existing** panic, which is what keeps issue #630 separately
//!   trackable.
//! - A macro nothing in scope defines — including every proc-macro,
//!   `#[derive]` and attribute macro, which are out of scope by design. Those
//!   reach the encoder's existing loud refusals unchanged.
//!
//! Neither is a silent skip: the first is a different, deliberate code path, and
//! the second still fails loud at the use site. A macro the table SHOULD have
//! been able to reach and could not — an unreadable dependency graph, an
//! ambiguity, an unparseable definition — is a named [`MacroError`], never
//! flattened into "unsupported".

use ball_lang_macro_expand::{Expanded, Expansion, MacroError, MacroOrigin, MacroTable, Route};
use syn::visit_mut::VisitMut;

/// rustc's own default `recursion_limit`.
pub(crate) const MAX_MACRO_DEPTH: usize = 128;

/// Turn a [`MacroError`] into the loud panic every other unsupported shape in
/// this crate already produces.
pub(crate) fn fail(err: MacroError) -> ! {
    panic!("ball-lang-encoder: {err}");
}

// ════════════════════════════════════════════════════════════
// Collecting definitions
// ════════════════════════════════════════════════════════════

/// Record every `macro_rules!` declared in `items` — including inside inline
/// `mod` blocks, which is where 21 of `bitflags`' definitions live — plus every
/// `use <krate>::{<name> as <alias>};` rename, which is how an aliased
/// dependency macro (`use defmt::{write as dewrite};`) is reached.
///
/// **TEST-ONLY inline `mod` blocks are skipped**, exactly as
/// `crate_graph::walk_items` skips them for module resolution: `cargo build`
/// does not compile them, so a definition in one is not in scope for anything
/// this encoder encodes. Collecting them anyway is not merely redundant, it is
/// actively wrong — `heck` declares `macro_rules! t` once inside each of its
/// eight `#[cfg(test)] mod tests` blocks with different bodies, which made
/// every `t!` in the crate a loud ambiguity between eight definitions none of
/// which an ordinary build has.
pub(crate) fn collect_definitions(
    items: &[syn::Item],
    module: &str,
    table: &mut MacroTable,
) -> Result<(), MacroError> {
    for item in items {
        match item {
            syn::Item::Macro(item_macro) if item_macro.ident.is_some() => {
                table.insert_macro_rules(
                    item_macro,
                    MacroOrigin::LocalCrate {
                        module: module.to_owned(),
                    },
                )?;
            }
            syn::Item::Mod(item_mod) if !crate::crate_graph::is_cfg_test(&item_mod.attrs) => {
                if let Some((_, inner)) = &item_mod.content {
                    let nested = format!("{module}::{}", item_mod.ident);
                    collect_definitions(inner, &nested, table)?;
                }
            }
            syn::Item::Use(item_use) => collect_use_aliases(&item_use.tree, table),
            _ => {}
        }
    }
    Ok(())
}

fn collect_use_aliases(tree: &syn::UseTree, table: &mut MacroTable) {
    match tree {
        syn::UseTree::Path(path) => collect_use_aliases(&path.tree, table),
        syn::UseTree::Group(group) => {
            for item in &group.items {
                collect_use_aliases(item, table);
            }
        }
        syn::UseTree::Rename(rename) => {
            table.insert_alias(rename.rename.to_string(), rename.ident.to_string());
        }
        syn::UseTree::Name(_) | syn::UseTree::Glob(_) => {}
    }
}

// ════════════════════════════════════════════════════════════
// The fixed-point driver
// ════════════════════════════════════════════════════════════

/// Expand every resolvable `macro_rules!` invocation in `file`, to a fixed
/// point, and remove the `macro_rules!` definitions themselves (they declare
/// nothing Ball models).
pub(crate) fn expand_file(file: &mut syn::File, table: &MacroTable) -> Result<(), MacroError> {
    let mut depth = 0usize;
    loop {
        let mut pass = Pass {
            table,
            replaced: 0,
            error: None,
            chain: Vec::new(),
        };
        pass.visit_file_mut(file);
        if let Some(err) = pass.error {
            return Err(err);
        }
        if pass.replaced == 0 {
            return Ok(());
        }
        depth += 1;
        if depth > MAX_MACRO_DEPTH {
            return Err(MacroError::DepthLimit {
                chain: pass.chain,
                limit: MAX_MACRO_DEPTH,
            });
        }
    }
}

/// One expansion pass. `replaced` drives the fixed point; `chain` is what the
/// depth-limit error reports.
struct Pass<'a> {
    table: &'a MacroTable,
    replaced: usize,
    error: Option<MacroError>,
    chain: Vec<String>,
}

impl Pass<'_> {
    /// The first error wins — reporting the last one would name a macro that
    /// only failed because an earlier expansion went wrong.
    fn record(&mut self, err: MacroError) {
        if self.error.is_none() {
            self.error = Some(err);
        }
    }

    fn note(&mut self, mac: &syn::Macro) {
        let name = ball_lang_macro_expand::path_text(&mac.path);
        if !self.chain.contains(&name) {
            self.chain.push(name);
        }
    }

    /// Should this invocation be expanded here?
    ///
    /// A named failure (a dependency graph that could not be read, an
    /// ambiguity, an unparseable definition) is recorded as a loud error. A
    /// builtin, or a name nothing in scope defines, is left exactly where it is
    /// — `methods.rs::encode_macro` and `lib.rs`'s unsupported-item panic are
    /// the better diagnostics for those two, and keeping them is what keeps
    /// issue #630 and the proc-macro boundary separately trackable.
    fn wants_expansion(&mut self, mac: &syn::Macro) -> bool {
        match self.table.route(mac) {
            Route::Expand => true,
            Route::Builtin | Route::Unknown => false,
            Route::Failed(err) => {
                self.record(err);
                false
            }
        }
    }

    /// Replace item-position invocations in place, and drop definitions.
    fn splice_items(&mut self, items: &mut Vec<syn::Item>) {
        let mut out = Vec::with_capacity(items.len());
        for item in std::mem::take(items) {
            match item {
                // A `macro_rules!` DEFINITION. It declares nothing Ball models
                // and it has already been collected into the table, so it is
                // removed rather than left to hit the encoder's
                // unsupported-item panic.
                syn::Item::Macro(ref item_macro) if item_macro.ident.is_some() => {}
                syn::Item::Macro(item_macro) if self.wants_expansion(&item_macro.mac) => {
                    self.note(&item_macro.mac);
                    match self.table.expand(&item_macro.mac, Expansion::Items) {
                        Ok(Expanded::Items(produced)) => {
                            self.replaced += 1;
                            out.extend(produced);
                        }
                        Ok(other) => unreachable_expansion("items", &other),
                        Err(err) => {
                            self.record(err);
                            out.push(syn::Item::Macro(item_macro));
                        }
                    }
                }
                other => out.push(other),
            }
        }
        *items = out;
    }

    fn splice_impl_items(&mut self, items: &mut Vec<syn::ImplItem>) {
        let mut out = Vec::with_capacity(items.len());
        for item in std::mem::take(items) {
            match item {
                syn::ImplItem::Macro(impl_macro) if self.wants_expansion(&impl_macro.mac) => {
                    self.note(&impl_macro.mac);
                    match self.table.expand(&impl_macro.mac, Expansion::ImplItems) {
                        Ok(Expanded::ImplItems(produced)) => {
                            self.replaced += 1;
                            out.extend(produced);
                        }
                        Ok(other) => unreachable_expansion("impl items", &other),
                        Err(err) => {
                            self.record(err);
                            out.push(syn::ImplItem::Macro(impl_macro));
                        }
                    }
                }
                other => out.push(other),
            }
        }
        *items = out;
    }

    fn splice_trait_items(&mut self, items: &mut Vec<syn::TraitItem>) {
        let mut out = Vec::with_capacity(items.len());
        for item in std::mem::take(items) {
            match item {
                syn::TraitItem::Macro(trait_macro) if self.wants_expansion(&trait_macro.mac) => {
                    self.note(&trait_macro.mac);
                    match self.table.expand(&trait_macro.mac, Expansion::TraitItems) {
                        Ok(Expanded::TraitItems(produced)) => {
                            self.replaced += 1;
                            out.extend(produced);
                        }
                        Ok(other) => unreachable_expansion("trait items", &other),
                        Err(err) => {
                            self.record(err);
                            out.push(syn::TraitItem::Macro(trait_macro));
                        }
                    }
                }
                other => out.push(other),
            }
        }
        *items = out;
    }

    fn splice_stmts(&mut self, stmts: &mut Vec<syn::Stmt>) {
        let mut out = Vec::with_capacity(stmts.len());
        for stmt in std::mem::take(stmts) {
            match stmt {
                syn::Stmt::Macro(stmt_macro) if self.wants_expansion(&stmt_macro.mac) => {
                    self.note(&stmt_macro.mac);
                    match self.table.expand(&stmt_macro.mac, Expansion::Stmts) {
                        Ok(Expanded::Stmts(produced)) => {
                            self.replaced += 1;
                            out.extend(produced);
                        }
                        Ok(other) => unreachable_expansion("statements", &other),
                        Err(err) => {
                            self.record(err);
                            out.push(syn::Stmt::Macro(stmt_macro));
                        }
                    }
                }
                other => out.push(other),
            }
        }
        *stmts = out;
    }
}

/// `MacroTable::expand` returns the shape it was ASKED for, so a mismatch is a
/// contract violation inside this repo, not a user-source problem — and it is
/// still loud rather than silently dropped.
fn unreachable_expansion(wanted: &str, got: &Expanded) -> ! {
    panic!(
        "ball-lang-encoder: internal error — asked ball-lang-macro-expand for {wanted} and got \
         {got:?}"
    );
}

impl VisitMut for Pass<'_> {
    fn visit_file_mut(&mut self, node: &mut syn::File) {
        self.splice_items(&mut node.items);
        for item in &mut node.items {
            self.visit_item_mut(item);
        }
    }

    fn visit_item_mod_mut(&mut self, node: &mut syn::ItemMod) {
        let Some((_, items)) = &mut node.content else {
            return;
        };
        self.splice_items(items);
        for item in items.iter_mut() {
            self.visit_item_mut(item);
        }
    }

    fn visit_item_impl_mut(&mut self, node: &mut syn::ItemImpl) {
        self.splice_impl_items(&mut node.items);
        for item in node.items.iter_mut() {
            self.visit_impl_item_mut(item);
        }
    }

    fn visit_item_trait_mut(&mut self, node: &mut syn::ItemTrait) {
        self.splice_trait_items(&mut node.items);
        for item in node.items.iter_mut() {
            self.visit_trait_item_mut(item);
        }
    }

    fn visit_block_mut(&mut self, node: &mut syn::Block) {
        syn::visit_mut::visit_block_mut(self, node);
        self.splice_stmts(&mut node.stmts);
    }

    fn visit_expr_mut(&mut self, node: &mut syn::Expr) {
        syn::visit_mut::visit_expr_mut(self, node);
        let syn::Expr::Macro(expr_macro) = node else {
            return;
        };
        if !self.wants_expansion(&expr_macro.mac) {
            return;
        }
        self.note(&expr_macro.mac);
        match self.table.expand(&expr_macro.mac, Expansion::Expr) {
            Ok(Expanded::Expr(expr)) => {
                self.replaced += 1;
                *node = expr;
            }
            Ok(other) => unreachable_expansion("an expression", &other),
            Err(err) => self.record(err),
        }
    }
}
