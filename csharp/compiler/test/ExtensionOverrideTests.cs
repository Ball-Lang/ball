using System.Text;
using Ball.V1;
using Google.Protobuf.WellKnownTypes;
using BallV1Program = Ball.V1.Program;

namespace Ball.Compiler.Tests;

/// <summary>
/// Extension-override dispatch (issue #670, fixture
/// <c>480_extension_override_selection</c>).
///
/// <para><c>Ext(receiver).member</c> is encoded as a call NAMING the
/// extension's own member (<c>&lt;module&gt;:&lt;Ext&gt;.&lt;member&gt;</c>)
/// with the receiver in <c>self</c>, because the selection is the whole meaning
/// of the node: two extensions can declare the SAME member on the SAME type,
/// and the plain <c>receiver.member</c> emission resolves by ordinary lookup —
/// a DIFFERENT member.</para>
///
/// <para>C# has no extensions in this lowering, so each member becomes a flat
/// static impl (<c>AlphaTag__tag</c>). The qualified call name matched no
/// callable, so it fell to <c>BallRuntime.CallMethod("main:AlphaTag.tag", …)</c>
/// — the Dart-SDK dispatcher, which asks the RECEIVER (an ordinary list here)
/// and could not tell the two extensions apart even if it knew the name.</para>
///
/// <para>These run on EVERY PR (<c>dotnet test Ball.slnx</c> in ci.yml's
/// <c>csharp</c> job). The whole-corpus <c>csharp-compiler</c> leg lives only
/// in conformance-matrix.yml, which has no <c>pull_request:</c> trigger and
/// RATCHETS an aggregate count — it fails only on a DROP, so it was green with
/// this fixture failing.</para>
/// </summary>
public class ExtensionOverrideTests
{
    private const string Fixture = "480_extension_override_selection";

    /// <summary>Reads a golden as BYTES, normalising only CRLF pairs (a lone <c>\r</c> can be semantic).</summary>
    private static string Golden(string expectedFile) =>
        Encoding.UTF8.GetString(File.ReadAllBytes(expectedFile)).Replace("\r\n", "\n");

    [Fact]
    public void ExtensionOverride_CallsTheNamedMemberImpl()
    {
        var source = CSharpCompiler.Compile(BallJson.Load(RepoPaths.Conformance($"{Fixture}.ball.json")));

        foreach (var impl in new[]
                 {
                     "AlphaTag__tag(", "BetaTag__tag(",
                     "AlphaTag__label(", "BetaTag__label(",
                     "AlphaTag__scale(", "BetaTag__scale(",
                 })
        {
            Assert.Contains(impl, source);
        }

        // ...and none of them may go through the receiver-asking dispatcher,
        // which cannot tell the two extensions apart.
        Assert.DoesNotContain("BallRuntime.CallMethod(\"main:", source);
    }

    [Fact]
    public void ExtensionOverride_Runs_ByteExact()
    {
        var output = CSharpRunner.Run(
            CSharpCompiler.Compile(BallJson.Load(RepoPaths.Conformance($"{Fixture}.ball.json"))));
        Assert.Equal(Golden(RepoPaths.Conformance($"{Fixture}.expected_output.txt")), output);
    }

    /// <summary>
    /// A READ through an override of a member that has BOTH a getter and a
    /// setter must dispatch the GETTER (PR #829 review). Hand-built IR, not
    /// a fixture — <c>480_extension_override_selection</c> deliberately
    /// carries no setter arm (#865), so this shape is unreachable from the
    /// committed corpus even though it is valid Dart
    /// (<c>extension AlphaTag on List&lt;int&gt; { int get slot => …; set
    /// slot(int v) { … } }</c>).
    ///
    /// <para>Before the fix, <c>IndexExtensionMembers</c> filled
    /// <c>_extensionMemberImpl</c> in one pass with no getter/setter
    /// precedence: the getter and setter share the Ball function name
    /// <c>main:AlphaTag.slot</c>, so whichever member the loop visited LAST
    /// won the dictionary slot. The setter is collected after the getter in
    /// every real extension (`get` syntactically precedes `set`), so a plain
    /// read — `AlphaTag(xs).slot` — compiled to a call into the SETTER impl
    /// and printed <c>null</c> instead of <c>"GETTER"</c>: a silent wrong
    /// answer, never a compile error, on a construct main compiled cleanly
    /// before this PR (extension-override dispatch didn't exist at all).</para>
    /// </summary>
    [Fact]
    public void ExtensionOverrideRead_WithBothGetterAndSetter_DispatchesTheGetter()
    {
        var output = CSharpRunner.Run(CSharpCompiler.Compile(GetterAndSetterOverrideProgram()));

        Assert.Equal("GETTER\n", output);
    }

    /// <summary>
    /// The setter's impl must still be emitted under its own
    /// <c>__set</c>-suffixed name (never silently dropped) — the getter
    /// winning the READ dispatch must not come at the cost of the setter
    /// vanishing from the compiled source entirely.
    /// </summary>
    [Fact]
    public void ExtensionOverrideRead_WithBothGetterAndSetter_StillEmitsTheSetterImpl()
    {
        var source = CSharpCompiler.Compile(GetterAndSetterOverrideProgram());

        Assert.Contains("AlphaTag__slot(", source);
        Assert.Contains("AlphaTag__slot__set(", source);
    }

    /// <summary>
    /// <c>extension AlphaTag on List&lt;int&gt; { int get slot => …; set
    /// slot(int v) { … } }</c> plus
    /// <c>main() { print(AlphaTag([1, 2]).slot); }</c> — the getter and
    /// setter both carry the qualified name <c>main:AlphaTag.slot</c>, and
    /// the call site reaches them exactly as a parsed <c>Ext(x).m</c> read
    /// does: a <c>call</c> whose packed input carries an explicit
    /// <c>self</c> field.
    /// </summary>
    private static BallV1Program GetterAndSetterOverrideProgram()
    {
        var main = Ast.Block(
        [
            Ast.Expr(Ast.Print(OverrideCall(Ast.ListLit(Ast.Int(1), Ast.Int(2))))),
        ]);

        var getter = new FunctionDefinition
        {
            Name = "main:AlphaTag.slot",
            OutputType = "String",
            Body = Ast.Str("GETTER"),
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
        var setter = new FunctionDefinition
        {
            Name = "main:AlphaTag.slot",
            InputType = "int",
            OutputType = "void",
            Body = Ast.Str("SETTER"),
            Metadata = new Struct
            {
                Fields =
                {
                    ["kind"] = Value.ForString("method"),
                    ["is_setter"] = Value.ForBool(true),
                    ["expression_body"] = Value.ForBool(true),
                },
            },
        };

        var program = Ast.Program(main, getter, setter);
        program.Modules.First(m => m.Name == "main").TypeDefs.Add(new TypeDefinition
        {
            Name = "main:AlphaTag",
            Metadata = new Struct
            {
                Fields = { ["kind"] = Value.ForString("extension"), ["on"] = Value.ForString("List<int>") },
            },
        });
        return program;
    }

    /// <summary>The extension-override call shape: <c>function</c> names the member directly, and the packed input carries an explicit <c>self</c>.</summary>
    private static Expression OverrideCall(Expression receiver) =>
        new()
        {
            Call = new FunctionCall
            {
                Module = "main",
                Function = "main:AlphaTag.slot",
                Input = Ast.Msg(("self", receiver)),
            },
        };
}
