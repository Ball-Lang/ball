using Ball.V1;
using Google.Protobuf.Reflection;
using Google.Protobuf.WellKnownTypes;
using BallV1Program = Ball.V1.Program;

namespace Ball.Compiler.Tests;

/// <summary>
/// Accessor-dispatch edge cases the conformance corpus structurally cannot
/// reach (issue #461).
///
/// <para>Both shapes here are hand-built Ball IR, not fixtures, because the
/// corpus is generated from <c>tests/conformance/src/*.dart</c> sources that
/// must first run under <c>dart run</c>: assigning to a getter-only property is
/// a <em>Dart compile-time error</em>, so no generated fixture can ever carry
/// that IR. Valid Ball IR is a strict superset of what any encoder emits, and
/// these two shapes live in the gap.</para>
///
/// <para>The <c>BallAccessors</c> dispatch table (see <c>Accessors.cs</c>) is a
/// C#-only emulation layer — C# cannot overload <c>get</c>/<c>set</c> on one
/// name (CS0111) — so its resolution rules have no cross-language safety net
/// and need direct tests.</para>
/// </summary>
public class AccessorEdgeCaseTests
{
    /// <summary>
    /// Writing a property that some class exposes as a getter with <b>no</b>
    /// setter must fail loud on that class's instances. Before the fix the write
    /// lowered to an unconditional <c>BallRuntime.FieldSet</c> — a silent field
    /// graft that compiled, ran and exited 0 while the getter kept returning its
    /// own value.
    /// </summary>
    [Fact]
    public void AssignToGetterOnlyProperty_FailsLoud()
    {
        var source = CSharpCompiler.Compile(GetterOnlyAssignmentProgram());

        var ex = Assert.Throws<InvalidOperationException>(() => CSharpRunner.Run(source));
        Assert.Contains("x", ex.Message, StringComparison.Ordinal);
        Assert.Contains("main:A", ex.Message, StringComparison.Ordinal);
    }

    /// <summary>
    /// A class that declares its own plain field must shadow a superclass getter
    /// of the same name (ordinary Dart/OOP override semantics). Before the fix
    /// <c>ResolveAccessorImpl</c> walked straight past the subclass's own
    /// descriptor fields to the superclass accessor, so the field was
    /// permanently unreadable and this printed <c>1</c>.
    /// </summary>
    [Fact]
    public void SubclassFieldShadowsSuperclassGetter_ReadsOwnField()
    {
        var source = CSharpCompiler.Compile(SubclassShadowProgram(subclassDeclaresOwnField: true));

        Assert.Equal("99\n", CSharpRunner.Run(source));
    }

    /// <summary>
    /// The correct case must not change: a subclass that <em>inherits</em> (does
    /// not redeclare) a superclass property still dispatches to the superclass
    /// impl. This is the regression guard on the own-field shadow check.
    /// </summary>
    [Fact]
    public void SubclassInheritingGetter_StillDispatchesToSuperclassImpl()
    {
        var source = CSharpCompiler.Compile(SubclassShadowProgram(subclassDeclaresOwnField: false));

        Assert.Equal("1\n", CSharpRunner.Run(source));
    }

    /// <summary>
    /// <c>_getterMembers</c> is a <b>global</b> name set, so the fail-loud write
    /// must be gated per receiver type: an unrelated class carrying a plain field
    /// that merely shares a name with some other class's getter-only property is
    /// still written (and read back) normally. A naive "throw whenever the name
    /// is a getter" would break every currently-passing program with a field
    /// called <c>x</c>/<c>value</c>/<c>name</c>.
    /// </summary>
    [Fact]
    public void AssignToUnrelatedTypeFieldSharingGetterName_StillWrites()
    {
        var source = CSharpCompiler.Compile(UnrelatedFieldAssignmentProgram());

        Assert.Equal("5\n", CSharpRunner.Run(source));
    }

    // ════════════════════════════════════════════════════════════
    // IR builders
    // ════════════════════════════════════════════════════════════

    /// <summary><c>class A { int get x =&gt; 1; }</c> plus <c>main() { A().x = 5; print("done"); }</c>.</summary>
    private static BallV1Program GetterOnlyAssignmentProgram()
    {
        var main = Ast.Block(
        [
            Ast.Expr(Assign(FieldAccess(New("main:A"), "x"), Ast.Int(5))),
            Ast.Expr(Ast.Print(Ast.Str("done"))),
        ]);

        var program = Ast.Program(main, Getter("main:A.x", Ast.Int(1)));
        MainModule(program).TypeDefs.Add(ClassTd("main:A"));
        return program;
    }

