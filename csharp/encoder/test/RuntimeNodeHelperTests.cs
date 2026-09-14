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
/// error, never a guess), plus one end-to-end fixture that is compiled, re-encoded, compiled
/// again and RUN against its committed golden.</para>
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
    /// positional slot. That is <c>null_coalesce</c> over two <c>field_access</c> nodes — the
    /// same <c>?? ??</c> chain <c>BallMethods.ArgGet</c> itself performs.
    /// </summary>
    [Fact]
    public void ArgGetEncodesAsNamedThenPositionalFieldAccess()
    {
        var arg = FirstPrintedArgument(
            "        BallRuntime.Print(BallRuntime.ArgGet(BallValue.Null, \"lo\", \"arg0\"));");

        Assert.Equal(Expression.ExprOneofCase.Call, arg.ExprCase);
        Assert.Equal("std", arg.Call.Module);
        Assert.Equal("null_coalesce", arg.Call.Function);

        var fields = arg.Call.Input.MessageCreation.Fields;
        var left = fields.Single(f => f.Name == "left").Value;
        var right = fields.Single(f => f.Name == "right").Value;

        Assert.Equal(Expression.ExprOneofCase.FieldAccess, left.ExprCase);
        Assert.Equal("lo", left.FieldAccess.Field);
        Assert.Equal(Expression.ExprOneofCase.FieldAccess, right.ExprCase);
        Assert.Equal("arg0", right.FieldAccess.Field);
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
