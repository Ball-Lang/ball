using System.Collections.Generic;
using System.Linq;
using Ball.V1;
using Google.Protobuf.Reflection;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

namespace Ball.Encoder;

/// <summary>
/// Type declarations (<c>class</c>/<c>struct</c>/<c>record</c>) → Ball <see cref="TypeDefinition"/>
/// + <see cref="DescriptorProto"/>; methods → <see cref="FunctionDefinition"/>s; object creation
/// (constructor call and/or object-initializer) → <see cref="MessageCreation"/>. Mirrors
/// <c>dart/encoder/lib/encoder.dart</c>'s class encoding (the reference implementation this
/// issue names) and <c>rust/encoder/src/types.rs</c>'s struct/impl split, adapted to C#'s single
/// <c>class</c>/<c>struct</c>/<c>record</c> declaration shape.
///
/// ## Construction is field-mapping only — a constructor body is RESOLVED, never interpreted
///
/// A C# constructor's body is not encoded or executed. It is reduced, at collection time, to a
/// <see cref="CtorShape"/>: the constructor's parameter names (which fix its arity) plus the
/// ordered list of fields it assigns, each sourced either from a parameter (by index) or from a
/// constant literal written in the body. See <see cref="Encoder.CollectDeclarations"/> and
/// <see cref="Encoder.CtorShapes"/>. Exactly two statement shapes are recognised —
/// <c>field = param;</c>/<c>this.field = param;</c> and <c>field = literal;</c> — and anything
/// else throws, naming the class and the offending statement.
///
/// <para><b>Why the field NAME, not the parameter name.</b> A method body reads instance state
/// through the class's own declared field names (<see cref="Encoder.ClassFields"/>, sourced
/// from <c>field</c>/auto-property declarations). Keying a construction's
/// <see cref="MessageCreation"/> by the constructor's PARAMETER names instead — which this
/// encoder did before issue #492's slice B — agrees with that only when the two happen to
/// match (a primary constructor, or an object initializer). For the ordinary
/// <c>private int _x; public Point(int x) { _x = x; }</c> idiom they differ, and the result was
/// silent wrong output: verified on the Dart reference engine, a `Sum()` reading `_x`/`_y` off a
/// message carrying `x`/`y` printed <c>0</c> instead of <c>3</c>. Resolving the body's
/// assignments is what makes "field mapping only" actually TRUE rather than assumed.</para>
///
/// <para><b>Selecting among several constructors.</b> A call site picks the
/// <see cref="CtorShape"/> whose parameter count equals its argument count. Two constructors of
/// the SAME arity are a documented scope limit — a syntax-only encoder has no semantic model to
/// type-match arguments — and are rejected loudly at collection time.</para>
///
/// <para>Rust's sibling encoder reaches the same construction shape from the other side: since
/// issue #491 it maps a receiver-less <c>Type::new(...)</c> associated function onto a
/// <c>metadata.is_static</c> class member, and Rust's own struct-literal syntax needs no
/// constructor at all. Both end at a plain <c>message_creation</c> keyed by real field names.</para>
///
/// ## Bodyless members are omitted, never thrown on
///
/// An interface method or an <c>abstract</c>/<c>partial</c>/<c>extern</c> declaration is a
/// signature with nothing to encode, so <see cref="EncodeTypeDeclaration"/> simply skips it
/// (issue #492, buckets b and g). Emitting it as an <c>IsBase = true</c> member instead would
/// be worse than useless: <c>CSharpCompiler</c>'s class-member registration loop (which
/// populates <c>_classMembersByOwner</c>, consumed by <c>TypeEmit.cs</c>'s
/// <c>CompileClassMembers</c>/<c>CompileMethodImpl</c>) has its own
/// <c>if (func.IsBase) { continue; }</c> guard evaluated BEFORE the dotted-name split, so such a
/// member would vanish from the compiled class with no diagnostic at all. Nothing is lost by
/// omitting it — Ball dispatch resolves by the receiver's concrete runtime <c>type_name</c>,
/// never by the declaring interface/abstract type, so the member is unreachable at run time.
///
/// ## Instance-method dispatch convention (verified against the reference engine)
///
/// An instance method compiles to a <see cref="FunctionDefinition"/> named
/// <c>"main:Owner.Method"</c> — <c>dart/engine/lib/engine.dart</c>'s
/// <c>_registerFunctionDispatchTables</c> splits a function name on its LAST <c>.</c> to build
/// the (type, method) → function dispatch table, resolved at a call site by the receiver's
/// *runtime* type (the <c>message_creation</c>'s <c>type_name</c>), not by any static type
/// information this syntax-only encoder lacks. A call site packs the receiver under a literal
/// <c>"self"</c> field (see <see cref="Builders.SelfFieldAccess"/>'s doc comment for why the
/// engine treats that key specially and unconditionally).
///
/// A static method has no receiver to dispatch through, so it compiles to a plain top-level
/// function instead — named <c>"Owner_Method"</c> (see <see cref="StaticFunctionName"/>) to
/// avoid colliding with an unrelated top-level/other-class member of the same short name,
/// EXCEPT a method literally named <c>Main</c>, which is always the bare entry-point name
/// <c>"Main"</c> regardless of which class declares it (every reference encoder treats the
/// entry point specially).
/// </summary>
internal sealed partial class Encoder
{
    private const string ModulePrefix = "main";

