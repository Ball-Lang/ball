using System.Text;
using Ball.Shared;
using Ball.V1;

namespace Ball.Compiler;

/// <summary>
/// Dart-3 structured-pattern compilation — a <c>switch</c> case's
/// <c>pattern_expr</c> lowered to (a) a boolean C# condition over the subject
/// and (b) a flat list of binders, each an <em>accessor expression</em> over
/// that same subject. The C# port of <c>ts/compiler/src/compiler.ts</c>'s
/// <c>compileStructuredPattern</c> (the leg that scores the full corpus) and of
/// the reference engine's <c>_matchStructuredPattern</c>
/// (<c>dart/engine/lib/engine_std.dart</c>).
///
/// <para><b>Accessors, not values.</b> A sub-pattern is compiled against a
/// derived accessor <em>string</em> (<c>PatternIndex(s, 0)</c>,
/// <c>PatternKeyGet(s, Str("k"))</c>, …), never against an evaluated value —
/// which is what lets one recursive pass produce one flat condition plus one
/// flat binding list, and why the binders can be re-materialized as locals at
/// the head of the matched arm. Conjuncts are ordered so the shape gates
/// (<c>is-list</c>, length, <c>has-key</c>) always short-circuit ahead of the
/// accessors that would index/deref the subject.</para>
///
/// <para><b>Fail loud (issue #55).</b> An unhandled pattern kind THROWS at
/// compile time naming the kind. It never degrades into a placeholder condition
/// — a program that compiles, runs, exits 0 and prints the wrong answer is the
/// worst outcome, and a silently-<c>true</c> typed wildcard is exactly how a
/// four-arm switch collapses onto its first case.</para>
/// </summary>
public sealed partial class CSharpCompiler
{
    /// <summary>A compiled pattern: its match condition, and the binders it introduces as <c>(ball name, accessor expression)</c> pairs.</summary>
    private readonly record struct PatternMatch(string Condition, List<(string Name, string Accessor)> Bindings);

    private static PatternMatch Always => new("true", new List<(string, string)>());

    /// <summary>
    /// The pattern kind — the <see cref="MessageCreation.TypeName"/> the encoder
    /// stamps on the pattern message (<c>VarPattern</c>, <c>ListPattern</c>, …),
    /// with the engine-normalized <c>__pattern_kind__</c> field as a fallback.
    /// <c>type_name</c> is not a field.
    /// </summary>
    private static string PatternKind(MessageCreation mc, OrderedDictionary<string, Expression> fields) =>
        mc.TypeName.Length != 0
            ? Naming.TypeShortName(mc.TypeName)
            : StringField(fields, "__pattern_kind__") ?? string.Empty;

    private static string PatternKindOf(Expression pattern) =>
        pattern.ExprCase == Expression.ExprOneofCase.MessageCreation
            ? PatternKind(pattern.MessageCreation, MessageCreationFields(pattern.MessageCreation))
            : string.Empty;

    /// <summary>The sub-pattern elements of a pattern's repeated field (<c>elements</c>/<c>entries</c>/<c>fields</c>), encoded as a list literal.</summary>
    private static List<Expression> PatternList(OrderedDictionary<string, Expression> fields, string key)
    {
        var result = new List<Expression>();
        if (fields.TryGetValue(key, out var expr)
            && expr.ExprCase == Expression.ExprOneofCase.Literal
            && expr.Literal.ValueCase == Literal.ValueOneofCase.ListValue)
        {
            result.AddRange(expr.Literal.ListValue.Elements);
        }

        return result;
    }

    /// <summary>
    /// The type test behind a typed binder (<c>int x</c>), a typed wildcard
    /// (<c>int _</c>), an object pattern's gate and a cast's assertion — all four
    /// go through this one predicate, because a typed wildcard that answers
    /// <c>true</c> unconditionally silently collapses the whole switch onto its
    /// first case (183/303).
    /// </summary>
    private static string TypeTest(string subject, string typeName) =>
        $"BallRuntime.PatternIsType({subject}, {Naming.StringLiteral(typeName)})";

    private static string Conjoin(List<string> conditions) =>
        conditions.Count switch
        {
            0 => "true",
            1 => conditions[0],
            _ => "(" + string.Join(" && ", conditions) + ")",
        };

