using System;
using System.IO;
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
///
/// <para><b><c>string.Join</c> (issue #492, slice 4, bucket (k)).</b> The same
/// function is the only place a <c>string.Join(sep, values)</c> call can be
/// routed, because <c>string</c> is a <c>PredefinedTypeSyntax</c> keyword exactly
/// like <c>int</c> — and, unlike <c>Debug</c>/<c>ArgumentNullException</c>, a
/// keyword can never collide with a user identifier, so this arm needs no
/// same-file-class guard. The route is the already-declared, already-compiled
/// <c>std_collections.string_join</c>. Its <c>StringJoinInput</c> field order is
/// <c>list</c>=1, <c>separator</c>=2 — <b>inverted</b> from C#'s
/// <c>(separator, values)</c> argument order — which is why the tests below
/// assert the field VALUES and run the encoded fixture, not merely the module
/// and function names.</para>
///
/// <para><b>Scoped to the measured shape.</b> Only the 2-argument spelling, the
/// one every occurrence in the Tier A corpus uses. A 1- or 3+-argument
/// <c>string.Join</c> (the <c>params</c> overloads) keeps failing loud rather
/// than being approximated, the same discipline <c>TryParse</c> established
/// above. The one documented divergence inside the routed shape is a
/// <c>null</c> ELEMENT: C# renders it as the empty string, while Ball's
/// <c>string_join</c> stringifies every element and so renders <c>null</c>. That
/// is invisible to a syntax-only encoder (it is an element VALUE, not a syntax
/// shape), so it is documented here and in <c>csharp/AGENTS.md</c> the same way
/// <c>EncodeConsoleCall</c>'s <c>Write</c> approximation is, rather than being
/// silently assumed away.</para>
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

    /// <summary>Bucket (k)'s committed fixture text, read from the same file the
    /// sweep encodes so the end-to-end proof below cannot drift from it.</summary>
    private static string BucketKFixture =>
        File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "fixtures", "realworld", "k_string_join.cs"));

    private const string JoinPreamble = """
        using System;
        using System.Collections.Generic;
        """;

    /// <summary>
    /// <c>string.Join(sep, values)</c> routes to <c>std_collections.string_join</c>
    /// with the two arguments SWAPPED into <c>StringJoinInput</c>'s declared field
    /// order. Asserting each field's value (not just the module/function names) is
    /// what makes an inverted construction fail here: a positional build would
    /// still produce a <c>string_join</c> call carrying two fields.
    /// </summary>
    [Fact]
    public void StringJoinEncodesAsStdCollectionsStringJoinWithSwappedFields()
    {
        var value = NthLetValue(OnParts("""        var joined = string.Join(", ", parts);"""), 1);

        Assert.Equal("std_collections", value.Call.Module);
        Assert.Equal("string_join", value.Call.Function);

        var fields = value.Call.Input.MessageCreation.Fields;
        Assert.Equal(2, fields.Count);
        Assert.Equal("parts", fields.Single(f => f.Name == "list").Value.Reference.Name);
        Assert.Equal(", ", fields.Single(f => f.Name == "separator").Value.Literal.StringValue);
    }

    /// <summary>A file that reaches <c>string_join</c> must declare the
    /// <c>std_collections</c> import, or the emitted program names a module it never
    /// brought in. This is the <c>MarkCollectionsUsed()</c> bookkeeping every other
    /// <c>std_collections</c> route already performs.</summary>
    [Fact]
    public void StringJoinMarksTheCollectionsModuleUsed()
    {
        var program = TestHelpers.EncodeProgram(OnParts("""        var joined = string.Join(" ", parts);"""));

        Assert.Contains(TestHelpers.MainModule(program).ModuleImports, i => i.Name == "std_collections");
    }

    /// <summary>
    /// Only the 2-argument shape is routed. The <c>params</c> overloads
    /// (<c>string.Join(sep, a, b)</c>) and the 1-argument spelling must keep
    /// failing loud rather than being silently approximated into a different
    /// meaning — the same boundary <see cref="IntTryParseStillFailsLoud"/> pins for
    /// <c>Parse</c>.
    /// </summary>
    [Theory]
    [InlineData("""string.Join(", ", "a", "b")""")]
    [InlineData("""string.Join(", ")""")]
    public void StringJoinAtAnUnroutedArityStaysLoud(string expression)
    {
        var ex = Assert.Throws<EncoderException>(() => TestHelpers.EncodeProgram(
            OnParts($"        var joined = {expression};")));

        Assert.Contains("unsupported static call", ex.Message);
        Assert.Contains("string.Join", ex.Message);
    }

    /// <summary>
    /// The new arm must not capture a same-file user class's own static
    /// <c>Join</c>. <c>string</c> is a keyword and can never be shadowed, but a
    /// helper TYPE spelled <c>StringJoinHelper.Join(...)</c> reaches a different
    /// dispatch path entirely and must keep resolving to the user function — a
    /// guard against a future edit widening the arm from the keyword to any
    /// receiver whose method happens to be named <c>Join</c>.
    /// </summary>
    [Fact]
    public void AUserDeclaredStaticJoinIsNotCaptured()
    {
        var program = TestHelpers.EncodeProgram($$"""
            {{JoinPreamble}}

            class StringJoinHelper
            {
                public static string Join(string separator, List<string> values)
                {
                    return separator;
                }
            }

            class Program
            {
                static void Main()
                {
                    var parts = new List<string> { "a", "b" };
                    var joined = StringJoinHelper.Join("-", parts);
                }
            }
            """);

        var value = TestHelpers.MainFunction(program).Body.Block.Statements[1].Let.Value;
        Assert.NotEqual("std_collections", value.Call.Module);
        Assert.Contains("Join", value.Call.Function);
    }

    /// <summary>
    /// The end-to-end proof: bucket (k)'s own fixture, ENCODED, compiled back to C#
    /// and RUN. It joins the same list with two different separators and then joins
    /// an empty list, so a swapped <c>list</c>/<c>separator</c> pair, a dropped
    /// separator, or a dropped receiver all change this string — the shape
    /// assertions above must not be the only evidence (bucket (e) encoded and
    /// compiled clean and still crashed at run time).
    /// </summary>
    [Fact]
    public void BucketKFixtureEncodesCompilesAndRuns()
    {
        var output = CSharpRunner.Run(CSharpCompiler.Compile(TestHelpers.EncodeProgram(BucketKFixture)));

        Assert.Equal("one hundred twenty\none, hundred, twenty\n\n", output);
    }

    /// <summary>Neither operand has to be a literal or a bare name: the separator
    /// and the values are ordinary expressions, joined at run time.</summary>
    [Fact]
    public void StringJoinRunsOnComputedOperands()
    {
        var compiled = CSharpCompiler.Compile(TestHelpers.EncodeProgram($$"""
            {{JoinPreamble}}

            class Program
            {
                static void Main()
                {
                    var parts = new List<string> { "a", "b", "c" };
                    var sep = "-" + "-";
                    Console.WriteLine(string.Join(sep, parts));
                }
            }
            """));

        Assert.Equal("a--b--c\n", CSharpRunner.Run(compiled));
    }

    /// <summary>A snippet whose statement 0 is the <c>parts</c> list every tree
    /// assertion reads its receiver from, so the expression under test is always
    /// statement 1.</summary>
    private static string OnParts(string body) => $$"""
        {{JoinPreamble}}

        class Program
        {
            static void Main()
            {
                var parts = new List<string> { "one", "two" };
        {{body}}
            }
        }
        """;

    private static Expression FirstLetValue(string source) => NthLetValue(source, 0);

    private static Expression NthLetValue(string source, int index) =>
        TestHelpers.MainFunction(TestHelpers.EncodeProgram(source)).Body.Block.Statements[index].Let.Value;
}
