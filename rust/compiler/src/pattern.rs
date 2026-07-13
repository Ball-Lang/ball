//! Dart-3 **structured pattern matching** for `switch`/`switch_expr` cases —
//! ported from `ts/compiler/src/compiler.ts`'s `compileStructuredPattern` (the
//! reference leg that scores 320/320 on the conformance corpus), with the
//! reference `dart/engine/lib/engine_std.dart`'s `_matchStructuredPattern` as
//! the semantic bar.
//!
//! A pattern compiles to two things, never to a runtime value:
//! - a **boolean Rust condition** over a *subject accessor* — an expression
//!   *string* (`__switch_subject.clone()`), not a value — and
//! - a flat, ordered list of **bindings**: `(binder name, accessor expression)`
//!   pairs the arm re-materializes as `let` locals.
//!
//! Sub-patterns get *derived accessors* (`ball_index_get(S, 0)`,
//! `ball_map_get(S, k)`, `ball_field_get(S, "f")`), never evaluated values —
//! which is what lets one recursive pass produce one flat condition and one flat
//! binding list, with no accessor ever evaluated before the conjunct guarding it
//! passed (Rust's `&&` short-circuits left-to-right, and the binding `let`s live
//! inside the already-matched block).
//!
//! **Fail loud (issue #55).** An unrecognized pattern kind is a *compile-time
//! panic* naming the kind — never a placeholder condition. The previous
//! implementation recognized only `ConstPattern` and silently *dropped* every
//! other case, so 19 pattern fixtures compiled, ran, exited 0 and printed their
//! default arm's answer: the worst outcome there is.
use indexmap::IndexMap;

use ball_lang_shared::proto::ball::v1::Expression;
use ball_lang_shared::proto::ball::v1::expression::Expr;

use crate::base_call::literal_list_elements;
use crate::{Compiler, sanitize_ident};

/// A compiled pattern: the Rust `bool` expression deciding the match, plus the
/// binders it introduces as `(Ball name, accessor expression)` pairs — see the
/// module doc comment.
pub(crate) struct PatternMatch {
    pub(crate) condition: String,
    pub(crate) bindings: Vec<(String, String)>,
}

impl PatternMatch {
    /// Matches anything, binds nothing (`_`, an absent sub-pattern).
    fn always() -> Self {
        PatternMatch {
            condition: "true".to_string(),
            bindings: Vec::new(),
        }
    }

    /// Is this an **unconditional catch-all** — the shape a switch's default arm
    /// is promoted from (a bare `_`, a switch *expression*'s `_ =>` arm, which
    /// carries no `is_default`)? A pattern that *binds* (`case var x:`) is not
    /// one: its binder still has to be materialized.
    pub(crate) fn is_catch_all(&self) -> bool {
        self.condition == "true" && self.bindings.is_empty()
    }
}

