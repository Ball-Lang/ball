using System.Linq;
using Ball.Compiler;
using Ball.Compiler.Tests;
using Ball.V1;

namespace Ball.Encoder.Tests;

/// <summary>
/// Static calls on a PREDEFINED type (<c>int.Parse("41")</c>) and the 0-argument
/// <c>.Count()</c> extension-method spelling — issue #492, bucket (e).
///
/// <para><b>Where the gap came from.</b> <c>int</c> parses as a Roslyn
/// <c>PredefinedTypeSyntax</c>, never an <c>IdentifierNameSyntax</c>, so
/// <c>Encoder.StaticReceiverName</c> returned <c>null</c> for it and
/// <c>EncodeMemberInvocation</c> fell through to encoding the receiver as an
/// ordinary expression — landing on <c>EncodeExpr</c>'s default arm,
/// <c>unsupported C# expression kind `PredefinedType`</c>. And <c>.Count()</c>
/// with parentheses is the LINQ extension-method spelling, which routes through
/// <c>DispatchInstanceOrBuiltinMethod</c>, whose switch had a
/// <c>("First", 0)</c> but no <c>("Count", 0)</c> — even though
/// <c>EncodePropertyAccess</c> had mapped the PROPERTY spelling <c>.Count</c> to
/// <c>std.length</c> since day one. Bucket (e)'s committed fixture contains both,
/// so it needed both to flip on its <b>unmodified</b> text.</para>
///
/// <para><b>Scope of the <c>Parse</c> mapping.</b> Only <c>int</c>/<c>long</c> →
/// <c>std.string_to_int</c> and <c>double</c>/<c>float</c> →
/// <c>std.string_to_double</c>, because those are the only two conversions
/// <c>StdModuleBuilders</c> declares. <c>float.Parse</c> going through
/// <c>string_to_double</c> is a deliberate precision-WIDENING approximation:
/// Ball has no 32-bit float type, so a C# <c>float</c> is modelled as a double
/// everywhere in this pipeline — the same documented-approximation style as
/// <c>EncodeConsoleCall</c>'s <c>Write</c>-becomes-newline-terminated-<c>print</c>.
/// <c>bool.Parse</c> has no declared <c>std</c> counterpart and
/// <c>int.TryParse(s, out var n)</c> is an <c>out var</c>
/// (<c>DeclarationExpression</c>) shape this encoder does not model at all —
/// both must keep failing loud rather than being silently approximated, since
/// dropping <c>TryParse</c>'s failure branch would compile and run and be wrong,
/// the exact defect class #492 slice B had to fix once for constructors.</para>
/// </summary>
public class PredefinedTypeCallTests
{
    /// <summary>Bucket (e)'s committed fixture text, inlined so the end-to-end
    /// proof below runs the same source the sweep encodes.</summary>
    private const string BucketEFixture = """
        using System;
        using System.Collections.Generic;
        using System.Linq;

        public class Program
        {
            public static void Main()
            {
                Func<int, int> twice = (int n) => n * 2;
                List<int> values = new List<int> { 1, 2, 3 };
                IEnumerable<int> doubled = values.Where(v => v > 1).Select(twice);
                int parsed = int.Parse("41");
                Console.WriteLine(doubled.Count() + parsed);
            }
        }
        """;

    [Theory]
    [InlineData("int", "string_to_int")]
    [InlineData("long", "string_to_int")]
    [InlineData("double", "string_to_double")]
    [InlineData("float", "string_to_double")]
    public void PredefinedTypeParseEncodesAsTheDeclaredStdConversion(string keyword, string stdFunction)
    {
        var value = FirstLetValue($$"""
            class Program
            {
                static void Main()
                {
                    var n = {{keyword}}.Parse("41");
                }
            }
            """);

        Assert.Equal("std", value.Call.Module);
        Assert.Equal(stdFunction, value.Call.Function);
        Assert.Equal("41", value.Call.Input.MessageCreation.Fields.Single().Value.Literal.StringValue);
    }

    /// <summary>The 0-argument METHOD spelling must encode identically to the
    /// PROPERTY spelling — a future edit that diverges the two is a defect, since
    /// C# means the same thing by both on a <c>List&lt;T&gt;</c>.</summary>
    [Fact]
    public void ZeroArgCountMethodCallEncodesLikeTheCountProperty()
    {
        const string methodForm = """
            using System.Collections.Generic;
            using System.Linq;

            class Program
            {
                static void Main()
                {
                    var values = new List<int> { 1, 2, 3 };
                    var n = values.Count();
                }
            }
            """;
        const string propertyForm = """
            using System.Collections.Generic;

            class Program
            {
                static void Main()
                {
                    var values = new List<int> { 1, 2, 3 };
                    var n = values.Count;
                }
            }
            """;

        var method = NthLetValue(methodForm, 1);
        Assert.Equal("std", method.Call.Module);
        Assert.Equal("length", method.Call.Function);
        Assert.Equal(method, NthLetValue(propertyForm, 1));
    }

