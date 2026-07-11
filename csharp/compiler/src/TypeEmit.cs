using System.Text;
using Ball.V1;
using Google.Protobuf.Reflection;
using Google.Protobuf.WellKnownTypes;

namespace Ball.Compiler;

/// <summary>
/// Type emission (issue #381, playbook Phase 2): <c>typeDefs[]</c> +
/// <c>Module.enums[]</c> → C# <c>class</c> / <c>abstract class</c> / an enum
/// namespace, with class members (methods/getters/setters via
/// <c>metadata.kind</c> + the <c>owner:Type.member</c> naming convention)
/// emitted as run-time-dispatched static methods.
///
/// <para>Like the Rust sibling (<c>rust/compiler/src/type_emit.rs</c>), the
/// <b>runtime representation stays dynamic</b>: an instance is a
/// <see cref="Ball.Shared.BallMessage"/> (a shared field map), so the emitted
/// C# <c>class</c> declaration is a faithful <em>shape</em> (fields as
/// properties) that documents the descriptor but is never itself instantiated
/// by generated code — <c>message_creation</c> always builds the dynamic
/// message. Method calls dispatch on the receiver's actual
/// <c>type_name</c> at run time (the C# analog of a dynamically-typed
/// engine's own dispatch), not via C#'s type system.</para>
///
/// <para><b>Scope (Phase 4):</b> enums run; concrete/abstract classes with
/// instance methods that read their fields run; constructors are the Dart
/// init-formal shape handled entirely by <see cref="CompileMessageCreation"/>
/// (a body-carrying constructor, static members, and <c>super</c> chains are
/// documented gaps for the self-host phase).</para>
/// </summary>
public sealed partial class CSharpCompiler
{
    /// <summary>
    /// The oneof-discriminator "enums" the Dart protobuf codegen synthesizes for
    /// each <c>oneof</c> (<c>Expression.expr</c> → <c>Expression_Expr</c>, …).
    /// They carry no <c>EnumDescriptorProto</c> in any <c>Module.enums[]</c>, so
    /// the normal type path never emits them — yet the engine's dispatch reads
    /// them (<c>whichExpr() == Expression_Expr.call</c>). Each member resolves to
    /// the case-name <b>string</b> the matching <c>ball_proto</c> discriminator
    /// returns, so a <c>field_access</c> <c>Expression_Expr.call</c> lowers to
    /// <c>FieldGet(BallOneofs.Expression_Expr, "call")</c> = <c>"call"</c>.
    /// Mirrors <c>rust/compiler/src/type_emit.rs</c>'s
    /// <c>ONEOF_DISCRIMINATOR_ENUMS</c> and the TS <c>preamble.ts</c> constants.
    /// </summary>
    private static readonly Dictionary<string, string[]> OneofDiscriminators = new(StringComparer.Ordinal)
    {
        ["Expression_Expr"] = new[] { "call", "literal", "reference", "fieldAccess", "messageCreation", "block", "lambda", "notSet" },
        ["Literal_Value"] = new[] { "intValue", "doubleValue", "stringValue", "boolValue", "bytesValue", "listValue", "notSet" },
        ["Statement_Stmt"] = new[] { "let", "expression", "notSet" },
        ["ModuleImport_Source"] = new[] { "http", "file", "git", "registry", "inline", "notSet" },
        // Keyed by the IR reference name (a dot the Dart protobuf codegen keeps —
        // `structpb.Value_Kind`); Naming.Sanitize maps it to the emitted C#
        // identifier `structpb_Value_Kind`.
        ["structpb.Value_Kind"] = new[] { "nullValue", "numberValue", "stringValue", "boolValue", "structValue", "listValue", "notSet" },
    };

    /// <summary>
    /// Emit the <see cref="OneofDiscriminators"/> namespace as a top-level
    /// static class <c>BallOneofs</c> whose members are the case-name strings, so
    /// every module's emitted code can read <c>BallOneofs.Expression_Expr</c>.
    /// </summary>
    private static string CompileOneofDiscriminators()
    {
        var sb = new StringBuilder();
        sb.Append("\ninternal static class BallOneofs\n{\n");
        foreach (var (enumName, members) in OneofDiscriminators)
        {
            var entries = string.Join(", ", members.Select(m => $"[{Naming.StringLiteral(m)}] = Str({Naming.StringLiteral(m)})"));
            sb.Append($"    public static readonly BallValue {Naming.Sanitize(enumName)} = (BallValue)new BallMessage({Naming.StringLiteral(enumName)}, new BallMap {{ {entries} }});\n");
        }

        sb.Append("}\n");
        return sb.ToString();
    }

