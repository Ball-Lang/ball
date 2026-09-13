//! The macro table: collecting `macro_rules!` definitions, resolving an
//! invocation to one, and expanding it.
//!
//! ## Resolution order
//!
//! Given a `syn::Macro { path, tokens }`:
//!
//! 1. **2+ path segments** (`mini_bitflags::flags!`, `bitflags::bitflags!`) →
//!    the crate named by the first segment, requiring an `#[macro_export]`ed
//!    definition. `crate`/`self` name this crate.
//! 2. **A single segment in the builtin/std family** → not this crate's
//!    business at all; [`crate::is_builtin_macro`] says so and the encoder
//!    lowers it semantically.
//! 3. **A single segment recorded as an alias** (`use defmt::{write as
//!    dewrite};`) → the aliased definition.
//! 4. **A single segment defined in this crate** → that definition. The Rust
//!    Reference's textual scope ("the macro enters the scope after the
//!    definition … up until its surrounding scope … is closed") is
//!    approximated by a crate-wide lookup; what keeps the approximation honest
//!    is that two definitions of the same name with *differing rules* are a
//!    loud [`MacroError::Ambiguous`], not a silent first-wins.
//! 5. Otherwise → a loud [`MacroError::Unresolved`] naming what WAS in scope.
//!
//! ## Every engine call sits behind `catch_unwind`
//!
//! `ra_ap_*` are rust-analyzer's internal crates, published for reuse but
//! written to `unwrap()` (its own `syntax-bridge` panics on a doc comment). A
//! bare panic escaping into the Tier A coverage harness would be scored as a
//! Ball encode error with an inscrutable message, so both entry points wrap the
//! engine and re-raise as [`MacroError::EnginePanic`].

use std::collections::{BTreeMap, BTreeSet};
use std::panic::AssertUnwindSafe;

use ra_ap_mbe::{DeclarativeMacro, MacroCallStyle};
use ra_ap_span::Edition;

use crate::bridge::{self, CALL_FILE, DEF_FILE};
use crate::{MacroError, hygiene, is_builtin_macro};

/// Where a `macro_rules!` definition came from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MacroOrigin {
    /// Defined in the crate being encoded, in the named Ball module.
    LocalCrate { module: String },
    /// Defined in a dependency crate, and reached by a path or a `use`.
    Dependency { krate: String },
}

impl MacroOrigin {
    fn describe(&self) -> String {
        match self {
            MacroOrigin::LocalCrate { module } => format!("module `{module}` of this crate"),
            MacroOrigin::Dependency { krate } => format!("the dependency crate `{krate}`"),
        }
    }

    /// What `$crate` resolves to for a macro defined here.
    fn dollar_crate(&self) -> &str {
        match self {
            MacroOrigin::LocalCrate { .. } => "crate",
            MacroOrigin::Dependency { krate } => krate,
        }
    }
}

/// One parsed `macro_rules!` definition.
pub struct MacroDef {
    /// The macro's name.
    pub name: String,
    /// Whether it carries `#[macro_export]` — the only definitions a *path*
    /// may reach. The Rust Reference: "The `macro_export` attribute exports the
    /// macro from the crate and makes it available in the root of the crate for
    /// path-based resolution"; "By default, macros only have textual scope and
    /// cannot be resolved by path."
    pub exported: bool,
    /// Where it was defined.
    pub origin: MacroOrigin,
    /// The rule tokens, verbatim, used only to tell two same-named definitions
    /// apart (identical rules are not an ambiguity).
    rules_text: String,
    rules: DeclarativeMacro,
}

impl std::fmt::Debug for MacroDef {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MacroDef")
            .field("name", &self.name)
            .field("exported", &self.exported)
            .field("origin", &self.origin)
            .finish_non_exhaustive()
    }
}

/// The position an expansion is being spliced into, which decides how its
/// tokens are re-parsed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Expansion {
    /// Item position — the expansion is a list of items.
    Items,
    /// Expression position — the expansion is one expression.
    Expr,
    /// Statement position — the expansion is a list of statements.
    Stmts,
    /// Inside an `impl` block — the expansion is a list of impl items. This is
    /// how `bitflags`' internal `__impl_public_bitflags*!` family is shaped.
    ImplItems,
    /// Inside a `trait` block — the expansion is a list of trait items.
    TraitItems,
}