    /// <summary><c>"Point"</c> → <c>"main:Point"</c> — mirrors
    /// <c>dart/encoder/lib/encoder.dart</c>'s own <c>"$moduleName:$className"</c> convention
    /// (this encoder always encodes one whole file into a single module named
    /// <c>"main"</c>).</summary>
    internal static string QualifiedTypeName(string shortName) => $"{ModulePrefix}:{shortName}";

    /// <summary>A static (non-<c>Main</c>) method's top-level Ball function name — see the
    /// module doc comment.</summary>
    internal static string StaticFunctionName(string ownerShort, string methodShort) =>
        $"{ownerShort}_{methodShort}";

    // ════════════════════════════════════════════════════════════
    // class / struct / record
    // ════════════════════════════════════════════════════════════

    internal (TypeDefinition TypeDef, List<FunctionDefinition> Members) EncodeTypeDeclaration(TypeDeclarationSyntax decl)
    {
        var shortName = decl.Identifier.Text;
        var qualified = QualifiedTypeName(shortName);

        var descriptor = new DescriptorProto { Name = qualified };
        var fieldsMeta = new List<Google.Protobuf.WellKnownTypes.Value>();
        var fieldNumber = 1;

        if (decl.ParameterList is not null)
        {
            foreach (var param in decl.ParameterList.Parameters)
            {
                var fieldName = param.Identifier.Text;
                var typeText = param.Type?.ToString() ?? "";
                descriptor.Field.Add(FieldDescriptorFor(fieldName, fieldNumber++, typeText));
                fieldsMeta.Add(Builders.StructValue(("name", Builders.StrValue(fieldName)), ("type", Builders.StrValue(typeText))));
            }
        }

        foreach (var member in decl.Members)
        {
            switch (member)
            {
                case FieldDeclarationSyntax field when !field.Modifiers.Any(SyntaxKind.StaticKeyword):
                    var fieldTypeText = field.Declaration.Type.ToString();
                    foreach (var variable in field.Declaration.Variables)
                    {
                        var fieldName = variable.Identifier.Text;
                        descriptor.Field.Add(FieldDescriptorFor(fieldName, fieldNumber++, fieldTypeText));
                        fieldsMeta.Add(Builders.StructValue(("name", Builders.StrValue(fieldName)), ("type", Builders.StrValue(fieldTypeText))));
                    }

                    break;
                case PropertyDeclarationSyntax prop when !prop.Modifiers.Any(SyntaxKind.StaticKeyword) && IsAutoProperty(prop):
                    var propTypeText = prop.Type.ToString();
                    descriptor.Field.Add(FieldDescriptorFor(prop.Identifier.Text, fieldNumber++, propTypeText));
                    fieldsMeta.Add(Builders.StructValue(("name", Builders.StrValue(prop.Identifier.Text)), ("type", Builders.StrValue(propTypeText))));
                    break;
            }
        }

        var meta = new MetaBuilder();
        meta.SetString("kind", decl switch
        {
            RecordDeclarationSyntax => "record",
            StructDeclarationSyntax => "struct",
            _ => "class",
        });
        meta.SetBoolIfTrue("is_public", decl.Modifiers.Any(SyntaxKind.PublicKeyword));
        meta.SetListIfNonempty("fields", fieldsMeta);
        if (decl.BaseList is not null)
        {
            meta.SetListIfNonempty(
                "interfaces",
                decl.BaseList.Types.Select(t => Builders.StrValue(t.Type.ToString())).ToList());
        }

        var typeDef = new TypeDefinition
        {
            Name = qualified,
            Descriptor_ = descriptor,
            Description = $"Class metadata for {qualified}",
            Metadata = meta.Build(),
        };

        var members = new List<FunctionDefinition>();
        foreach (var member in decl.Members)
        {
            // A member with neither a block body nor an expression body is a signature only —
            // an interface method, an `abstract`/`partial`/`extern` declaration. There is
            // nothing to encode, so it is OMITTED rather than encoded or thrown on (issue
            // #492, taxonomy buckets b and g). See the module doc comment's "Bodyless members
            // are omitted" section for why omission beats emitting an `is_base` member.
            if (member is MethodDeclarationSyntax { Body: null, ExpressionBody: null })
            {
                continue;
            }

            if (member is MethodDeclarationSyntax method)
            {
                members.Add(EncodeMethodDeclaration(shortName, method));
            }
        }

        return (typeDef, members);
    }