    /// <summary>Emit every type declaration in <paramref name="module"/> plus its class-member methods.</summary>
    private string CompileModuleTypes(Module module)
    {
        var sb = new StringBuilder();

        foreach (var enumDef in module.Enums)
        {
            sb.Append(CompileEnum(enumDef));
            sb.Append('\n');
        }

        foreach (var td in module.TypeDefs)
        {
            // A cosmetic `kind: "enum"` TypeDefinition carries no descriptor
            // (its values live in Module.enums[]); skip it here.
            if (td.Descriptor_ is null)
            {
                continue;
            }

            sb.Append(CompileClass(td));
            sb.Append('\n');
        }

        sb.Append(CompileClassMembers(module));
        return sb.ToString();
    }

    /// <summary>
    /// A Ball enum's namespace — a <c>static readonly BallValue</c> field named
    /// by the enum's short name, holding a map of member name → a message
    /// tagged with the enum's type and carrying <c>index</c>/<c>name</c>, plus a
    /// <c>values</c> list in declaration order. Runs exactly (enum values are
    /// ordinary dynamic messages).
    /// </summary>
    private static string CompileEnum(EnumDescriptorProto enumDef)
    {
        var fullName = enumDef.Name ?? string.Empty;
        var shortName = Naming.Sanitize(Naming.TypeShortName(fullName));
        var sb = new StringBuilder();
        sb.Append($"    public static readonly BallValue {shortName} = BuildEnum_{shortName}();\n");
        sb.Append($"    private static BallValue BuildEnum_{shortName}()\n    {{\n");
        sb.Append("        var __ns = new BallMap();\n");
        sb.Append("        var __values = new BallList();\n");
        var index = 0;
        foreach (var value in enumDef.Value)
        {
            var memberName = value.Name ?? string.Empty;
            var ordinal = value.HasNumber ? value.Number : index;
            sb.Append($"        var __m{index} = (BallValue)new BallMessage({Naming.StringLiteral(fullName)}, new BallMap {{ [\"index\"] = Int({ordinal}L), [\"name\"] = Str({Naming.StringLiteral(memberName)}) }});\n");
            sb.Append($"        __ns[{Naming.StringLiteral(memberName)}] = __m{index};\n");
            sb.Append($"        __values.Add(__m{index});\n");
            index++;
        }

        sb.Append("        __ns[\"values\"] = (BallValue)__values;\n");
        sb.Append($"        return new BallMessage({Naming.StringLiteral(fullName)}, __ns);\n");
        sb.Append("    }\n");
        return sb.ToString();
    }

    /// <summary>A concrete or abstract class shape (a faithful field declaration; never instantiated by generated code).</summary>
    private string CompileClass(TypeDefinition td)
    {
        var name = Naming.Sanitize(Naming.TypeShortName(td.Name));
        var isAbstract = MetaBool(td.Metadata, "is_abstract");
        var keyword = isAbstract ? "abstract class" : "sealed class";
        var sb = new StringBuilder();
        sb.Append($"    // Ball type {td.Name} — runtime instances are dynamic BallMessages; this is the descriptor shape.\n");
        sb.Append($"    public {keyword} {name}\n    {{\n");
        if (td.Descriptor_ is not null)
        {
            foreach (var field in td.Descriptor_.Field)
            {
                if (string.IsNullOrEmpty(field.Name))
                {
                    continue;
                }

                sb.Append($"        public BallValue? {Naming.Sanitize(field.Name)} {{ get; set; }}\n");
            }
        }

        sb.Append("    }\n");
        return sb.ToString();
    }

    /// <summary>
    /// Emit every class member (instance method/getter/setter) of
    /// <paramref name="module"/> as an implementation method plus, per shared
    /// short name, one run-time dispatcher that routes on the receiver's
    /// <c>type_name</c>. Constructors are handled by
    /// <see cref="CompileMessageCreation"/> (init-formals) and skipped here.
    /// </summary>
    private string CompileClassMembers(Module module)
    {
        var impls = new StringBuilder();
        var dispatchTargets = new Dictionary<string, List<(string Owner, string Impl)>>(StringComparer.Ordinal);

        foreach (var (owner, members) in _classMembersByOwner)
        {
            if (!_typeDefsByShortName.TryGetValue(Naming.TypeShortName(owner), out var ownerTd)
                || !module.TypeDefs.Contains(ownerTd))
            {
                continue;
            }

            foreach (var member in members)
            {
                var kind = MetaString(member.Metadata, "kind");
                if (kind == "constructor")
                {
                    continue;
                }

                var split = Naming.SplitMemberName(member.Name);
                if (split is null)
                {
                    continue;
                }

                var shortMember = Naming.Sanitize(split.Value.Member);
                var ownerShort = Naming.Sanitize(Naming.TypeShortName(owner));
                var implName = $"{ownerShort}__{shortMember}";
                impls.Append(CompileMethodImpl(implName, ownerTd, member));
                impls.Append('\n');

                dispatchTargets.TryAdd(shortMember, new List<(string, string)>());
                dispatchTargets[shortMember].Add((owner, implName));
            }
        }

        var sb = new StringBuilder();
        foreach (var (shortMember, targets) in dispatchTargets)
        {
            sb.Append(CompileDispatcher(shortMember, targets));
            sb.Append('\n');
        }

        sb.Append(impls);
        return sb.ToString();
    }