impl Expansion {
    fn describe(self) -> &'static str {
        match self {
            Expansion::Items => "a list of items",
            Expansion::Expr => "an expression",
            Expansion::Stmts => "a list of statements",
            Expansion::ImplItems => "a list of `impl` items",
            Expansion::TraitItems => "a list of `trait` items",
        }
    }
}

/// What the driver should do with one invocation — see [`MacroTable::route`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Route {
    /// A compiler builtin or std-prelude macro. Not this crate's business:
    /// the encoder lowers it semantically.
    Builtin,
    /// A `macro_rules!` this table can expand.
    Expand,
    /// No `macro_rules!` in scope has this name — a proc-macro, a `#[derive]`
    /// helper, an attribute macro, or a typo. The encoder's own loud refusal
    /// is the better diagnostic here, so the driver leaves the invocation in
    /// place for it.
    Unknown,
    /// The name IS known to belong to something this table should have been
    /// able to reach, and could not. Always loud, always named.
    Failed(MacroError),
}

/// A successfully expanded, hygiene-resolved macro invocation.
#[derive(Debug, Clone)]
pub enum Expanded {
    Items(Vec<syn::Item>),
    Expr(syn::Expr),
    Stmts(Vec<syn::Stmt>),
    ImplItems(Vec<syn::ImplItem>),
    TraitItems(Vec<syn::TraitItem>),
}

/// Every `macro_rules!` definition in scope for one crate, plus the salsa
/// database the engine expands against.
///
/// One `salsa::DatabaseImpl` is created per table and reused for every
/// expansion — exactly what rust-analyzer's own `crates/mbe` tests and
/// benchmarks do.
pub struct MacroTable {
    db: salsa::DatabaseImpl,
    defs: BTreeMap<String, Vec<MacroDef>>,
    /// `use <dep>::{<name> as <alias>};` — alias → the name to look up.
    aliases: BTreeMap<String, String>,
    /// Set when the dependency graph could not be read at all. A dependency
    /// macro is then a loud [`MacroError::DependenciesUnavailable`] naming this
    /// reason — never a silent skip.
    dependencies_unavailable: Option<String>,
}

impl Default for MacroTable {
    fn default() -> Self {
        Self::new()
    }
}

impl std::fmt::Debug for MacroTable {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MacroTable")
            .field("defs", &self.defs)
            .field("aliases", &self.aliases)
            .field("dependencies_unavailable", &self.dependencies_unavailable)
            .finish()
    }
}

impl MacroTable {
    pub fn new() -> MacroTable {
        MacroTable {
            db: salsa::DatabaseImpl::default(),
            defs: BTreeMap::new(),
            aliases: BTreeMap::new(),
            dependencies_unavailable: None,
        }
    }

    /// Record a `macro_rules! <name> { … }` item.
    ///
    /// A `syn::Item::Macro` whose `ident` is `None` is an *invocation*, not a
    /// definition, and is rejected rather than quietly ignored.
    pub fn insert_macro_rules(
        &mut self,
        item: &syn::ItemMacro,
        origin: MacroOrigin,
    ) -> Result<(), MacroError> {
        let Some(ident) = &item.ident else {
            return Err(MacroError::DefinitionNotParseable {
                name: path_text(&item.mac.path),
                origin: origin.describe(),
                reason: "this is a macro INVOCATION, not a `macro_rules!` definition".to_owned(),
            });
        };
        let name = ident.to_string();
        let rules_text = item.mac.tokens.to_string();
        if let Some(existing) = self.defs.get(&name) {
            if existing.iter().any(|def| def.rules_text == rules_text) {
                // The identical macro, defined again (heck defines `t!` once
                // per test module). Not an ambiguity — nothing to choose.
                return Ok(());
            }
        }
        let exported = item
            .attrs
            .iter()
            .any(|attr| attr.path().is_ident("macro_export"));
        let tokens = item.mac.tokens.clone();
        let rules = guarded(&name, || {
            let subtree = bridge::to_subtree(tokens, bridge::span(DEF_FILE));
            DeclarativeMacro::parse_macro_rules(&subtree, |_| Edition::CURRENT)
        })?;
        if let Some(err) = rules.err() {
            return Err(MacroError::DefinitionNotParseable {
                name,
                origin: origin.describe(),
                reason: format!("{err:?}"),
            });
        }
        self.defs.entry(name.clone()).or_default().push(MacroDef {
            name,
            exported,
            origin,
            rules_text,
            rules,
        });
        Ok(())
    }