    // ════════════════════════════════════════════════════════════
    // enum
    // ════════════════════════════════════════════════════════════

    /// <summary>
    /// <c>enum Color { Red, Green, Blue }</c> → an <see cref="EnumDescriptorProto"/> for
    /// <c>Module.Enums[]</c> plus a companion, <b>descriptor-less</b>
    /// <see cref="TypeDefinition"/> tagged <c>metadata.kind = "enum"</c> (issue #492, slice C).
    ///
    /// <para>The shape is not invented here — it is the convention
    /// <c>rust/encoder/src/types.rs</c>'s <c>encode_item_enum</c> and
    /// <c>dart/encoder/lib/encoder.dart</c> already emit, and the one
    /// <c>csharp/compiler/src/TypeEmit.cs</c>'s <c>CompileEnum</c> already consumes: the real
    /// value/number data lives in the <see cref="EnumDescriptorProto"/>, while the
    /// <see cref="TypeDefinition"/> carries only cosmetic metadata and deliberately no
    /// descriptor (which is exactly how <c>CompileModuleTypes</c> knows not to re-emit it as a
    /// class). Two encoders that disagree here would only surface the divergence much later, as
    /// a round-trip mismatch.</para>
    ///
    /// <para><b>Member numbering follows C#, not position.</b> A member with an explicit
    /// <c>= N</c> takes N, and every member after it continues from N + 1 — so
    /// <c>{ Red, Green = 5, Blue }</c> is 0/5/6, not 0/5/2.</para>
    /// </summary>
    internal (TypeDefinition TypeDef, EnumDescriptorProto EnumDef) EncodeEnumDeclaration(EnumDeclarationSyntax decl)
    {
        var shortName = decl.Identifier.Text;
        var qualified = QualifiedTypeName(shortName);

        var values = new List<EnumValueDescriptorProto>();
        var valuesMeta = new List<Google.Protobuf.WellKnownTypes.Value>();
        var next = 0;
        foreach (var member in decl.Members)
        {
            var memberName = member.Identifier.Text;
            if (member.EqualsValue is not null)
            {
                next = ConstantMemberValue(shortName, memberName, member.EqualsValue.Value);
            }

            values.Add(new EnumValueDescriptorProto { Name = memberName, Number = next });
            valuesMeta.Add(Builders.StructValue(("name", Builders.StrValue(memberName))));
            next++;
        }

        var meta = new MetaBuilder();
        meta.SetString("kind", "enum");
        meta.SetBoolIfTrue("is_public", decl.Modifiers.Any(SyntaxKind.PublicKeyword));
        meta.SetListIfNonempty("values", valuesMeta);

        var typeDef = new TypeDefinition
        {
            Name = qualified,
            Description = $"Enum metadata for {qualified}",
            Metadata = meta.Build(),
        };

        var enumDef = new EnumDescriptorProto { Name = qualified };
        enumDef.Value.AddRange(values);
        return (typeDef, enumDef);
    }