impl Compiler<'_> {
    /// Compile one `pattern_expr` against `subject` (an accessor *expression* —
    /// see the module doc comment). Panics at compile time on an unrecognized
    /// pattern kind.
    pub(crate) fn compile_pattern(&self, pattern: &Expression, subject: &str) -> PatternMatch {
        let Some(Expr::MessageCreation(mc)) = &pattern.expr else {
            panic!(
                "ball-lang-compiler: a switch case's `pattern_expr` is not a MessageCreation — \
                 cannot compile its match condition"
            );
        };
        let f = self.message_creation_fields(mc);
        // The kind is the MessageCreation's `typeName`; an engine-normalized IR
        // may instead carry it in a `__pattern_kind__` field (the reference TS
        // compiler's `patternExprKind` accepts both).
        let kind = if mc.type_name.is_empty() {
            self.string_field(&f, "__pattern_kind__")
                .unwrap_or_default()
        } else {
            mc.type_name.clone()
        };

        match kind.as_str() {
            // `42`, `'x'`, `null`, `MyEnum.a` — **Ball** equality (`ball_equals`),
            // never Rust reference identity.
            "ConstPattern" => match f.get("value") {
                Some(value) => PatternMatch {
                    condition: is_true(&format!(
                        "ball_equals({subject}, {})",
                        self.compile_expression(value)
                    )),
                    bindings: Vec::new(),
                },
                None => PatternMatch::always(),
            },

            // `var x`, `int x`, `int? x` — a **typed** binder type-tests; an
            // untyped one matches anything.
            "VarPattern" => PatternMatch {
                condition: self.pattern_type_condition(&f, subject),
                bindings: binding_of(&self.string_field(&f, "name").unwrap_or_default(), subject),
            },

            // `_`, `int _` — binds nothing, but a **typed** wildcard still
            // type-tests. Returning a bare `true` here is the single
            // highest-value bug in this file: the arm's condition becomes `true`,
            // the caller promotes it to the default arm, case parsing stops, and
            // the whole switch collapses onto one arm — 183_type_patterns printed
            // `int/int/int/int` where the golden is `int/string/bool/other`. It
            // shares `pattern_type_condition` with `VarPattern`/`ObjectPattern`/
            // `CastPattern` precisely so a typed binder and a typed wildcard can
            // never diverge (the TS and C++ compilers carry the same fix).
            "WildcardPattern" => PatternMatch {
                condition: self.pattern_type_condition(&f, subject),
                bindings: Vec::new(),
            },

            // `> 5`, `== 3`, `!= x`. An ordering comparison against a
            // **non-numeric** subject must *fail to match* — not throw, not
            // coerce — hence the `num` gates (the reference engine's
            // `_matchRelationalPattern` guards `value is num && operand is num`
            // the same way; without them `ball_greater_than` panics on a String).
            "RelationalPattern" => {
                let operator = self.string_field(&f, "operator").unwrap_or_default();
                let Some(operand) = f.get("operand") else {
                    return PatternMatch::always();
                };
                let operand = self.compile_expression(operand);
                let condition = match operator.as_str() {
                    "" => return PatternMatch::always(),
                    "==" => is_true(&format!("ball_equals({subject}, {operand})")),
                    "!=" => is_true(&format!("ball_not_equals({subject}, {operand})")),
                    ">" | "<" | ">=" | "<=" => {
                        let helper = match operator.as_str() {
                            ">" => "ball_greater_than",
                            "<" => "ball_less_than",
                            ">=" => "ball_gte",
                            _ => "ball_lte",
                        };
                        all_of(vec![
                            type_check(subject, "num"),
                            type_check(&operand, "num"),
                            is_true(&format!("{helper}({subject}, {operand})")),
                        ])
                    }
                    other => panic!(
                        "ball-lang-compiler: unsupported relational pattern operator '{other}'"
                    ),
                };
                PatternMatch {
                    condition,
                    bindings: Vec::new(),
                }
            }

            // `p1 || p2` (`case bool _ || double _:`) and `p1 && p2`
            // (`case int n && > 0:`) — both operands run against the **same**
            // subject, and their bindings union. The union is deduped by name:
            // two `let`s of one name in a block would shadow, silently making the
            // body read the *second* alternative's accessor.
            "LogicalOrPattern" | "LogicalAndPattern" => {
                let left = self.required_sub_pattern(&f, "left", subject, &kind);
                let right = self.required_sub_pattern(&f, "right", subject, &kind);
                let conditions = vec![left.condition, right.condition];
                let condition = if kind == "LogicalOrPattern" {
                    any_of(conditions)
                } else {
                    all_of(conditions)
                };
                let mut bindings = left.bindings;
                for binding in right.bindings {
                    if !bindings.iter().any(|(name, _)| *name == binding.0) {
                        bindings.push(binding);
                    }
                }
                PatternMatch {
                    condition,
                    bindings,
                }
            }

            // `p as T` — an **assertion**, not a refutation: a type mismatch
            // *throws* a catchable Ball `TypeError`, it does not fall through to
            // the next case. The sub-pattern's condition is the **left** conjunct
            // so the assert only fires once the outer shape matched —
            // `[var x as int]` must not throw when the subject isn't a 2-element
            // list at all (fixture 302).
            "CastPattern" => {
                let sub = self.optional_sub_pattern(&f, "pattern", subject);
                let Some(type_name) = self
                    .string_field(&f, "type")
                    .filter(|type_name| !type_name.is_empty())
                else {
                    return sub;
                };
                PatternMatch {
                    condition: all_of(vec![
                        sub.condition,
                        format!(
                            "ball_cast_assert({}, {type_name:?})",
                            type_check(subject, &type_name)
                        ),
                    ]),
                    bindings: sub.bindings,
                }
            }

            // `p?` / `p!` — identical for *matching* purposes (both reference
            // engines treat them the same): a null never matches, and never binds.
            "NullCheckPattern" | "NullAssertPattern" => {
                let sub = self.optional_sub_pattern(&f, "pattern", subject);
                PatternMatch {
                    condition: all_of(vec![format!("{subject} != BallValue::Null"), sub.condition]),
                    bindings: sub.bindings,
                }
            }

            "ListPattern" => self.compile_list_pattern(&f, subject),
            "MapPattern" => self.compile_map_pattern(&f, subject),
            "RecordPattern" => self.compile_record_pattern(&f, subject),
            "ObjectPattern" => self.compile_object_pattern(&f, subject),

            // Only meaningful *inside* a `ListPattern` (handled there). A
            // stand-alone one is defensive: delegate to its sub-pattern.
            "RestPattern" => self.optional_sub_pattern(&f, "subpattern", subject),

            other => panic!(
                "ball-lang-compiler: unsupported pattern kind '{other}' — every kind must \
                 compile to a real condition; a placeholder would make the switch take the \
                 wrong arm, print the wrong answer and still exit 0 (issue #55)"
            ),
        }
    }

    /// The condition a pattern's optional `type` field contributes: the shared
    /// type test when present, an unconditional `true` when absent. Shared by
    /// `VarPattern` and `WildcardPattern` — see the `WildcardPattern` arm.
    fn pattern_type_condition(
        &self,
        fields: &IndexMap<String, Expression>,
        subject: &str,
    ) -> String {
        match self
            .string_field(fields, "type")
            .filter(|type_name| !type_name.is_empty())
        {
            Some(type_name) => type_check(subject, &type_name),
            None => "true".to_string(),
        }
    }

    /// A **required** sub-pattern (a logical pattern's `left`/`right`). Absent
    /// means a malformed IR — a compile-time error, never a silently-`true`
    /// operand that would make the whole alternation match everything.
    fn required_sub_pattern(
        &self,
        fields: &IndexMap<String, Expression>,
        key: &str,
        subject: &str,
        kind: &str,
    ) -> PatternMatch {
        match fields.get(key) {
            Some(pattern) => self.compile_pattern(pattern, subject),
            None => panic!("ball-lang-compiler: {kind} is missing its `{key}` operand"),
        }
    }

    /// An **optional** sub-pattern (a cast's / null-check's / rest's inner
    /// pattern) — absent means "matches anything, binds nothing".
    fn optional_sub_pattern(
        &self,
        fields: &IndexMap<String, Expression>,
        key: &str,
        subject: &str,
    ) -> PatternMatch {
        match fields.get(key) {
            Some(pattern) => self.compile_pattern(pattern, subject),
            None => PatternMatch::always(),
        }
    }

    /// `[a, b]` / `[a, ...rest, z]`. The `is List` and length conjuncts come
    /// **first**, so no element accessor is ever evaluated against a non-list or
    /// out of range. A rest element (`...`, `...var tail`) is a `RestPattern`
    /// *inside* `elements` (there is no separate `rest` field); Dart allows at
    /// most one, so the first wins.
    fn compile_list_pattern(
        &self,
        fields: &IndexMap<String, Expression>,
        subject: &str,
    ) -> PatternMatch {
        let elements = fields
            .get("elements")
            .map(literal_list_elements)
            .unwrap_or_default();
        let mut conditions = vec![type_check(subject, "List")];
        let mut bindings: Vec<(String, String)> = Vec::new();

        let Some(rest_at) = elements.iter().position(|e| self.is_rest_pattern(e)) else {
            conditions.push(format!(
                "ball_length({subject}) == BallValue::Int({})",
                elements.len()
            ));
            for (index, element) in elements.iter().enumerate() {
                let sub = self.compile_pattern(element, &list_element(subject, index));
                conditions.push(sub.condition);
                bindings.extend(sub.bindings);
            }
            return PatternMatch {
                condition: all_of(conditions),
                bindings,
            };
        };

        let before = &elements[..rest_at];
        let after = &elements[rest_at + 1..];
        conditions.push(is_true(&format!(
            "ball_gte(ball_length({subject}), BallValue::Int({}))",
            before.len() + after.len()
        )));
        for (index, element) in before.iter().enumerate() {
            let sub = self.compile_pattern(element, &list_element(subject, index));
            conditions.push(sub.condition);
            bindings.extend(sub.bindings);
        }
        // `...var tail` binds the middle slice `[|before| .. len - |after|]`.
        if let Some(rest) = self.pattern_fields(&elements[rest_at]).get("subpattern") {
            let slice = format!(
                "ball_list_slice({subject}, BallValue::Int({}), \
                 ball_subtract(ball_length({subject}), BallValue::Int({})))",
                before.len(),
                after.len()
            );
            let sub = self.compile_pattern(rest, &slice);
            conditions.push(sub.condition);
            bindings.extend(sub.bindings);
        }
        // A trailing element's index is computed from the subject's *actual*
        // length, not a constant.
        for (index, element) in after.iter().enumerate() {
            let accessor = format!(
                "ball_index_get({subject}, \
                 ball_subtract(ball_length({subject}), BallValue::Int({})))",
                after.len() - index
            );
            let sub = self.compile_pattern(element, &accessor);
            conditions.push(sub.condition);
            bindings.extend(sub.bindings);
        }
        PatternMatch {
            condition: all_of(conditions),
            bindings,
        }
    }

    /// `{'k': p, …}`. Extra keys in the subject are **allowed** (unlike a
    /// record). The subject must be a real map and **not a Set** (issue #178):
    /// the portable set form `{'__ball_set__': [...]}` is itself a map and would
    /// otherwise satisfy a map pattern keyed on that marker — the reference
    /// engine rejects sets first (fixture 394).
    fn compile_map_pattern(
        &self,
        fields: &IndexMap<String, Expression>,
        subject: &str,
    ) -> PatternMatch {
        let mut conditions = map_gate(subject);
        let mut bindings: Vec<(String, String)> = Vec::new();
        for entry in fields
            .get("entries")
            .map(literal_list_elements)
            .unwrap_or_default()
        {
            let ef = self.pattern_fields(&entry);
            let Some(key) = ef.get("key") else { continue };
            let key = self.compile_expression(key);
            conditions.push(is_true(&format!("ball_map_contains_key({subject}, {key})")));
            if let Some(value) = ef.get("value") {
                let sub = self.compile_pattern(value, &format!("ball_map_get({subject}, {key})"));
                conditions.push(sub.condition);
                bindings.extend(sub.bindings);
            }
        }
        PatternMatch {
            condition: all_of(conditions),
            bindings,
        }
    }

    /// `(1, var x)` / `(a: 1, b: var y)` — an **exact** shape: a 2-field pattern
    /// must not match a 3-field record (fixture 305).
    ///
    /// This mirrors how a record is *constructed*: the encoder emits one as an
    /// anonymous `MessageCreation` whose positional fields are named `$1`, `$2`,
    /// … and whose named fields keep their names, and
    /// [`Compiler::compile_record`] lowers that to a plain `BallValue::Map` with
    /// exactly those keys. Matching the key **count** and every expected key's
    /// presence is therefore equivalent to matching the key *set* exactly (a
    /// record carries no `__`-prefixed metadata key to exclude — a typed object
    /// is a `BallValue::Message`, not a map).
    fn compile_record_pattern(
        &self,
        fields: &IndexMap<String, Expression>,
        subject: &str,
    ) -> PatternMatch {
        let record_fields = fields
            .get("fields")
            .map(literal_list_elements)
            .unwrap_or_default();
        let mut conditions = map_gate(subject);
        conditions.push(format!(
            "ball_map_length({subject}) == BallValue::Int({})",
            record_fields.len()
        ));
        let mut bindings: Vec<(String, String)> = Vec::new();
        let mut positional = 0usize;
        for field in &record_fields {
            let ff = self.pattern_fields(field);
            let key = match self.string_field(&ff, "name") {
                Some(name) if !name.is_empty() => name,
                _ => {
                    positional += 1;
                    format!("${positional}")
                }
            };
            let key = format!("BallValue::String({key:?}.to_string())");
            conditions.push(is_true(&format!("ball_map_contains_key({subject}, {key})")));
            let Some(pattern) = ff.get("pattern") else {
                continue;
            };
            let sub = self.compile_pattern(pattern, &format!("ball_map_get({subject}, {key})"));
            conditions.push(sub.condition);
            bindings.extend(sub.bindings);
        }
        PatternMatch {
            condition: all_of(conditions),
            bindings,
        }
    }

    /// `Type(field: p, …)` — the same type gate a typed binder / `CastPattern`
    /// uses, plus a getter per named field. Extra fields on the subject are fine:
    /// this is field access, not positional arity.
    fn compile_object_pattern(
        &self,
        fields: &IndexMap<String, Expression>,
        subject: &str,
    ) -> PatternMatch {
        let mut conditions = Vec::new();
        if let Some(type_name) = self
            .string_field(fields, "type")
            .filter(|type_name| !type_name.is_empty())
        {
            conditions.push(type_check(subject, &type_name));
        }
        let mut bindings: Vec<(String, String)> = Vec::new();
        for field in fields
            .get("fields")
            .map(literal_list_elements)
            .unwrap_or_default()
        {
            let ff = self.pattern_fields(&field);
            let (Some(name), Some(pattern)) = (self.string_field(&ff, "name"), ff.get("pattern"))
            else {
                continue;
            };
            let sub =
                self.compile_pattern(pattern, &format!("ball_field_get({subject}, {name:?})"));
            conditions.push(sub.condition);
            bindings.extend(sub.bindings);
        }
        PatternMatch {
            condition: all_of(conditions),
            bindings,
        }
    }

    /// A pattern node's fields (or those of a map-entry / record-field /
    /// object-field sub-message — anonymous `MessageCreation`s), by name.
    fn pattern_fields(&self, expr: &Expression) -> IndexMap<String, Expression> {
        match &expr.expr {
            Some(Expr::MessageCreation(mc)) => self.message_creation_fields(mc),
            _ => IndexMap::new(),
        }
    }

    /// Is this list element the (at most one) `RestPattern` — `...` /
    /// `...var tail`?
    fn is_rest_pattern(&self, expr: &Expression) -> bool {
        matches!(&expr.expr, Some(Expr::MessageCreation(mc)) if mc.type_name == "RestPattern")
    }
}