    /// Record `use <krate>::{<name> as <alias>};`. The corpus's one real
    /// instance is `use defmt::{write as dewrite};` in `smallvec`.
    pub fn insert_alias(&mut self, alias: String, target: String) {
        self.aliases.insert(alias, target);
    }

    /// Record that the dependency graph could not be read, and why.
    pub fn set_dependencies_unavailable(&mut self, reason: String) {
        self.dependencies_unavailable = Some(reason);
    }

    /// Every macro name this table can resolve, sorted.
    pub fn names(&self) -> Vec<String> {
        self.defs
            .keys()
            .cloned()
            .chain(self.aliases.keys().cloned())
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect()
    }

    /// What should the driver DO with this invocation?
    ///
    /// The three answers are deliberately different, because they carry
    /// different diagnostics — collapsing them into one boolean is what threw
    /// away the "this crate's dependencies were never read" message and
    /// replaced it with a generic "unsupported item".
    pub fn route(&self, mac: &syn::Macro) -> Route {
        if is_builtin_macro(&path_text(&mac.path)) {
            return Route::Builtin;
        }
        match self.lookup(mac) {
            Ok(_) => Route::Expand,
            // Nothing in scope has this name at all. That is the proc-macro /
            // `#[derive]` / attribute-macro boundary, which the encoder's own
            // loud refusals already describe better than this crate can.
            Err(MacroError::Unresolved { .. }) => Route::Unknown,
            // Anything else — a dependency graph that could not be read, two
            // definitions that cannot be told apart, a definition the engine
            // could not parse — is a specific, named failure and must not be
            // flattened into "unsupported".
            Err(err) => Route::Failed(err),
        }
    }

    fn lookup(&self, mac: &syn::Macro) -> Result<&MacroDef, MacroError> {
        let path = path_text(&mac.path);
        let segments: Vec<String> = mac
            .path
            .segments
            .iter()
            .map(|s| s.ident.to_string())
            .collect();

        if segments.len() > 1 {
            let krate = &segments[0];
            let name = segments
                .last()
                .expect("a path always has a last segment")
                .clone();
            let local = matches!(krate.as_str(), "crate" | "self");
            if !local {
                if let Some(reason) = &self.dependencies_unavailable {
                    return Err(MacroError::DependenciesUnavailable {
                        name: path.clone(),
                        krate: krate.clone(),
                        reason: reason.clone(),
                    });
                }
            }
            let candidates = self.defs.get(&name).map(Vec::as_slice).unwrap_or(&[]);
            let hit = candidates.iter().find(|def| {
                def.exported
                    && match (&def.origin, local) {
                        (MacroOrigin::Dependency { krate: k }, false) => k == krate,
                        (MacroOrigin::LocalCrate { .. }, true) => true,
                        _ => false,
                    }
            });
            return match hit {
                Some(def) => Ok(def),
                None if !local && candidates.is_empty() => {
                    Err(MacroError::DependenciesUnavailable {
                        name: path,
                        krate: krate.clone(),
                        reason: "no `#[macro_export] macro_rules!` with that name was found in \
                                 that crate's library target"
                            .to_owned(),
                    })
                }
                None => Err(MacroError::Unresolved {
                    name: path,
                    in_scope: self.names(),
                }),
            };
        }

        let name = self
            .aliases
            .get(&path)
            .cloned()
            .unwrap_or_else(|| path.clone());
        let candidates = self.defs.get(&name).map(Vec::as_slice).unwrap_or(&[]);
        match candidates {
            [] => Err(MacroError::Unresolved {
                name: path,
                in_scope: self.names(),
            }),
            [only] => Ok(only),
            many => Err(MacroError::Ambiguous {
                name: path,
                modules: many.iter().map(|def| def.origin.describe()).collect(),
            }),
        }
    }