    /// <summary>
    /// A predefined type in a NON-receiver position — <c>default(int)</c> — is a
    /// different syntax slot (<c>DefaultExpressionSyntax.Type</c>), unreachable
    /// from the new invocation arm.
    ///
    /// <para>It had its own, separate silent-wrong-output bug, found while
    /// writing this guard: the <c>DefaultExpressionSyntax</c> arm encoded EVERY
    /// <c>default(T)</c> as a null literal, so <c>default(int)</c> printed
    /// <c>null</c> where C# prints <c>0</c>. Asserting the oneof CASE, not just
    /// <c>IntValue</c>, is what makes this test able to fail: an all-defaults
    /// <c>Literal</c> reads back <c>IntValue == 0</c> too.</para>
    /// </summary>
    [Theory]
    [InlineData("int", Literal.ValueOneofCase.IntValue)]
    [InlineData("long", Literal.ValueOneofCase.IntValue)]
    [InlineData("double", Literal.ValueOneofCase.DoubleValue)]
    [InlineData("bool", Literal.ValueOneofCase.BoolValue)]
    public void DefaultOfAPredefinedValueTypeEncodesItsZero(string keyword, Literal.ValueOneofCase expected)
    {
        var value = FirstLetValue($$"""
            class Program
            {
                static void Main()
                {
                    var zero = default({{keyword}});
                }
            }
            """);

        Assert.Equal(Expression.ExprOneofCase.Literal, value.ExprCase);
        Assert.Equal(expected, value.Literal.ValueCase);
    }

    /// <summary><c>default(T)</c> for a type whose zero really IS null keeps
    /// encoding as the null literal — the new arm must not invent a zero for a
    /// reference type or for a keyword Ball has no counterpart for
    /// (<c>char</c>, <c>decimal</c>).</summary>
    [Theory]
    [InlineData("string")]
    [InlineData("object")]
    [InlineData("char")]
    [InlineData("decimal")]
    [InlineData("Program")]
    public void DefaultOfAReferenceOrUnmodelledTypeStaysNull(string typeName)
    {
        var value = FirstLetValue($$"""
            class Program
            {
                static void Main()
                {
                    var zero = default({{typeName}});
                }
            }
            """);

        Assert.Equal(Expression.ExprOneofCase.Literal, value.ExprCase);
        Assert.Equal(Literal.ValueOneofCase.None, value.Literal.ValueCase);
    }

    /// <summary><c>bool.Parse</c> has no declared <c>std</c> counterpart, so it must
    /// stay a loud error rather than be invented — a regression guard against
    /// over-widening the new arm.</summary>
    [Fact]
    public void BoolParseStillFailsLoud()
    {
        var ex = Assert.Throws<EncoderException>(() => TestHelpers.EncodeProgram("""
            class Program
            {
                static void Main()
                {
                    var b = bool.Parse("true");
                }
            }
            """));
        Assert.Contains("bool", ex.Message);
        Assert.Contains("Parse", ex.Message);
    }

    /// <summary><c>int.TryParse(s, out var n)</c> must keep failing loud. Routing it
    /// to <c>string_to_int</c> would DROP its failure branch — a program that
    /// compiles, runs, and is silently wrong on bad input.</summary>
    [Fact]
    public void IntTryParseStillFailsLoud()
    {
        Assert.Throws<EncoderException>(() => TestHelpers.EncodeProgram("""
            class Program
            {
                static void Main()
                {
                    var ok = int.TryParse("41", out var n);
                }
            }
            """));
    }

    /// <summary>
    /// The end-to-end proof: bucket (e)'s own fixture, ENCODED, compiled back to
    /// C#, and executed. <c>values = [1,2,3]</c> → <c>Where(v &gt; 1) = [2,3]</c> →
    /// <c>Select(twice) = [4,6]</c> → <c>Count() = 2</c>, plus
    /// <c>int.Parse("41") = 41</c>, so stdout is exactly <c>43\n</c>.
    ///
    /// <para>This is the assertion that made the fix honest rather than
    /// syntax-deep. With only the two encoder dispatch arms in place the fixture
    /// encodes and compiles clean and then <b>crashes</b> at run time —
    /// <c>BallRuntimeException: ball runtime: value is not callable: Null</c> out
    /// of <c>BallStd.ListFilter</c> — because the C# COMPILER read
    /// <c>list_filter</c>'s callback only under the Dart-encoder spelling
    /// <c>value</c> while this encoder emits the declared name <c>callback</c>.
    /// See <c>csharp/compiler/test/CallbackFieldAliasTests.cs</c>. An encode-only
    /// assertion would have declared the bucket closed while its output did not
    /// run.</para>
    /// </summary>
    [Fact]
    public void BucketEFixtureEncodesCompilesAndRuns()
    {
        var output = CSharpRunner.Run(CSharpCompiler.Compile(TestHelpers.EncodeProgram(BucketEFixture)));
        Assert.Equal("43\n", output);
    }

    private static Expression FirstLetValue(string source) => NthLetValue(source, 0);

    private static Expression NthLetValue(string source, int index) =>
        TestHelpers.MainFunction(TestHelpers.EncodeProgram(source)).Body.Block.Statements[index].Let.Value;
}