    /// <summary>Compile one structured pattern against <paramref name="subject"/> (a C# expression that must be pure — the switch's subject temp, or an accessor derived from it).</summary>
    private PatternMatch CompilePattern(string subject, Expression pattern)
    {
        if (pattern.ExprCase != Expression.ExprOneofCase.MessageCreation)
        {
            throw new InvalidOperationException(
                "C# compiler: switch case carries no structured pattern (pattern_expr must be a MessageCreation)");
        }

        var mc = pattern.MessageCreation;
        var f = MessageCreationFields(mc);
        var kind = PatternKind(mc, f);
        switch (kind)
        {
            case "VarPattern":
                return CompileVarPattern(subject, f);
            case "WildcardPattern":
                // A typed wildcard TESTS its type. Answering "true" here would make
                // the first typed case a catch-all, the switch would collapse onto
                // it, and every subject would print that arm's answer (183 printed
                // int/int/int/int) — the CARDINAL-RULE failure: exit 0, wrong output.
                return new PatternMatch(
                    StringField(f, "type") is { } wildType ? TypeTest(subject, wildType) : "true",
                    new List<(string, string)>());
            case "ConstPattern":
                return new PatternMatch(
                    f.TryGetValue("value", out var constValue)
                        ? $"BallValue.ValueEquals({subject}, {CompileExpression(constValue)})"
                        : "true",
                    new List<(string, string)>());
            case "RelationalPattern":
                return CompileRelationalPattern(subject, f);
            case "LogicalOrPattern":
                return CompileLogicalPattern(subject, f, "||");
            case "LogicalAndPattern":
                return CompileLogicalPattern(subject, f, "&&");
            case "CastPattern":
                return CompileCastPattern(subject, f);
            case "NullCheckPattern":
            case "NullAssertPattern":
                return CompileNullPattern(subject, f);
            case "ListPattern":
                return CompileListPattern(subject, f);
            case "MapPattern":
                return CompileMapPattern(subject, f);
            case "RecordPattern":
                return CompileRecordPattern(subject, f);
            case "ObjectPattern":
                return CompileObjectPattern(subject, f);
            case "RestPattern":
                // Only meaningful inside a list pattern (handled there); standalone
                // it is its sub-pattern, or an unconditional match.
                return f.TryGetValue("subpattern", out var rest) ? CompilePattern(subject, rest) : Always;
            default:
                throw new InvalidOperationException(
                    $"C# compiler: unsupported pattern kind '{kind}'");
        }
    }

    /// <summary><c>var x</c> / <c>int x</c> / <c>int? x</c> — binds unconditionally, or behind its declared type's test.</summary>
    private PatternMatch CompileVarPattern(string subject, OrderedDictionary<string, Expression> f)
    {
        var name = StringField(f, "name") ?? "_";
        var condition = StringField(f, "type") is { } type ? TypeTest(subject, type) : "true";
        var bindings = new List<(string, string)>();
        if (name != "_")
        {
            bindings.Add((name, subject));
        }

        return new PatternMatch(condition, bindings);
    }

    /// <summary>
    /// <c>== x</c> / <c>!= x</c> / <c>&gt; 5</c> — equality goes through Ball
    /// value equality (reference identity on a boxed number would never fire);
    /// an ordering comparison against a non-numeric subject is a non-match, not
    /// a throw.
    /// </summary>
    private PatternMatch CompileRelationalPattern(string subject, OrderedDictionary<string, Expression> f)
    {
        if (StringField(f, "operator") is not { } op || !f.TryGetValue("operand", out var operandExpr))
        {
            return Always;
        }

        var operand = CompileExpression(operandExpr);
        var condition = op switch
        {
            "==" => $"BallValue.ValueEquals({subject}, {operand})",
            "!=" => $"!BallValue.ValueEquals({subject}, {operand})",
            ">" or "<" or ">=" or "<=" =>
                $"BallRuntime.PatternRelational({subject}, {Naming.StringLiteral(op)}, {operand})",
            _ => throw new InvalidOperationException(
                $"C# compiler: unsupported relational pattern operator '{op}'"),
        };
        return new PatternMatch(condition, new List<(string, string)>());
    }

    /// <summary><c>p1 || p2</c> / <c>p1 &amp;&amp; p2</c> — both operands match the SAME subject; the binder lists union (deduped, since C# forbids re-declaring a name).</summary>
    private PatternMatch CompileLogicalPattern(string subject, OrderedDictionary<string, Expression> f, string op)
    {
        if (!f.TryGetValue("left", out var left) || !f.TryGetValue("right", out var right))
        {
            return Always;
        }

        var l = CompilePattern(subject, left);
        var r = CompilePattern(subject, right);
        var bindings = new List<(string Name, string Accessor)>(l.Bindings);
        foreach (var binding in r.Bindings)
        {
            if (!bindings.Any(b => b.Name == binding.Name))
            {
                bindings.Add(binding);
            }
        }

        return new PatternMatch($"({l.Condition} {op} {r.Condition})", bindings);
    }