    /// <summary>
    /// An enum member's explicit discriminant, which must be an integer literal (optionally
    /// negated). A computed constant expression (<c>1 &lt;&lt; 2</c>, <c>Read | Write</c>) needs
    /// a constant evaluator this syntax-only encoder does not have, so it fails loud naming the
    /// member rather than guessing an ordinal — a NARROW, documented gap, unlike the blanket
    /// "enums are unsupported" this slice replaced.
    /// </summary>
    private static int ConstantMemberValue(string enumShort, string memberName, ExpressionSyntax value)
    {
        var (literal, negate) = value switch
        {
            LiteralExpressionSyntax lit => (lit, false),
            PrefixUnaryExpressionSyntax { Operand: LiteralExpressionSyntax operand } unary
                when unary.IsKind(SyntaxKind.UnaryMinusExpression) => (operand, true),
            _ => (null, false),
        };

        if (literal is null || literal.Token.Value is not int and not long)
        {
            throw new EncoderException(
                $"ball-encoder: enum `{enumShort}` member `{memberName}` has a computed value " +
                $"`{value}` — only an integer literal discriminant is supported (a syntax-only " +
                "encoder has no constant evaluator)");
        }

        var magnitude = Convert.ToInt64(literal.Token.Value, System.Globalization.CultureInfo.InvariantCulture);
        var signed = negate ? -magnitude : magnitude;
        if (signed is < int.MinValue or > int.MaxValue)
        {
            throw new EncoderException(
                $"ball-encoder: enum `{enumShort}` member `{memberName}` value `{signed}` does " +
                "not fit in the 32-bit `EnumValueDescriptorProto.number` field");
        }

        return (int)signed;
    }

    private FunctionDefinition EncodeMethodDeclaration(string ownerShort, MethodDeclarationSyntax method)
    {
        var methodShort = method.Identifier.Text;
        var isStatic = method.Modifiers.Any(SyntaxKind.StaticKeyword);
        var isMainEntry = isStatic && methodShort == "Main";
        var paramNames = method.ParameterList.Parameters.Select(p => p.Identifier.Text).ToList();

        var previousOwner = _currentInstanceOwner;
        var previousOwnerShort = _currentOwnerShort;
        _currentInstanceOwner = isStatic ? null : ownerShort;
        _currentOwnerShort = ownerShort;
        PushScope(paramNames);

        // A bodyless member never reaches here — `EncodeTypeDeclaration` omits it (issue
        // #492, buckets b/g). The `ExpressionBody`-first order matters: an expression-bodied
        // method (`double Area() => 1.0;`) has a null `Body`.
        Expression body = method.ExpressionBody is not null
            ? EncodeExpr(method.ExpressionBody.Expression)
            : EncodeStatementsAsBlock(method.Body!.Statements);

        PopScope();
        _currentInstanceOwner = previousOwner;
        _currentOwnerShort = previousOwnerShort;

        var meta = new MetaBuilder();
        meta.SetString("kind", "method");
        meta.SetBoolIfTrue("is_static", isStatic);
        meta.SetBoolIfTrue("is_public", method.Modifiers.Any(SyntaxKind.PublicKeyword));
        meta.SetBoolIfTrue("is_async", method.Modifiers.Any(SyntaxKind.AsyncKeyword));

        var name = isMainEntry
            ? "Main"
            : isStatic
                ? StaticFunctionName(ownerShort, methodShort)
                : $"{QualifiedTypeName(ownerShort)}.{methodShort}";

        // For an instance method, `metadata.params` lists only the method's own (non-`self`)
        // parameters — the engine binds `self` unconditionally and separately (see the module
        // doc comment). For a static method (a plain top-level function), list every parameter.
        var paramsMeta = paramNames.Count > 0 ? Builders.ParamsMetadata(paramNames) : null;
        var metadata = Builders.MergeStruct(paramsMeta, meta.Build());

        return new FunctionDefinition
        {
            Name = name,
            InputType = paramNames.Count == 1 ? (method.ParameterList.Parameters[0].Type?.ToString() ?? "") : "",
            OutputType = method.ReturnType.ToString() is "void" or "" ? "" : method.ReturnType.ToString(),
            Body = body,
            IsBase = false,
            Metadata = metadata,
        };
    }