/// The `let`s an arm re-materializes its binders from, at the head of the
/// matched block (and, separately, at the head of its guard's block — both must
/// see the same names). Accessors are recomputed rather than captured: they are
/// pure reads of the already-matched subject.
pub(crate) fn binding_decls(bindings: &[(String, String)]) -> String {
    bindings
        .iter()
        .map(|(name, accessor)| format!("let {} = {accessor};\n", sanitize_ident(name)))
        .collect()
}

/// A `(name, accessor)` entry for a binder — nothing for an anonymous one (`_`
/// binds nothing; the reference engine skips it too).
fn binding_of(name: &str, subject: &str) -> Vec<(String, String)> {
    if name.is_empty() || name == "_" {
        Vec::new()
    } else {
        vec![(name.to_string(), subject.to_string())]
    }
}

/// A `BallValue`-returning comparison helper's result, as a Rust `bool` — the
/// same shape the switch's own equality condition has always used.
fn is_true(call: &str) -> String {
    format!("{call} == BallValue::Bool(true)")
}

/// The shared type test. [`ball_lang_shared::runtime::ball_is_type`] already
/// handles nullable `T?` (a `null` matches — `case int? n:`), generic arguments
/// (`List<int>` → `List`), and a message's registered superclass chain. An
/// unrecognized `T` falls through to the user-type test (false for a primitive),
/// never to a hardcoded `true`.
fn type_check(subject: &str, type_name: &str) -> String {
    format!("ball_is_type(&{subject}, {type_name:?})")
}