    /// <summary>
    /// <c>p as T</c> — an ASSERTION: a type mismatch throws, it does not fall
    /// through to the next case. The sub-pattern's condition is the LEFT
    /// conjunct, so the assert only fires once the outer shape matched
    /// (<c>[var x as int]</c> must not throw on a subject that is not a
    /// 2-element list at all).
    /// </summary>
    private PatternMatch CompileCastPattern(string subject, OrderedDictionary<string, Expression> f)
    {
        var sub = f.TryGetValue("pattern", out var inner) ? CompilePattern(subject, inner) : Always;
        if (StringField(f, "type") is not { } type)
        {
            return sub;
        }

        var assert = $"BallRuntime.PatternCastAssert({TypeTest(subject, type)}, {Naming.StringLiteral(type)})";
        return new PatternMatch($"({sub.Condition} && {assert})", sub.Bindings);
    }

    /// <summary><c>p?</c> / <c>p!</c> — a null never matches, and never binds; both kinds match identically.</summary>
    private PatternMatch CompileNullPattern(string subject, OrderedDictionary<string, Expression> f)
    {
        var sub = f.TryGetValue("pattern", out var inner) ? CompilePattern(subject, inner) : Always;
        var notNull = $"{subject} is not BallNull";
        return new PatternMatch(
            sub.Condition == "true" ? $"({notNull})" : $"({notNull} && {sub.Condition})",
            sub.Bindings);
    }

    /// <summary><c>[a, b]</c> / <c>[a, ...rest, z]</c> — the list gate and the length check precede every element accessor.</summary>
    private PatternMatch CompileListPattern(string subject, OrderedDictionary<string, Expression> f)
    {
        var elements = PatternList(f, "elements");
        var restIndex = elements.FindIndex(e => PatternKindOf(e) == "RestPattern");
        var conditions = new List<string> { $"BallRuntime.PatternIsList({subject})" };
        var bindings = new List<(string Name, string Accessor)>();

        if (restIndex < 0)
        {
            conditions.Add($"BallRuntime.PatternLength({subject}) == {elements.Count}");
            for (var i = 0; i < elements.Count; i++)
            {
                var element = CompilePattern($"BallRuntime.PatternIndex({subject}, {i})", elements[i]);
                conditions.Add(element.Condition);
                bindings.AddRange(element.Bindings);
            }

            return new PatternMatch(Conjoin(conditions), bindings);
        }

        var before = elements.Take(restIndex).ToList();
        var after = elements.Skip(restIndex + 1).ToList();
        conditions.Add($"BallRuntime.PatternLength({subject}) >= {before.Count + after.Count}");

        for (var i = 0; i < before.Count; i++)
        {
            var element = CompilePattern($"BallRuntime.PatternIndex({subject}, {i})", before[i]);
            conditions.Add(element.Condition);
            bindings.AddRange(element.Bindings);
        }

        // The rest element's own sub-pattern (`...var tail`) matches the SLICE
        // between the leading and trailing sub-patterns.
        var restFields = MessageCreationFields(elements[restIndex].MessageCreation);
        if (restFields.TryGetValue("subpattern", out var restSub))
        {
            var slice = $"BallRuntime.PatternSlice({subject}, {before.Count}, {after.Count})";
            var rest = CompilePattern(slice, restSub);
            conditions.Add(rest.Condition);
            bindings.AddRange(rest.Bindings);
        }

        // A trailing element's index is computed from the subject's length, not a
        // constant — the rest absorbed an unknown number of elements.
        for (var i = 0; i < after.Count; i++)
        {
            var index = $"BallRuntime.PatternLength({subject}) - {after.Count - i}";
            var element = CompilePattern($"BallRuntime.PatternIndex({subject}, {index})", after[i]);
            conditions.Add(element.Condition);
            bindings.AddRange(element.Bindings);
        }

        return new PatternMatch(Conjoin(conditions), bindings);
    }

    /// <summary>
    /// <c>{'k': p, …}</c> — every pattern key must be PRESENT (extra subject keys
    /// are allowed, unlike a record). A Ball <c>Set</c> is a list, not a map, so
    /// it can never match here (issue #178 / fixture 394).
    /// </summary>
    private PatternMatch CompileMapPattern(string subject, OrderedDictionary<string, Expression> f)
    {
        var conditions = new List<string> { $"BallRuntime.PatternIsMap({subject})" };
        var bindings = new List<(string Name, string Accessor)>();

        foreach (var entry in PatternList(f, "entries"))
        {
            if (entry.ExprCase != Expression.ExprOneofCase.MessageCreation)
            {
                continue;
            }

            var ef = MessageCreationFields(entry.MessageCreation);
            if (!ef.TryGetValue("key", out var keyExpr))
            {
                continue;
            }

            var key = CompileExpression(keyExpr);
            conditions.Add($"BallRuntime.PatternHasKey({subject}, {key})");
            if (ef.TryGetValue("value", out var valuePattern))
            {
                var value = CompilePattern($"BallRuntime.PatternKeyGet({subject}, {key})", valuePattern);
                conditions.Add(value.Condition);
                bindings.AddRange(value.Bindings);
            }
        }

        return new PatternMatch(Conjoin(conditions), bindings);
    }