    // ════════════════════════════════════════════════════════════
    // Object creation
    // ════════════════════════════════════════════════════════════

    private static readonly HashSet<string> ListLikeTypeNames = new()
    {
        "List", "IList", "IEnumerable", "ICollection", "HashSet", "ISet", "Queue", "Stack", "LinkedList",
    };

    private static readonly HashSet<string> MapLikeTypeNames = new() { "Dictionary", "IDictionary", "SortedDictionary" };

    internal Expression EncodeObjectCreation(ObjectCreationExpressionSyntax objCreate)
    {
        var typeText = objCreate.Type.ToString();
        var shortName = SimpleTypeName(typeText);

        if (ListLikeTypeNames.Contains(shortName))
        {
            return objCreate.Initializer is null
                ? Builders.ListLiteralExpr(Enumerable.Empty<Expression>())
                : Builders.ListLiteralExpr(objCreate.Initializer.Expressions.Select(EncodeExpr));
        }

        if (MapLikeTypeNames.Contains(shortName))
        {
            return EncodeDictionaryConstruction(objCreate);
        }

        if (!ClassNames.TryGetValue(shortName, out var qualified))
        {
            if (shortName.EndsWith("Exception", System.StringComparison.Ordinal))
            {
                return EncodeExceptionConstruction(objCreate);
            }

            throw new EncoderException(
                $"ball-encoder: `new {typeText}(...)` targets an unknown type `{shortName}` " +
                "(only a same-file class/struct/record declaration, `List<T>`/`Dictionary<K,V>` " +
                "collection construction, or a `*Exception(message)` BCL-style exception " +
                "construction, is supported)");
        }

        var fields = new List<(string Name, Expression Value)>();
        var args = objCreate.ArgumentList?.Arguments ?? default;
        var shapes = CtorShapes.TryGetValue(shortName, out var declared) ? declared : new List<CtorShape>();

        // A 0-argument `new Foo()` on a class that declares no constructor at all stays on the
        // pre-existing object-initializer-only path (no constructor to select, nothing to
        // report) — exactly as before.
        if (args.Count > 0 || shapes.Count > 0)
        {
            // Arity selects the constructor. `CollectDeclarations` already rejected same-arity
            // overloads, so at most one shape can match.
            var shape = shapes.FirstOrDefault(s => s.ParamNames.Count == args.Count);
            if (shape is null)
            {
                throw new EncoderException(
                    $"ball-encoder: `new {typeText}(...)` passes {args.Count} positional " +
                    $"argument(s) but `{shortName}` " +
                    (shapes.Count == 0
                        ? "has no declared constructor"
                        : "declares constructor(s) taking " +
                          string.Join(", ", shapes.Select(s => s.ParamNames.Count).OrderBy(n => n)) +
                          " argument(s)") +
                    " — declare a matching constructor (or primary constructor), or use an " +
                    "object initializer instead");
            }

            // Every field the selected constructor assigns, keyed by the class's own DECLARED
            // FIELD NAME — never the constructor's parameter name. Those two agree only for a
            // primary constructor; for the ordinary `private int _x; Point(int x){ _x = x; }`
            // idiom they differ, and keying by the parameter name silently built a message
            // whose fields no method body could read (issue #492).
            foreach (var (field, paramIndex, literal) in shape.Assignments)
            {
                fields.Add((
                    field,
                    paramIndex >= 0 ? EncodeExpr(args[paramIndex].Expression) : EncodeExpr(literal!)));
            }
        }

        if (objCreate.Initializer is not null)
        {
            fields.AddRange(EncodeObjectInitializerFields(objCreate.Initializer));
        }

        return Builders.NamedMessage(qualified, fields.ToArray());
    }

