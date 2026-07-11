using System.Globalization;
using System.Text;
using Ball.V1;
using Google.Protobuf.WellKnownTypes;

namespace Ball.Compiler;

/// <summary>
/// Body-carrying constructor emission + class-hierarchy field binding (issue
/// #383, Round 3) — the C# port of <c>rust/compiler/src/type_emit.rs</c>'s
/// <c>compile_constructor_with_body</c> / <c>all_instance_field_names</c> /
/// <c>constructor_self_init</c> (the #39/#298/#300-era self-host constructor
/// work).
///
/// <para>The self-hosted engine's <c>BallEngine(...)</c> / <c>BallObject(...)</c>
/// constructors carry a real body (they build lookup tables, refresh entries,
/// validate limits) that MUST run on construction — a bare init-formal field map
/// leaves the instance half-built (no <c>_functions</c>/<c>_types</c>), which is
/// exactly why the engine could compile but not run after Round 2. A
/// <c>message_creation</c> for such a type therefore <b>invokes the
/// constructor</b> (<see cref="CompileMessageCreation"/>), and the constructor:</para>
/// <list type="number">
/// <item>binds each declared parameter from its input;</item>
/// <item>builds the instance — every instance field (own + inherited via the
/// <c>metadata.superclass</c> chain) seeded from its init-formal parameter, its
/// field-level default (<c>_functions = {}</c> → an empty map, <c>_globalScope =
/// _Scope()</c> → a real nested instance), or <c>Null</c>;</item>
/// <item>binds each instance field as a local alias so the body's bare field
/// references resolve (Dart's implicit-<c>this</c>);</item>
/// <item>runs the body; then</item>
/// <item>writes every body-reassigned field back into the instance (a
/// reference-semantic <see cref="Ball.Shared.BallMessage"/> shares its field map,
/// so mutations <em>through</em> a field alias already persist — only a bare
/// <c>field = x</c> rebind of the local needs write-back).</item>
/// </list>
/// </summary>
public sealed partial class CSharpCompiler
{
    /// <summary>Short type name → the impl method name of its body-carrying constructor (if any).</summary>
    private readonly Dictionary<string, string> _bodyCtorImplByShort = new(StringComparer.Ordinal);

    /// <summary>The backing instance fields of a <b>native</b> superclass (no user <c>TypeDefinition</c>).</summary>
    private static readonly Dictionary<string, string[]> NativeSuperclassFields = new(StringComparer.Ordinal)
    {
        // `class BallObject extends BallMap` inherits BallMap's ordered-map
        // backing `entries`, referenced as a bare name by setField/_refreshEntries.
        ["BallMap"] = new[] { "entries" },
    };

    /// <summary>Register every body-carrying constructor's impl name (called from the ctor, before any emission).</summary>
    private void IndexConstructors()
    {
        foreach (var (owner, members) in _classMembersByOwner)
        {
            foreach (var member in members)
            {
                if (MetaString(member.Metadata, "kind") != "constructor" || member.Body is null)
                {
                    continue;
                }

                if (Naming.SplitMemberName(member.Name) is { } split)
                {
                    var ownerShort = Naming.TypeShortName(owner);
                    _bodyCtorImplByShort[ownerShort] = MemberImplName(ownerShort, split.Member);
                }
            }
        }
    }

    /// <summary>
    /// The impl method name for a class member (<c>Owner__member</c>). The member
    /// component is keyword-unescaped (a bare <c>@</c> would be illegal mid-
    /// identifier — a constructor is named <c>new</c>, which <see cref="Naming.Sanitize"/>
    /// escapes to <c>@new</c>); the compound name is never itself a keyword.
    /// </summary>
    private static string MemberImplName(string ownerShort, string member) =>
        $"{Naming.Sanitize(ownerShort)}__{Naming.Sanitize(member).TrimStart('@')}";

    /// <summary>The impl method name of <paramref name="typeName"/>'s body-carrying constructor, or <c>null</c>.</summary>
    private string? BodyConstructorImpl(string typeName) =>
        typeName.Length > 0 && _bodyCtorImplByShort.TryGetValue(Naming.TypeShortName(typeName), out var impl)
            ? impl
            : null;