    /// <summary>
    /// <c>class A { int get x =&gt; 1; } class B extends A { … }</c> plus
    /// <c>main() { print(B(x: 99).x); }</c>. When
    /// <paramref name="subclassDeclaresOwnField"/> is set, <c>B</c>'s descriptor
    /// declares its own <c>x</c> field (the shadowing shape); otherwise <c>B</c>
    /// purely inherits <c>A</c>'s getter.
    /// </summary>
    private static BallV1Program SubclassShadowProgram(bool subclassDeclaresOwnField)
    {
        var receiver = subclassDeclaresOwnField
            ? New("main:B", ("x", Ast.Int(99)))
            : New("main:B");
        var main = Ast.Block([Ast.Expr(Ast.Print(FieldAccess(receiver, "x")))]);

        var program = Ast.Program(main, Getter("main:A.x", Ast.Int(1)));
        var module = MainModule(program);
        module.TypeDefs.Add(ClassTd("main:A"));
        module.TypeDefs.Add(subclassDeclaresOwnField
            ? ClassTd("main:B", superclass: "A", fields: ["x"])
            : ClassTd("main:B", superclass: "A"));
        return program;
    }

    /// <summary>
    /// <c>class A { int get x =&gt; 1; } class C { int x; }</c> plus
    /// <c>main() { final c = C(x: 0); c.x = 5; print(c.x); }</c> — <c>C</c> has no
    /// relationship to <c>A</c> and must keep plain field semantics.
    /// </summary>
    private static BallV1Program UnrelatedFieldAssignmentProgram()
    {
        var main = Ast.Block(
        [
            Ast.Let("c", New("main:C", ("x", Ast.Int(0)))),
            Ast.Expr(Assign(FieldAccess(Ast.Ref("c"), "x"), Ast.Int(5))),
            Ast.Expr(Ast.Print(FieldAccess(Ast.Ref("c"), "x"))),
        ]);

        var program = Ast.Program(main, Getter("main:A.x", Ast.Int(1)));
        var module = MainModule(program);
        module.TypeDefs.Add(ClassTd("main:A"));
        module.TypeDefs.Add(ClassTd("main:C", fields: ["x"]));
        return program;
    }

    private static Module MainModule(BallV1Program program) =>
        program.Modules.First(m => m.Name == "main");

    /// <summary>An instance getter member (<c>metadata.is_getter</c>), the only shape a property read resolves through.</summary>
    private static FunctionDefinition Getter(string name, Expression body) => new()
    {
        Name = name,
        OutputType = "int",
        Body = body,
        Metadata = new Struct
        {
            Fields =
            {
                ["kind"] = Value.ForString("method"),
                ["is_getter"] = Value.ForBool(true),
                ["expression_body"] = Value.ForBool(true),
            },
        },
    };

    /// <summary>A <c>metadata.kind = "class"</c> type definition with an optional superclass and own descriptor fields.</summary>
    private static TypeDefinition ClassTd(string name, string? superclass = null, params string[] fields)
    {
        var descriptor = new DescriptorProto { Name = name };
        for (var i = 0; i < fields.Length; i++)
        {
            descriptor.Field.Add(new FieldDescriptorProto
            {
                Name = fields[i],
                Number = i + 1,
                Label = FieldDescriptorProto.Types.Label.Optional,
                Type = FieldDescriptorProto.Types.Type.Int64,
            });
        }

        var metadata = new Struct { Fields = { ["kind"] = Value.ForString("class") } };
        if (superclass is not null)
        {
            metadata.Fields["superclass"] = Value.ForString(superclass);
        }

        return new TypeDefinition { Name = name, Descriptor_ = descriptor, Metadata = metadata };
    }

    private static Expression New(string typeName, params (string Name, Expression Value)[] fields)
    {
        var mc = new MessageCreation { TypeName = typeName };
        foreach (var (name, value) in fields)
        {
            mc.Fields.Add(new FieldValuePair { Name = name, Value = value });
        }

        return new Expression { MessageCreation = mc };
    }

    private static Expression FieldAccess(Expression obj, string field) =>
        new() { FieldAccess = new FieldAccess { Object = obj, Field = field } };

    private static Expression Assign(Expression target, Expression value) =>
        Ast.Call("std", "assign", Ast.Msg(("target", target), ("value", value)));
}