    /// <summary>A `*Exception`-named type with no same-file class declaration — assumed to be
    /// a BCL exception (<c>System.Exception</c>, <c>ArgumentException</c>, ...). Ball's
    /// <c>throw</c>/<c>try</c>/<c>catch</c> model is value-based (see
    /// <c>Ball.Shared.StdModuleBuilders</c>'s <c>throw</c>/<c>TryInput</c>/<c>CatchClause</c>
    /// shapes — no exception TYPE hierarchy is required), so a full BCL exception-type model
    /// isn't needed to support the common <c>throw new FooException("message")</c> /
    /// <c>catch (Exception e) { ... e.Message ... }</c> idiom: this maps directly to an
    /// anonymous message carrying a <c>Message</c> field, so <c>e.Message</c> resolves via
    /// ordinary <c>field_access</c> with no TypeDefinition needed at all.</summary>
    private Expression EncodeExceptionConstruction(ObjectCreationExpressionSyntax objCreate)
    {
        var args = objCreate.ArgumentList?.Arguments ?? default;
        var message = args.Count switch
        {
            0 => Builders.StringLiteral(""),
            1 => EncodeExpr(args[0].Expression),
            _ => throw new EncoderException(
                $"ball-encoder: `new {objCreate.Type}(...)` with {args.Count} arguments is not " +
                "supported (only a zero- or one-argument `*Exception(message)` construction is)"),
        };
        return Builders.NamedMessage(SimpleTypeName(objCreate.Type.ToString()), ("Message", message));
    }

    /// <summary>Ball has no native map literal (<c>Literal.value</c>'s oneof only covers
    /// int/double/string/bool/bytes/list — see <c>proto/ball/v1/ball.proto</c>), so a
    /// <c>Dictionary&lt;K,V&gt;</c> construction routes through <c>std_collections</c>'
    /// <c>map_from_entries</c> instead — the same "list of <c>{key, value}</c>" convention
    /// <c>map_entries</c> produces (see <c>dart/engine/lib/engine_std.dart</c>'s
    /// <c>map_from_entries</c>/<c>map_entries</c> implementations, which are exact inverses).
    /// Handles both initializer shorthands: <c>{ "a", 1 }</c> (an implicit <c>Add(key,
    /// value)</c> pair) and <c>["a"] = 1</c> (an indexer initializer).</summary>
    private Expression EncodeDictionaryConstruction(ObjectCreationExpressionSyntax objCreate)
    {
        MarkCollectionsUsed();
        var entries = new List<Expression>();
        if (objCreate.Initializer is not null)
        {
            foreach (var entryExpr in objCreate.Initializer.Expressions)
            {
                switch (entryExpr)
                {
                    case InitializerExpressionSyntax pair when pair.Expressions.Count == 2:
                        entries.Add(Builders.ArgsMessage(
                            ("key", EncodeExpr(pair.Expressions[0])),
                            ("value", EncodeExpr(pair.Expressions[1]))));
                        break;
                    case AssignmentExpressionSyntax assign when assign.Left is ImplicitElementAccessSyntax indexInit
                        && indexInit.ArgumentList.Arguments.Count == 1:
                        entries.Add(Builders.ArgsMessage(
                            ("key", EncodeExpr(indexInit.ArgumentList.Arguments[0].Expression)),
                            ("value", EncodeExpr(assign.Right))));
                        break;
                    default:
                        throw new EncoderException(
                            $"ball-encoder: unsupported dictionary initializer entry `{entryExpr}` " +
                            "(only `{ key, value }` and `[key] = value` are supported)");
                }
            }
        }

        return Builders.CollectionsCall("map_from_entries", Builders.ArgsMessage(("list", Builders.ListLiteralExpr(entries))));
    }