    // ════════════════════════════════════════════════════════════
    // Class-hierarchy field resolution
    // ════════════════════════════════════════════════════════════

    /// <summary>The <c>metadata.superclass</c> short name of <paramref name="td"/>, or <c>null</c>.</summary>
    private static string? SuperclassOf(TypeDefinition td)
    {
        var name = MetaString(td.Metadata, "superclass");
        return string.IsNullOrEmpty(name) ? null : name;
    }

    /// <summary>
    /// Every instance-field name of <paramref name="ownerTd"/> — own descriptor
    /// fields first, then each field inherited from the <c>metadata.superclass</c>
    /// chain, then any <see cref="NativeSuperclassFields"/> of a native base.
    /// Deduplicated, own-first. This is what lets a method/constructor body's bare
    /// reference to an inherited field (e.g. <c>entries</c> on <c>BallObject
    /// extends BallMap</c>) bind like an own field.
    /// </summary>
    private List<string> AllInstanceFieldNames(TypeDefinition ownerTd)
    {
        var names = new List<string>();
        var seen = new HashSet<string>(StringComparer.Ordinal);

        void AddDescriptorFields(TypeDefinition td)
        {
            if (td.Descriptor_ is null)
            {
                return;
            }

            foreach (var field in td.Descriptor_.Field)
            {
                if (!string.IsNullOrEmpty(field.Name) && seen.Add(field.Name))
                {
                    names.Add(field.Name);
                }
            }
        }

        AddDescriptorFields(ownerTd);
        var current = ownerTd;
        for (var i = 0; i < 32; i++)
        {
            var superName = SuperclassOf(current);
            if (superName is null)
            {
                break;
            }

            if (_typeDefsByShortName.TryGetValue(Naming.TypeShortName(superName), out var superTd))
            {
                AddDescriptorFields(superTd);
                current = superTd;
            }
            else
            {
                if (NativeSuperclassFields.TryGetValue(superName, out var nativeFields))
                {
                    foreach (var name in nativeFields)
                    {
                        if (seen.Add(name))
                        {
                            names.Add(name);
                        }
                    }
                }

                break;
            }
        }

        return names;
    }

    /// <summary>The field-level default initializer source text for instance field <paramref name="field"/> (walking the superclass chain), or <c>null</c>.</summary>
    private string? FieldInitializerText(TypeDefinition td, string field)
    {
        var current = td;
        for (var i = 0; i < 32; i++)
        {
            var fields = MetaList(current.Metadata, "fields");
            if (fields is not null)
            {
                foreach (var entry in fields)
                {
                    if (entry.KindCase == Value.KindOneofCase.StructValue
                        && StructString(entry.StructValue, "name") == field)
                    {
                        return StructString(entry.StructValue, "initializer");
                    }
                }
            }

            var superName = SuperclassOf(current);
            if (superName is null
                || !_typeDefsByShortName.TryGetValue(Naming.TypeShortName(superName), out var superTd))
            {
                break;
            }

            current = superTd;
        }

        return null;
    }

    /// <summary>
    /// Lower a field-level initializer's cosmetic source text to a C#
    /// <c>BallValue</c> expression for the common literal / zero-arg-constructor
    /// shapes (<c>{}</c> → empty map, <c>_Scope()</c> → a real nested instance),
    /// or <c>null</c> for a richer expression the encoder stored only as text (the
    /// documented best-effort boundary — the field stays <c>Null</c>).
    /// </summary>
    private string? LowerFieldInitializer(string init, HashSet<string> visiting)
    {
        var s = StripGenericPrefix(init.Trim());
        switch (s)
        {
            case "{}":
                return "(BallValue)new BallMap()";
            case "[]":
                return "(BallValue)new BallList()";
            case "''":
            case "\"\"":
                return "Str(\"\")";
            case "true":
                return "Bool(true)";
            case "false":
                return "Bool(false)";
            case "null":
                return "BallValue.Null";
        }

        if (long.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out var l))
        {
            return $"Int({l}L)";
        }