/// The map-shape gate shared by `MapPattern` and `RecordPattern` — see
/// [`Compiler::compile_map_pattern`] for why a Set is excluded.
fn map_gate(subject: &str) -> Vec<String> {
    vec![
        type_check(subject, "Map"),
        format!("!{}", type_check(subject, "Set")),
    ]
}

/// `S[i]`.
fn list_element(subject: &str, index: usize) -> String {
    format!("ball_index_get({subject}, BallValue::Int({index}))")
}

/// Conjoin, dropping trivially-`true` conjuncts.
fn all_of(conditions: Vec<String>) -> String {
    join(
        conditions.into_iter().filter(|c| c != "true").collect(),
        "&&",
    )
}

/// Disjoin. A `true` member is **not** dropped here — it makes the whole
/// disjunction unconditional, which is exactly what an untyped alternative means.
fn any_of(conditions: Vec<String>) -> String {
    join(conditions, "||")
}

/// Members are parenthesized so one that is itself an `&&`/`||` chain keeps its
/// meaning inside the other operator.
fn join(conditions: Vec<String>, operator: &str) -> String {
    match conditions.len() {
        0 => "true".to_string(),
        1 => conditions.into_iter().next().unwrap_or_default(),
        _ => conditions
            .iter()
            .map(|condition| format!("({condition})"))
            .collect::<Vec<_>>()
            .join(&format!(" {operator} ")),
    }
}
