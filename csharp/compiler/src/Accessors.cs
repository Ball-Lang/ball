using System.Text;
using Ball.V1;

namespace Ball.Compiler;

/// <summary>
/// Property (getter/setter) emission — the C# answer to a shape every other
/// target gets from its host language for free.
///
/// <para>A Dart <c>get celsius</c> and its <c>set celsius(value)</c> carry the
/// <b>same Ball function name</b> (<c>main:Temperature.celsius</c>); only
/// <c>metadata.is_getter</c>/<c>is_setter</c> tells them apart. Dart and TS emit
/// native <c>get</c>/<c>set</c> members; C++ overloads on arity
/// (<c>celsius()</c> vs <c>celsius(v)</c> — see <c>cpp/compiler/src/compiler.cpp</c>'s
/// <c>class_getters_</c>/<c>class_setters_</c>). C# can do <em>neither</em>: every
/// impl method has the one signature <c>BallValue(BallValue)</c>, so the pair
/// collided on a single name (CS0111). The setter therefore takes the
/// <c>__set</c> impl suffix (<see cref="MemberImplName"/>).</para>
///
/// <para>Renaming the impl is only half of it — a property is never
/// <em>called</em>: the IR reaches it as a <c>field_access</c> (a read) or as an
/// <c>std.assign</c> whose target is a <c>field_access</c> (a write), exactly
/// like a plain field. Both lower to a call into the synthesized top-level
/// <c>BallAccessors</c> class, which dispatches on the receiver's run-time
/// <c>type_name</c> — resolving the property through the
/// <c>metadata.superclass</c> chain, so a subclass inherits it — and falls back
/// to <c>BallRuntime.FieldGet</c>/<c>FieldSet</c> for any receiver that is
/// <em>not</em> one of those classes (a map, a proto message, a core value).
/// That fallback is exactly what the compiler already emitted for every field
/// access, so routing a name some class exposes as a property is a strict
/// superset — never a silent change for other receivers.</para>
///
/// <para><c>BallAccessors</c> is top-level (like <c>BallOneofs</c>) rather than
/// per-module: a <c>field_access</c> carries no module, so one class is the only
/// place that can hold every owner of a given property name — including two
/// owners in different modules. Its members are therefore reached from every
/// emitted module class, which is why a getter/setter impl is emitted
/// <c>public</c> (assembly-scoped — the enclosing class is <c>internal</c>)
/// while a plain method impl stays <c>private</c>.</para>
/// </summary>
public sealed partial class CSharpCompiler
{
    /// <summary>Raw member names declared as an instance getter by some class (sorted, so emission is deterministic).</summary>
    private readonly SortedSet<string> _getterMembers = new(StringComparer.Ordinal);

    /// <summary>Raw member names declared as an instance setter by some class.</summary>
    private readonly SortedSet<string> _setterMembers = new(StringComparer.Ordinal);

    /// <summary>The module each user <see cref="TypeDefinition"/> was declared in (its members' impls are emitted into that module's class).</summary>
    private readonly Dictionary<string, string> _moduleByTypeShortName = new(StringComparer.Ordinal);

    /// <summary>The <see cref="TypeDefinition"/> whose method/constructor body is being compiled (for implicit-<c>this</c> property access), or <c>null</c>.</summary>
    private TypeDefinition? _currentOwnerTd;

    /// <summary>Record every instance getter/setter member name (called from the ctor, before any emission).</summary>
    private void IndexAccessors()
    {
        foreach (var (owner, members) in _classMembersByOwner)
        {
            // A member whose owner has no TypeDefinition gets no impl method
            // emitted (see CompileClassMembers), so it cannot be routed to.
            if (!_typeDefsByShortName.ContainsKey(Naming.TypeShortName(owner)))
            {
                continue;
            }

            foreach (var member in members)
            {
                if (!IsInstanceMethod(member) || Naming.SplitMemberName(member.Name) is not { } split)
                {
                    continue;
                }

                if (MetaBool(member.Metadata, "is_getter"))
                {
                    _getterMembers.Add(split.Member);
                }
                else if (MetaBool(member.Metadata, "is_setter"))
                {
                    _setterMembers.Add(split.Member);
                }
            }
        }
    }

    /// <summary>Whether <paramref name="member"/> is a non-static class method (the only shape a getter/setter takes).</summary>
    private static bool IsInstanceMethod(FunctionDefinition member) =>
        MetaString(member.Metadata, "kind") == "method" && !MetaBool(member.Metadata, "is_static");

    /// <summary>The <c>BallAccessors</c> method reading the property <paramref name="member"/> (keyword-unescaped — see <see cref="MemberImplName"/>).</summary>
    private static string AccessorGetName(string member) => $"Get__{Naming.Sanitize(member).TrimStart('@')}";

    /// <summary>The <c>BallAccessors</c> method writing the property <paramref name="member"/>.</summary>
    private static string AccessorSetName(string member) => $"Set__{Naming.Sanitize(member).TrimStart('@')}";

    /// <summary>The qualifier a call into module <paramref name="module"/>'s emitted class needs (always explicit — <c>BallAccessors</c> is in neither class).</summary>
    private string ModuleQualifier(string module) =>
        module == _entryModule ? "BallProgram." : $"{Naming.Sanitize(module)}.";