    internal Expression EncodeImplicitObjectCreation(ImplicitObjectCreationExpressionSyntax _) =>
        throw new EncoderException(
            "ball-encoder: target-typed `new(...)` is not supported — this is a syntax-only " +
            "encoder with no semantic model to resolve the implied type; write `new Foo(...)` " +
            "explicitly (issue #382's scope)");

    internal Expression EncodeArrayCreation(ArrayCreationExpressionSyntax arrayCreate)
    {
        if (arrayCreate.Initializer is not null)
        {
            return Builders.ListLiteralExpr(arrayCreate.Initializer.Expressions.Select(EncodeExpr));
        }

        throw new EncoderException(
            "ball-encoder: `new T[size]` without an initializer is not supported (issue #382's " +
            "scope) — use a collection initializer (`new int[] { ... }`) or `std_collections`");
    }

    private List<(string Name, Expression Value)> EncodeObjectInitializerFields(InitializerExpressionSyntax initializer)
    {
        var fields = new List<(string Name, Expression Value)>();
        foreach (var entry in initializer.Expressions)
        {
            if (entry is not AssignmentExpressionSyntax assign || assign.Left is not IdentifierNameSyntax fieldId)
            {
                throw new EncoderException(
                    $"ball-encoder: unsupported object-initializer entry `{entry}` (only " +
                    "`Field = value` is supported)");
            }

            fields.Add((fieldId.Identifier.Text, EncodeExpr(assign.Right)));
        }

        return fields;
    }

    private static string SimpleTypeName(string typeText)
    {
        var name = typeText.TrimEnd('?');
        var lastDot = name.LastIndexOf('.');
        if (lastDot >= 0)
        {
            name = name[(lastDot + 1)..];
        }

        var angle = name.IndexOf('<');
        if (angle >= 0)
        {
            name = name[..angle];
        }

        return name;
    }

    // ════════════════════════════════════════════════════════════
    // C# type text → protobuf FieldDescriptorProto (best-effort, cosmetic — see
    // rust/encoder/src/types.rs::rust_type_to_proto's identical posture: the struct's
    // *field names* are semantically load-bearing, the declared scalar type is documentation
    // only, since every instance stays a dynamic message regardless).
    // ════════════════════════════════════════════════════════════

    private static FieldDescriptorProto FieldDescriptorFor(string name, int number, string typeText)
    {
        var (protoType, repeated) = CSharpTypeToProto(typeText);
        var field = new FieldDescriptorProto
        {
            Name = name,
            Number = number,
            Label = repeated ? FieldDescriptorProto.Types.Label.Repeated : FieldDescriptorProto.Types.Label.Optional,
        };
        if (protoType is not null)
        {
            field.Type = protoType.Value;
        }

        return field;
    }

    private static (FieldDescriptorProto.Types.Type? Type, bool Repeated) CSharpTypeToProto(string typeText)
    {
        var text = typeText.TrimEnd('?').Trim();
        if (text.EndsWith("[]", System.StringComparison.Ordinal))
        {
            var (inner, _) = CSharpTypeToProto(text[..^2]);
            return (inner, true);
        }

        if (text.StartsWith("List<", System.StringComparison.Ordinal) && text.EndsWith('>'))
        {
            var (inner, _) = CSharpTypeToProto(text[5..^1]);
            return (inner, true);
        }

        var scalar = text switch
        {
            "int" => FieldDescriptorProto.Types.Type.Int32,
            "long" => FieldDescriptorProto.Types.Type.Int64,
            "uint" => FieldDescriptorProto.Types.Type.Uint32,
            "ulong" => FieldDescriptorProto.Types.Type.Uint64,
            "double" => FieldDescriptorProto.Types.Type.Double,
            "float" => FieldDescriptorProto.Types.Type.Float,
            "bool" => FieldDescriptorProto.Types.Type.Bool,
            "string" => FieldDescriptorProto.Types.Type.String,
            "byte[]" => FieldDescriptorProto.Types.Type.Bytes,
            _ => (FieldDescriptorProto.Types.Type?)null,
        };
        return (scalar, false);
    }
}