        if (double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var d) && double.IsFinite(d))
        {
            return $"Double({Naming.DoubleLiteral(d)})";
        }

        if (s.EndsWith("()", StringComparison.Ordinal))
        {
            var typeName = s[..^2].Trim();
            if (IsSimpleIdent(typeName))
            {
                return ConstructDefaultInstance(typeName, visiting);
            }
        }

        return null;
    }

    /// <summary>Construct a <c>Type()</c> default instance — call its body-constructor, or build a field-default map for a bodyless type; <c>null</c> for a native/unknown type.</summary>
    private string? ConstructDefaultInstance(string shortType, HashSet<string> visiting)
    {
        if (!visiting.Add(shortType))
        {
            return null; // guard against a cyclic constructor-default chain
        }

        try
        {
            if (!_typeDefsByShortName.TryGetValue(shortType, out var td))
            {
                return null;
            }

            if (BodyConstructorImpl(shortType) is { } implName)
            {
                return $"{implName}((BallValue)new BallMap())";
            }

            var entries = FieldDefaultEntries(td, new HashSet<string>(StringComparer.Ordinal), visiting);
            var mapExpr = entries.Count == 0 ? "new BallMap()" : $"new BallMap {{ {string.Join(", ", entries)} }}";
            return $"(BallValue)new BallMessage({Naming.StringLiteral(td.Name)}, {mapExpr})";
        }
        finally
        {
            visiting.Remove(shortType);
        }
    }

    /// <summary>The <c>[field] = default</c> entries for every instance field of <paramref name="td"/> not in <paramref name="explicitFields"/>.</summary>
    private List<string> FieldDefaultEntries(TypeDefinition td, HashSet<string> explicitFields, HashSet<string> visiting)
    {
        var entries = new List<string>();
        foreach (var field in AllInstanceFieldNames(td))
        {
            if (explicitFields.Contains(field))
            {
                continue;
            }

            var text = FieldInitializerText(td, field);
            var value = text is null ? null : LowerFieldInitializer(text, visiting);
            value ??= NativeInheritedFieldDefault(td, field);
            if (value is not null)
            {
                entries.Add($"[{Naming.StringLiteral(field)}] = {value}");
            }
        }

        return entries;
    }

    /// <summary>The default for a native-inherited backing field (<c>BallMap.entries</c> → an empty map), or <c>null</c>.</summary>
    private string? NativeInheritedFieldDefault(TypeDefinition td, string field)
    {
        var current = td;
        for (var i = 0; i < 32; i++)
        {
            var superName = SuperclassOf(current);
            if (superName is null)
            {
                return null;
            }

            if (_typeDefsByShortName.TryGetValue(Naming.TypeShortName(superName), out var superTd))
            {
                current = superTd;
                continue;
            }

            if (NativeSuperclassFields.TryGetValue(superName, out var nativeFields) && Array.IndexOf(nativeFields, field) >= 0)
            {
                // The only native backing field today is BallMap's ordered map.
                return "(BallValue)new BallMap()";
            }

            return null;
        }

        return null;
    }

    // ════════════════════════════════════════════════════════════
    // Constructor emission
    // ════════════════════════════════════════════════════════════

    /// <summary>
    /// Emit a body-carrying constructor as a static <c>&lt;Owner&gt;__&lt;short&gt;(input)</c>
    /// method that binds params, builds the instance (own + inherited fields
    /// defaulted/init-formal-seeded), runs the body with each field aliased, then
    /// writes body-reassigned fields back and returns the instance.
    /// </summary>
    private string CompileConstructor(string implName, TypeDefinition ownerTd, FunctionDefinition ctor)
    {
        var inName = PushInput();
        PushScope();
        // `public` (in the internal BallProgram class → assembly-scoped) so the
        // self-host driver (Ball.Engine's BallEngine.Run) can construct the engine
        // by invoking this constructor directly.
        var sb = new StringBuilder($"    public static BallValue {implName}(BallValue {inName})\n    {{\n");

        var paramNames = ParamNames(ctor);
        var paramSet = new HashSet<string>(paramNames, StringComparer.Ordinal);
        var positional = 0;
        foreach (var param in paramNames)
        {
            var argKey = Naming.StringLiteral($"arg{positional}");
            positional++;
            sb.Append($"        var {BindLocal(param)} = BallRuntime.ArgGet({inName}, {Naming.StringLiteral(param)}, {argKey});\n");
        }

        // Build the instance: each field seeded from its init-formal parameter,
        // its field-level default, a native-inherited default, or Null.
        var fields = AllInstanceFieldNames(ownerTd);
        var entries = new List<string>();
        foreach (var field in fields)
        {
            string value;
            if (paramSet.Contains(field) && LocalName(field) is { } paramLocal)
            {
                value = paramLocal;
            }
            else if (FieldInitializerParam(ctor, field, paramSet) is { } initParam && LocalName(initParam) is { } initLocal)
            {
                value = initLocal;
            }
            else if (FieldInitializerText(ownerTd, field) is { } text
                     && LowerFieldInitializer(text, new HashSet<string>(StringComparer.Ordinal)) is { } defaultValue)
            {
                value = defaultValue;
            }
            else if (NativeInheritedFieldDefault(ownerTd, field) is { } nativeDefault)
            {
                value = nativeDefault;
            }
            else
            {
                value = "BallValue.Null";
            }

            entries.Add($"[{Naming.StringLiteral(field)}] = {value}");
        }

        var mapExpr = entries.Count == 0 ? "new BallMap()" : $"new BallMap {{ {string.Join(", ", entries)} }}";
        var selfName = BindLocal("self");
        sb.Append($"        var {selfName} = (BallValue)new BallMessage({Naming.StringLiteral(ownerTd.Name)}, {mapExpr});\n");

        var prevInInstance = _inInstanceMethod;
        var prevSelfRecv = _selfRecvName;
        _inInstanceMethod = true;
        _selfRecvName = selfName;

        // Bind each instance field as a local alias (own + inherited) so the
        // body's bare field references resolve (Dart implicit-`this`).
        var fieldAliases = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var field in fields)
        {
            var local = BindLocal(field);
            fieldAliases[field] = local;
            sb.Append($"        var {local} = BallRuntime.FieldGet({selfName}, {Naming.StringLiteral(field)});\n");
        }

        // Run the body inside an IIFE so an early `return` in the constructor
        // yields to the field write-back + `return self` below, rather than
        // returning past them (and dropping the instance).
        if (ctor.Body is not null)
        {
            var bodyInner = ctor.Body.ExprCase == Expression.ExprOneofCase.Block
                ? EmitBlockInner(ctor.Body.Block, isFunctionBody: false)
                : EmitStatement(ctor.Body) + "\n";
            sb.Append($"        Run(() =>\n        {{\n{bodyInner}        return BallValue.Null;\n        }});\n");
        }

        // Persist any body-reassigned field back into the instance. (Mutations
        // *through* a field alias already persist via the shared field map.)
        if (ctor.Body is not null)
        {
            foreach (var field in fields)
            {
                if (ExprReassignsVar(ctor.Body, field) && fieldAliases.TryGetValue(field, out var local))
                {
                    sb.Append($"        BallRuntime.FieldSet({selfName}, {Naming.StringLiteral(field)}, {local});\n");
                }
            }
        }

        sb.Append($"        return {selfName};\n");
        sb.Append("    }\n");
        _inInstanceMethod = prevInInstance;
        _selfRecvName = prevSelfRecv;
        PopScope();
        PopInput();
        return sb.ToString();
    }

    /// <summary>The parameter that a <c>metadata.initializers</c> field entry sets <paramref name="field"/> from (the <c>field = param</c> / <c>field = param ?? default</c> shape), or <c>null</c>.</summary>
    private static string? FieldInitializerParam(FunctionDefinition ctor, string field, HashSet<string> paramNames)
    {
        var initializers = MetaList(ctor.Metadata, "initializers");
        if (initializers is null)
        {
            return null;
        }

        foreach (var init in initializers)
        {
            if (init.KindCase != Value.KindOneofCase.StructValue)
            {
                continue;
            }

            var initStruct = init.StructValue;
            if (StructString(initStruct, "kind") != "field" || StructString(initStruct, "name") != field)
            {
                continue;
            }

            var value = StructString(initStruct, "value");
            if (value is null)
            {
                return null;
            }

            var token = new string(value.Trim().TakeWhile(c => char.IsLetterOrDigit(c) || c == '_').ToArray());
            return paramNames.Contains(token) ? token : null;
        }

        return null;
    }

    // ════════════════════════════════════════════════════════════
    // Mutation analysis (for field write-back)
    // ════════════════════════════════════════════════════════════

    /// <summary>Whether <paramref name="expr"/> reassigns the bare local <paramref name="name"/> (an <c>assign</c>/increment/decrement whose target is <c>reference(name)</c>).</summary>
    private static bool ExprReassignsVar(Expression expr, string name)
    {
        switch (expr.ExprCase)
        {
            case Expression.ExprOneofCase.Call:
                var call = expr.Call;
                if (call.Module is "std" or ""
                    && call.Function is "assign" or "pre_increment" or "post_increment" or "pre_decrement" or "post_decrement"
                    && call.Input is { ExprCase: Expression.ExprOneofCase.MessageCreation } input)
                {
                    foreach (var field in input.MessageCreation.Fields)
                    {
                        if (field.Name is "target" or "value"
                            && field.Value is { ExprCase: Expression.ExprOneofCase.Reference } refExpr
                            && refExpr.Reference.Name == name)
                        {
                            return true;
                        }
                    }
                }

                return call.Input is not null && ExprReassignsVar(call.Input, name);
            case Expression.ExprOneofCase.MessageCreation:
                foreach (var field in expr.MessageCreation.Fields)
                {
                    if (field.Value is not null && ExprReassignsVar(field.Value, name))
                    {
                        return true;
                    }
                }

                return false;
            case Expression.ExprOneofCase.Block:
                foreach (var statement in expr.Block.Statements)
                {
                    if (statement.StmtCase == Statement.StmtOneofCase.Let && statement.Let.Value is { } letValue
                        && ExprReassignsVar(letValue, name))
                    {
                        return true;
                    }

                    if (statement.StmtCase == Statement.StmtOneofCase.Expression && ExprReassignsVar(statement.Expression, name))
                    {
                        return true;
                    }
                }

                return expr.Block.Result is not null && ExprReassignsVar(expr.Block.Result, name);
            case Expression.ExprOneofCase.FieldAccess:
                return expr.FieldAccess.Object is not null && ExprReassignsVar(expr.FieldAccess.Object, name);
            case Expression.ExprOneofCase.Lambda:
                return expr.Lambda.Body is not null && ExprReassignsVar(expr.Lambda.Body, name);
            default:
                return false;
        }
    }

    // ════════════════════════════════════════════════════════════
    // Metadata + text helpers
    // ════════════════════════════════════════════════════════════

    /// <summary>The values of a <c>metadata</c> list field, or <c>null</c> if absent/not a list.</summary>
    private static IReadOnlyList<Value>? MetaList(Struct? meta, string key) =>
        meta is not null
        && meta.Fields.TryGetValue(key, out var value)
        && value.KindCase == Value.KindOneofCase.ListValue
            ? value.ListValue.Values
            : null;

    /// <summary>A string field of a nested metadata <see cref="Struct"/>, or <c>null</c>.</summary>
    private static string? StructString(Struct s, string key) =>
        s.Fields.TryGetValue(key, out var value) && value.KindCase == Value.KindOneofCase.StringValue
            ? value.StringValue
            : null;

    /// <summary>Strip a leading Dart generic type-argument prefix (<c>&lt;String, int&gt;{}</c> → <c>{}</c>).</summary>
    private static string StripGenericPrefix(string s)
    {
        if (!s.StartsWith('<'))
        {
            return s;
        }

        var depth = 0;
        for (var i = 0; i < s.Length; i++)
        {
            if (s[i] == '<')
            {
                depth++;
            }
            else if (s[i] == '>')
            {
                depth--;
                if (depth == 0)
                {
                    return s[(i + 1)..].TrimStart();
                }
            }
        }

        return s;
    }

    /// <summary>Whether <paramref name="s"/> is a plain identifier (a bare class name in <c>Type()</c> initializer text).</summary>
    private static bool IsSimpleIdent(string s) =>
        s.Length > 0 && !char.IsDigit(s[0]) && s.All(c => char.IsLetterOrDigit(c) || c == '_');
}
