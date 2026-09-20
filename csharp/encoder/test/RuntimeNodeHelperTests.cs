using System;
using System.Linq;
using Ball.Encoder;
using Ball.V1;

namespace Ball.Encoder.Tests;

/// <summary>
/// The two <c>BallRuntime</c> helpers whose inverse is an expression NODE rather than one
/// <c>std</c> base call — <c>FieldGet</c> and <c>ArgGet</c> (issue #689).
///
/// <para><c>encoder/src/RuntimeHelpers.cs</c>'s table can express exactly one shape: a helper
/// name, the <c>std</c> function it emits, and the input field each positional argument fills.
/// Neither of these fits it. <c>FieldGet(obj, "name")</c> inverts to a <c>field_access</c> node,
/// a different <c>Expression</c> kind entirely; <c>ArgGet(input, "name", "argN")</c> inverts to a
/// null-coalesced PAIR of them. Until they were added as named arms, the encoder refused both —
/// and since the Ball → C# compiler emits <c>FieldGet</c> for every <c>self</c>/field read, that
/// refusal was the single most common first blocker in the <c>csharp-roundtrip</c> matrix row
/// (<c>101_simple_class</c>, <c>102_inheritance</c>, <c>103_abstract_class</c>,
/// <c>104_getter_setter</c>, <c>106_factory_constructor</c>, …).</para>
///
/// <para>The whole-corpus proof is that row, which is floored and ratcheted in
/// <c>conformance-matrix.yml</c>. These are the fast in-solution guards on the SHAPE and on the
/// fail-loud boundary either arm keeps (issue #55 doctrine: a key this encoder cannot name is an
/// error, never a guess). A shape assertion cannot see whether the tree it asserts actually RUNS,
/// which is exactly how the first cut of the <c>ArgGet</c> arm shipped a pair of
/// <c>field_access</c> operands that throw on the reference engine for every real input —
/// <see cref="ReferenceEngineExecutionTests"/> is the executable half, and it runs the
/// re-encoded program on the Dart reference engine.</para>
/// </summary>
public class RuntimeNodeHelperTests
{
    private static string Wrap(string body) => $$"""
        using Ball.Shared;
        internal static class BallProgram
        {
            public static void Main(string[] args)
            {
        {{body}}
            }
        }
        """;

    private static Expression FirstPrintedArgument(string body)
    {
        var program = CSharpEncoder.Encode(Wrap(body));
        var main = program.Modules.Single(m => m.Name == "main").Functions.Single(f => f.Name == "Main");
        var call = main.Body.Block.Statements[0].Expression.Call;
        Assert.Equal("std", call.Module);
        Assert.Equal("print", call.Function);
        return call.Input.MessageCreation.Fields.Single(f => f.Name == "message").Value;
    }

    /// <summary><c>BallRuntime.FieldGet(obj, "x")</c> is the compiler's emission of a
    /// <c>field_access</c> node, so it must encode back to exactly that node — not to a base
    /// call, and not to a refusal.</summary>
    [Fact]
    public void FieldGetEncodesAsAFieldAccessNode()
    {
        var arg = FirstPrintedArgument("        BallRuntime.Print(BallRuntime.FieldGet(BallValue.Null, \"x\"));");

        Assert.Equal(Expression.ExprOneofCase.FieldAccess, arg.ExprCase);
        Assert.Equal("x", arg.FieldAccess.Field);
        Assert.Equal(Expression.ExprOneofCase.Literal, arg.FieldAccess.Object.ExprCase);
        Assert.Equal(Literal.ValueOneofCase.None, arg.FieldAccess.Object.Literal.ValueCase);
    }

    /// <summary>A Ball <c>field_access</c> NAMES a field; it cannot compute one. A key that is
    /// not a string literal must therefore fail loud rather than be guessed at.</summary>
    [Fact]
    public void FieldGetWithAComputedFieldNameFailsLoud()
    {
        var ex = Assert.Throws<EncoderException>(() => CSharpEncoder.Encode(Wrap("""
                    var key = "x";
                    BallRuntime.Print(BallRuntime.FieldGet(BallValue.Null, key));
        """)));

        Assert.Contains("FieldGet", ex.Message, StringComparison.Ordinal);
        Assert.Contains("string-literal field name", ex.Message, StringComparison.Ordinal);
    }

    /// <summary>The arity boundary the table's rows already enforce, kept by the node arm.</summary>
    [Fact]
    public void FieldGetArityIsChecked()
    {
        var ex = Assert.Throws<EncoderException>(() => CSharpEncoder.Encode(Wrap(
            "        BallRuntime.Print(BallRuntime.FieldGet(BallValue.Null));")));

        Assert.Contains("FieldGet", ex.Message, StringComparison.Ordinal);
        Assert.Contains("expects 2 argument(s)", ex.Message, StringComparison.Ordinal);
    }