    /// Expand one invocation, resolve hygiene over the result, and parse it in
    /// the position it was invoked.
    pub fn expand(&self, mac: &syn::Macro, want: Expansion) -> Result<Expanded, MacroError> {
        let def = self.lookup(mac)?;
        let name = def.name.clone();
        let arg_tokens = mac.tokens.clone();
        let subtree = guarded(&name, || {
            let arg = bridge::to_subtree(arg_tokens, bridge::span(CALL_FILE));
            def.rules.expand(
                &self.db,
                &arg,
                |_| (),
                MacroCallStyle::FnLike,
                bridge::span(CALL_FILE),
            )
        })?;
        if let Some(err) = &subtree.err {
            return Err(MacroError::NoExpansion {
                name,
                origin: def.origin.describe(),
                reason: format!("{err:?}"),
                arguments: mac.tokens.to_string(),
            });
        }
        let (expansion, _arm) = subtree.value;
        let dollar_crate = def.origin.dollar_crate().to_owned();
        let tokens = bridge::from_subtree(&expansion, &mut |text, is_raw, origin| {
            hygiene::mark(text, is_raw, origin, &dollar_crate)
        })?;

        let not_parseable = |err: syn::Error| MacroError::NotParseable {
            name: name.clone(),
            position: want.describe(),
            tokens: tokens.to_string(),
            reason: err.to_string(),
        };

        match want {
            Expansion::Items => {
                let mut file = syn::parse2::<syn::File>(tokens.clone()).map_err(not_parseable)?;
                hygiene::resolve(&mut file, |v, node| syn::visit_mut::visit_file_mut(v, node));
                Ok(Expanded::Items(file.items))
            }
            Expansion::Expr => {
                let mut expr = syn::parse2::<syn::Expr>(tokens.clone()).map_err(not_parseable)?;
                hygiene::resolve(&mut expr, |v, node| syn::visit_mut::visit_expr_mut(v, node));
                Ok(Expanded::Expr(expr))
            }
            Expansion::Stmts => {
                let mut block = syn::parse2::<BlockBody>(tokens.clone())
                    .map_err(not_parseable)?
                    .0;
                hygiene::resolve(&mut block, |v, node| {
                    for stmt in node.iter_mut() {
                        syn::visit_mut::visit_stmt_mut(v, stmt);
                    }
                });
                Ok(Expanded::Stmts(block))
            }
            Expansion::ImplItems => {
                let mut items = syn::parse2::<ItemList<syn::ImplItem>>(tokens.clone())
                    .map_err(not_parseable)?
                    .0;
                hygiene::resolve(&mut items, |v, node| {
                    for item in node.iter_mut() {
                        syn::visit_mut::visit_impl_item_mut(v, item);
                    }
                });
                Ok(Expanded::ImplItems(items))
            }
            Expansion::TraitItems => {
                let mut items = syn::parse2::<ItemList<syn::TraitItem>>(tokens.clone())
                    .map_err(not_parseable)?
                    .0;
                hygiene::resolve(&mut items, |v, node| {
                    for item in node.iter_mut() {
                        syn::visit_mut::visit_trait_item_mut(v, item);
                    }
                });
                Ok(Expanded::TraitItems(items))
            }
        }
    }
}

/// A bare statement list, so `syn::parse2` can be pointed at one without the
/// braces a `syn::Block` requires.
struct BlockBody(Vec<syn::Stmt>);

impl syn::parse::Parse for BlockBody {
    fn parse(input: syn::parse::ParseStream<'_>) -> syn::Result<Self> {
        input.call(syn::Block::parse_within).map(BlockBody)
    }
}

/// A bare list of `impl`/`trait` items, for the same reason.
struct ItemList<T>(Vec<T>);

impl<T: syn::parse::Parse> syn::parse::Parse for ItemList<T> {
    fn parse(input: syn::parse::ParseStream<'_>) -> syn::Result<Self> {
        let mut items = Vec::new();
        while !input.is_empty() {
            items.push(input.parse()?);
        }
        Ok(ItemList(items))
    }
}

/// Run one engine call with panics converted into a named error.
fn guarded<T>(name: &str, f: impl FnOnce() -> T) -> Result<T, MacroError> {
    std::panic::catch_unwind(AssertUnwindSafe(f)).map_err(|payload| MacroError::EnginePanic {
        name: name.to_owned(),
        payload: panic_message(&payload),
    })
}

fn panic_message(payload: &Box<dyn std::any::Any + Send>) -> String {
    if let Some(s) = payload.downcast_ref::<&str>() {
        (*s).to_owned()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "<non-string panic payload>".to_owned()
    }
}

/// A macro path as written, `::`-joined.
pub fn path_text(path: &syn::Path) -> String {
    path.segments
        .iter()
        .map(|s| s.ident.to_string())
        .collect::<Vec<_>>()
        .join("::")
}