    /// <summary>A run-time method dispatcher: routes on the receiver's <c>type_name</c> to the matching impl.</summary>
    private static string CompileDispatcher(string shortMember, List<(string Owner, string Impl)> targets)
    {
        var sb = new StringBuilder();
        sb.Append($"    public static BallValue {shortMember}(BallValue input)\n    {{\n");
        sb.Append("        var __self = BallRuntime.FieldGet(input, \"self\");\n");
        sb.Append("        var __t = BallRuntime.MessageTypeName(__self);\n");
        foreach (var (owner, impl) in targets)
        {
            var shortOwner = Naming.TypeShortName(owner);
            sb.Append($"        if (__t == {Naming.StringLiteral(owner)} || __t == {Naming.StringLiteral(shortOwner)}) return {impl}(input);\n");
        }

        sb.Append($"        throw new BallRuntimeException($\"no method '{shortMember}' for {{__t}}\");\n");
        sb.Append("    }\n");
        return sb.ToString();
    }

    /// <summary>
    /// A method implementation: binds the receiver (<c>self</c>) and each of
    /// the owner's fields as read aliases (so the body's bare field references
    /// resolve — Dart's implicit-<c>this</c> convention), plus the method's
    /// declared parameters, then compiles the body.
    /// </summary>
    private string CompileMethodImpl(string implName, TypeDefinition ownerTd, FunctionDefinition member)
    {
        var inName = PushInput();
        PushScope();
        var sb = new StringBuilder($"    private static BallValue {implName}(BallValue {inName})\n    {{\n");
        sb.Append($"        var self = BallRuntime.FieldGet({inName}, \"self\");\n");
        BindLocal("self");

        // A declared parameter shadows a same-named field inside the method body
        // (Dart semantics); C# forbids re-declaring the name, so skip the field
        // alias when a parameter (or the receiver `self`) already claims it.
        var paramNames = ParamNames(member);
        var shadowed = new HashSet<string>(paramNames, StringComparer.Ordinal) { "self" };

        if (ownerTd.Descriptor_ is not null)
        {
            foreach (var field in ownerTd.Descriptor_.Field)
            {
                if (string.IsNullOrEmpty(field.Name) || shadowed.Contains(field.Name))
                {
                    continue;
                }

                sb.Append($"        var {Naming.Sanitize(field.Name)} = BallRuntime.FieldGet(self, {Naming.StringLiteral(field.Name)});\n");
                BindLocal(field.Name);
            }
        }

        foreach (var param in paramNames)
        {
            if (param == "self")
            {
                continue;
            }

            sb.Append($"        var {Naming.Sanitize(param)} = BallRuntime.FieldGet({inName}, {Naming.StringLiteral(param)});\n");
            BindLocal(param);
        }

        if (member.Body is null)
        {
            sb.Append("        return BallValue.Null;\n");
        }
        else if (member.Body.ExprCase == Expression.ExprOneofCase.Block)
        {
            sb.Append(EmitBlockInner(member.Body.Block, isFunctionBody: true));
        }
        else
        {
            sb.Append($"        return {CompileExpression(member.Body)};\n");
        }

        sb.Append("    }\n");
        PopScope();
        return sb.ToString();
    }

    /// <summary>
    /// The constructor parameter names of the class <paramref name="typeName"/>
    /// refers to, in declaration order — used to remap a constructor call's
    /// positional <c>argN</c> fields to real field names. <c>null</c> when
    /// <paramref name="typeName"/> is empty or has no registered constructor.
    /// </summary>
    private List<string>? ConstructorParamNames(string typeName)
    {
        if (typeName.Length == 0)
        {
            return null;
        }

        var shortName = Naming.TypeShortName(typeName);
        foreach (var (owner, members) in _classMembersByOwner)
        {
            if (Naming.TypeShortName(owner) != shortName)
            {
                continue;
            }

            foreach (var member in members)
            {
                if (MetaString(member.Metadata, "kind") == "constructor")
                {
                    return ParamNames(member);
                }
            }
        }

        return null;
    }
}