    /// <summary>
    /// <c>BallRuntime.ArgGet(input, "lo", "arg0")</c> is the compiler's parameter prologue for a
    /// 2+-parameter callee: read the declared name out of the one input message, else its
    /// positional slot. That is <c>null_coalesce</c> over two TOLERANT keyed reads — the same
    /// <c>?? ??</c> chain <c>BallMethods.ArgGet</c> itself performs.
    ///
    /// <para>The operands are <c>std_collections.map_get</c>, never <c>field_access</c>: exactly
    /// one of the two keys is present in any input the compiler packs, and
    /// <c>std.null_coalesce</c> is EAGER on the reference engine, so a <c>field_access</c> on the
    /// absent key would be a hard <c>BallRuntimeError: Field "…" not found</c> — the arm would
    /// throw on every real input. <see cref="ReferenceEngineExecutionTests"/> is the executable
    /// half of this guard; this one pins the shape that makes it run.</para>
    /// </summary>
    [Fact]
    public void ArgGetEncodesAsNamedThenPositionalTolerantKeyRead()
    {
        var arg = FirstPrintedArgument(
            "        BallRuntime.Print(BallRuntime.ArgGet(BallValue.Null, \"lo\", \"arg0\"));");

        Assert.Equal(Expression.ExprOneofCase.Call, arg.ExprCase);
        Assert.Equal("std", arg.Call.Module);
        Assert.Equal("null_coalesce", arg.Call.Function);

        var fields = arg.Call.Input.MessageCreation.Fields;
        AssertTolerantKeyRead(fields.Single(f => f.Name == "left").Value, "lo");
        AssertTolerantKeyRead(fields.Single(f => f.Name == "right").Value, "arg0");
    }

    /// <summary>One <c>ArgGet</c> operand: a <c>std_collections.map_get(map, key)</c> whose key is
    /// the literal <paramref name="key"/>. Asserts it is NOT a <c>field_access</c>, which is the
    /// specific regression this pins.</summary>
    private static void AssertTolerantKeyRead(Expression operand, string key)
    {
        Assert.NotEqual(Expression.ExprOneofCase.FieldAccess, operand.ExprCase);
        Assert.Equal(Expression.ExprOneofCase.Call, operand.ExprCase);
        Assert.Equal("std_collections", operand.Call.Module);
        Assert.Equal("map_get", operand.Call.Function);

        var operands = operand.Call.Input.MessageCreation.Fields;
        var keyExpr = operands.Single(f => f.Name == "key").Value;
        Assert.Equal(Expression.ExprOneofCase.Literal, keyExpr.ExprCase);
        Assert.Equal(key, keyExpr.Literal.StringValue);
        Assert.Contains(operands, f => f.Name == "map");
    }

    /// <summary>Reading a key through <c>std_collections</c> must also DECLARE that module, or the
    /// encoded program calls a base function it never imported.</summary>
    [Fact]
    public void ArgGetDeclaresTheCollectionsModuleItReadsThrough()
    {
        var program = CSharpEncoder.Encode(Wrap(
            "        BallRuntime.Print(BallRuntime.ArgGet(BallValue.Null, \"lo\", \"arg0\"));"));

        Assert.Contains(program.Modules, m => m.Name == "std_collections");
        var main = program.Modules.Single(m => m.Name == "main");
        Assert.Contains(main.ModuleImports, i => i.Name == "std_collections");
        var collections = program.Modules.Single(m => m.Name == "std_collections");
        Assert.Contains(collections.Functions, f => f.Name == "map_get" && f.IsBase);
    }

    /// <summary>Same fail-loud boundary as <c>FieldGet</c>, on either key operand.</summary>
    [Fact]
    public void ArgGetWithAComputedKeyFailsLoud()
    {
        var ex = Assert.Throws<EncoderException>(() => CSharpEncoder.Encode(Wrap("""
                    var key = "lo";
                    BallRuntime.Print(BallRuntime.ArgGet(BallValue.Null, key, "arg0"));
        """)));

        Assert.Contains("ArgGet", ex.Message, StringComparison.Ordinal);
        Assert.Contains("string-literal key names", ex.Message, StringComparison.Ordinal);
    }

    /// <summary>The arity boundary, again — <c>ArgGet</c> takes three operands, never two.</summary>
    [Fact]
    public void ArgGetArityIsChecked()
    {
        var ex = Assert.Throws<EncoderException>(() => CSharpEncoder.Encode(Wrap(
            "        BallRuntime.Print(BallRuntime.ArgGet(BallValue.Null, \"lo\"));")));

        Assert.Contains("ArgGet", ex.Message, StringComparison.Ordinal);
        Assert.Contains("expects 3 argument(s)", ex.Message, StringComparison.Ordinal);
    }
}