    /// <summary>
    /// <c>(1, var x)</c> / <c>(a: 1, b: var y)</c> — an EXACT shape. A record
    /// materializes as the map its <c>record</c> base call builds (positional
    /// fields keyed <c>$1</c>, <c>$2</c>, … — see <c>BaseCall.cs</c>'s
    /// <c>record</c>), so the pattern matches that key scheme and demands the
    /// exact field count: a 2-field pattern must not match a 3-field record.
    /// </summary>
    private PatternMatch CompileRecordPattern(string subject, OrderedDictionary<string, Expression> f)
    {
        var fields = PatternList(f, "fields");
        var conditions = new List<string>
        {
            $"BallRuntime.PatternIsMap({subject})",
            $"BallRuntime.PatternRecordArity({subject}, {fields.Count})",
        };
        var bindings = new List<(string Name, string Accessor)>();

        var positional = 0;
        foreach (var field in fields)
        {
            if (field.ExprCase != Expression.ExprOneofCase.MessageCreation)
            {
                continue;
            }

            var ff = MessageCreationFields(field.MessageCreation);
            if (!ff.TryGetValue("pattern", out var sub))
            {
                continue;
            }

            var key = StringField(ff, "name") ?? $"${++positional}";
            var keyLiteral = $"Str({Naming.StringLiteral(key)})";
            conditions.Add($"BallRuntime.PatternHasKey({subject}, {keyLiteral})");
            var value = CompilePattern($"BallRuntime.PatternKeyGet({subject}, {keyLiteral})", sub);
            conditions.Add(value.Condition);
            bindings.AddRange(value.Bindings);
        }

        return new PatternMatch(Conjoin(conditions), bindings);
    }

    /// <summary><c>Type(field: p, …)</c> — the same type gate as a typed binder, plus a getter per named field. Extra fields on the subject are fine.</summary>
    private PatternMatch CompileObjectPattern(string subject, OrderedDictionary<string, Expression> f)
    {
        var conditions = new List<string>();
        if (StringField(f, "type") is { } type)
        {
            conditions.Add(TypeTest(subject, type));
        }

        var bindings = new List<(string Name, string Accessor)>();
        foreach (var field in PatternList(f, "fields"))
        {
            if (field.ExprCase != Expression.ExprOneofCase.MessageCreation)
            {
                continue;
            }

            var ff = MessageCreationFields(field.MessageCreation);
            if (StringField(ff, "name") is not { } name || !ff.TryGetValue("pattern", out var sub))
            {
                continue;
            }

            var value = CompilePattern($"BallRuntime.FieldGet({subject}, {Naming.StringLiteral(name)})", sub);
            conditions.Add(value.Condition);
            bindings.AddRange(value.Bindings);
        }

        return new PatternMatch(Conjoin(conditions), bindings);
    }

    /// <summary>
    /// Re-materialize a pattern's binders as locals, from the subject, at the
    /// head of the arm they belong to. The caller must have opened a scope
    /// (<see cref="PushScope"/>) — the body/guard is then compiled inside it, so
    /// its references resolve to these declarations.
    /// </summary>
    private string EmitPatternBindings(List<(string Name, string Accessor)> bindings)
    {
        var sb = new StringBuilder();
        foreach (var (name, accessor) in bindings)
        {
            sb.Append($"var {BindLocal(name)} = {accessor};\n");
        }

        return sb.ToString();
    }

    /// <summary>
    /// A <c>when</c> guard, as a conjunct of its arm's condition: it runs only
    /// after the pattern matched (C#'s <c>&amp;&amp;</c> short-circuit) and only
    /// after the binders it reads are materialized — and a matched pattern whose
    /// guard is false is NOT a match, so control falls through to the next case.
    /// </summary>
    private string GuardCondition(Expression guard, List<(string Name, string Accessor)> bindings)
    {
        PushScope();
        var binds = EmitPatternBindings(bindings);
        var expr = CompileExpression(guard);
        PopScope();

        return bindings.Count == 0
            ? $"BallRuntime.PatternGuard({expr})"
            : $"BallRuntime.PatternGuard(Run(() =>\n{{\n{binds}return {expr};\n}}))";
    }
}
