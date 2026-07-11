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
/// ## Construction is field-mapping only — no constructor **body** is ever interpreted
///
/// A C# constructor's body is NOT encoded or executed by this encoder — only its **parameter
/// list** is consulted (see <see cref="Encoder.CtorParams"/>), to map `new Foo(a, b)`'s
/// positional arguments onto field names by position. This mirrors
/// <c>rust/encoder/src/types.rs</c>'s own posture toward Rust's `Type::new(...)` associated
/// functions (a documented gap there for a different reason — no `self` receiver to dispatch
/// through) and every reference encoder's shared assumption that a plain field-value literal
/// (`Point { x: 3, y: 4 }`/`new Point(3, 4)`) needs no constructor interpretation at all. Only a
/// single user-declared constructor (or a C# 12 primary constructor) per class is supported —
/// see <see cref="Encoder.CollectDeclarations"/>'s "multiple constructors" check.
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
            if (member is MethodDeclarationSyntax method)
            {
                members.Add(EncodeMethodDeclaration(shortName, method));
            }
        }

        return (typeDef, members);
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

        Expression body;
        if (method.ExpressionBody is not null)
        {
            body = EncodeExpr(method.ExpressionBody.Expression);
        }
        else if (method.Body is not null)
        {
            body = EncodeStatementsAsBlock(method.Body.Statements);
        }
        else
        {
            throw new EncoderException(
                $"ball-encoder: method `{ownerShort}.{methodShort}` has no body " +
                "(abstract/partial/extern methods are a documented gap — issue #382's scope)");
        }

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
        if (args.Count > 0)
        {
            var ctorParams = CtorParams.TryGetValue(shortName, out var cp) ? cp : new List<string>();
            if (ctorParams.Count != args.Count)
            {
                throw new EncoderException(
                    $"ball-encoder: `new {typeText}(...)` passes {args.Count} positional " +
                    $"argument(s) but `{shortName}` " +
                    (ctorParams.Count == 0
                        ? "has no declared constructor"
                        : $"declares {ctorParams.Count} constructor parameter(s)") +
                    " — declare a single matching constructor (or primary constructor), or " +
                    "use an object initializer instead");
            }

            for (var i = 0; i < args.Count; i++)
            {
                fields.Add((ctorParams[i], EncodeExpr(args[i].Expression)));
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