    /// <summary>
    /// The qualified impl method an instance of <paramref name="td"/> resolves
    /// the getter (or setter) <paramref name="member"/> to — the declaration
    /// found by walking <paramref name="td"/>'s <c>metadata.superclass</c> chain,
    /// so a subclass inherits its parent's property. <c>null</c> when no class in
    /// the chain declares it.
    /// </summary>
    private string? ResolveAccessorImpl(TypeDefinition td, string member, bool setter)
    {
        var current = td;
        for (var i = 0; i < 32; i++)
        {
            if (_classMembersByOwner.TryGetValue(current.Name, out var members))
            {
                foreach (var candidate in members)
                {
                    if (!IsInstanceMethod(candidate)
                        || Naming.SplitMemberName(candidate.Name) is not { } split
                        || split.Member != member
                        || !MetaBool(candidate.Metadata, setter ? "is_setter" : "is_getter"))
                    {
                        continue;
                    }

                    var ownerShort = Naming.TypeShortName(current.Name);
                    var module = _moduleByTypeShortName.TryGetValue(ownerShort, out var declaring)
                        ? declaring
                        : _entryModule;
                    return ModuleQualifier(module) + MemberImplName(ownerShort, member, setter);
                }
            }

            if (SuperclassOf(current) is not { } superName
                || !_typeDefsByShortName.TryGetValue(Naming.TypeShortName(superName), out var superTd))
            {
                return null;
            }

            current = superTd;
        }

        return null;
    }

    /// <summary>Every user type resolving the property <paramref name="member"/>, paired with the impl it resolves to (declaration order).</summary>
    private List<(TypeDefinition Td, string Impl)> AccessorTargets(string member, bool setter)
    {
        var targets = new List<(TypeDefinition, string)>();
        foreach (var module in _program.Modules)
        {
            if (_baseModules.Contains(module.Name))
            {
                continue;
            }

            foreach (var td in module.TypeDefs)
            {
                if (td.Descriptor_ is not null && ResolveAccessorImpl(td, member, setter) is { } impl)
                {
                    targets.Add((td, impl));
                }
            }
        }

        return targets;
    }

    /// <summary>Emit the top-level <c>BallAccessors</c> class (empty when the program declares no property).</summary>
    private string CompileAccessors()
    {
        if (_getterMembers.Count == 0 && _setterMembers.Count == 0)
        {
            return string.Empty;
        }

        var sb = new StringBuilder("\ninternal static class BallAccessors\n{\n");
        foreach (var member in _getterMembers)
        {
            sb.Append(CompileGetterAccessor(member));
        }

        foreach (var member in _setterMembers)
        {
            sb.Append(CompileSetterAccessor(member));
        }

        sb.Append("}\n");
        return sb.ToString();
    }

    /// <summary>A property read: invoke the resolved class's getter impl with <c>{self}</c>, else read the field.</summary>
    private string CompileGetterAccessor(string member)
    {
        var sb = new StringBuilder($"    public static BallValue {AccessorGetName(member)}(BallValue __obj)\n    {{\n");
        sb.Append("        var __t = BallRuntime.MessageTypeName(__obj);\n");
        foreach (var (td, impl) in AccessorTargets(member, setter: false))
        {
            sb.Append($"        if ({TypeNameTest(td)}) return {impl}(BallRuntime.WithSelf(BallValue.Null, __obj));\n");
        }

        sb.Append($"        return BallRuntime.FieldGet(__obj, {Naming.StringLiteral(member)});\n");
        sb.Append("    }\n");
        return sb.ToString();
    }

    /// <summary>
    /// A property write: invoke the resolved class's setter impl with
    /// <c>{self, arg0}</c>, else write the field. The assigned value is passed
    /// <b>positionally</b>, so the setter's single declared parameter binds
    /// whatever it is named (<c>value</c>, <c>d</c>, <c>f</c>, …) via the method
    /// prologue's <c>ArgGet(name, "arg0")</c> — issue #95, fixture
    /// <c>341_setter_param_binding</c>. A setter body yields null, but an
    /// assignment <em>expression</em> evaluates to the assigned value, so that is
    /// what is returned.
    /// </summary>
    private string CompileSetterAccessor(string member)
    {
        var sb = new StringBuilder($"    public static BallValue {AccessorSetName(member)}(BallValue __obj, BallValue __value)\n    {{\n");
        sb.Append("        var __t = BallRuntime.MessageTypeName(__obj);\n");
        foreach (var (td, impl) in AccessorTargets(member, setter: true))
        {
            sb.Append($"        if ({TypeNameTest(td)}) {{ {impl}(BallRuntime.Arg0WithSelf(__value, __obj)); return __value; }}\n");
        }

        sb.Append($"        return BallRuntime.FieldSet(__obj, {Naming.StringLiteral(member)}, __value);\n");
        sb.Append("    }\n");
        return sb.ToString();
    }

    /// <summary>The receiver-type test the accessors dispatch on — the full <c>module:Type</c> name or the short one (a message may carry either).</summary>
    private static string TypeNameTest(TypeDefinition td) =>
        $"__t == {Naming.StringLiteral(td.Name)} || __t == {Naming.StringLiteral(Naming.TypeShortName(td.Name))}";
}
