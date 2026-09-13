using System;
using System.IO;
using System.Linq;
using Ball.Compiler;
using Ball.Compiler.Tests;
using Ball.Shared;
using Ball.V1;

namespace Ball.Encoder.Tests;

/// <summary>
/// The 0-argument LINQ terminals <c>.Last()</c> and <c>.Any()</c> — issue #492, bucket (j).
///
/// <para><b>Where the gap came from.</b> <c>DispatchInstanceOrBuiltinMethod</c>'s
/// <c>switch (methodName, argExprs.Count)</c> carries an arity window per routed name (the
/// <c>collectionRoutes</c> pattern of <c>dart/encoder</c>, #494/#510): <c>First</c> has BOTH
/// a 1-argument arm (<c>list_find</c>) and a 0-argument arm (<c>list_first</c>) — as did
/// <c>FirstOrDefault</c> until issue #588 removed it from both — and <c>Any</c> has only its
/// 1-argument arm (<c>list_any</c>). The
/// 0-argument spellings of <c>Last</c> and <c>Any</c> had no arm at all, so they fell through
/// to the same generic fallback throw every unresolved name hits:
/// <c>unsupported method call `.Last(...)` with 0 argument(s) (… a user-defined instance method
/// must be declared in a same-file class …)</c> — a message that mis-describes a plain
/// <c>List&lt;T&gt;</c> call as a cross-file user method.</para>
///
/// <para><b>What they route to.</b> <c>list_last</c> and <c>list_is_empty</c> are declared by
/// <c>StdModuleBuilders</c> (the #505 declared-name rule — the C# builders are gated name-for-name
/// against <c>dart/shared/lib/std_collections.dart</c>), compiled by <c>BaseCall</c> and run by
/// every engine. So, like slice 3's <c>std.assert</c> routes, this is purely an encoder-side
/// dispatch-table gap: no new base function, no proto change, no cross-language work.</para>
///
/// <para><b>Semantics, checked rather than assumed.</b> C#'s <c>.Last()</c> throws
/// <c>InvalidOperationException</c> on an empty sequence and Ball's <c>list_last</c> throws
/// <c>BallRuntimeException("last on an empty list")</c> (<c>BallRuntime.ListLast</c>,
/// <c>_stdAsList(...)!.last</c> in the Dart reference engine) — the SAME contract, which is
/// why this is a route and not an approximation.</para>
///
/// <para><b>Why no <c>*OrDefault</c> name is routed.</b> They are the default-returning
/// contracts, and the only trees available to them are the throwing
/// <c>list_first</c>/<c>list_last</c>/<c>list_find</c>. When this file was written the
/// pre-existing <c>("First" or "FirstOrDefault", …)</c> arms still made that trade — issue
/// #588 — and this slice FLAGGED it rather than propagating it to a second name; #588 has
/// since REMOVED <c>FirstOrDefault</c> from both arms, so all four <c>*OrDefault</c> spellings
/// now fail loud for one reason. See <see cref="OrDefaultTerminalsFailLoud"/>,
/// <see cref="FirstOrDefaultContractTests"/> for the decision record, and the
/// "`*OrDefault` LINQ terminals" section of <c>csharp/AGENTS.md</c>.</para>
/// </summary>
public class ZeroArgLinqTerminalTests
{
    /// <summary>Bucket (j)'s committed fixture text, read from the same file the sweep encodes
    /// so the end-to-end proof below cannot drift from it.</summary>
    private static string BucketJFixture =>
        File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "fixtures", "realworld", "j_zero_arg_linq_terminals.cs"));

    private const string ListPreamble = """
        using System;
        using System.Collections.Generic;
        using System.Linq;
        """;

    [Fact]
    public void ZeroArgLastEncodesAsListLast()
    {
        var value = NthLetValue(OnValues("        var x = values.Last();"), 1);

        Assert.Equal("std_collections", value.Call.Module);
        Assert.Equal("list_last", value.Call.Function);
        var field = value.Call.Input.MessageCreation.Fields.Single();
        Assert.Equal("list", field.Name);
        Assert.Equal("values", field.Value.Reference.Name);
    }

    /// <summary>
    /// <c>.Any()</c> is "not empty", so it must encode as <c>std.not</c> WRAPPING
    /// <c>std_collections.list_is_empty</c>. Asserting the wrapper (and not merely that
    /// <c>list_is_empty</c> appears somewhere) is what makes the inverted encoding — the easy
    /// mistake here — fail this test rather than pass it.
    /// </summary>
    [Fact]
    public void ZeroArgAnyEncodesAsNotOfListIsEmpty()
    {
        var value = NthLetValue(OnValues("        var x = values.Any();"), 1);

        Assert.Equal("std", value.Call.Module);
        Assert.Equal("not", value.Call.Function);

        var inner = value.Call.Input.MessageCreation.Fields.Single();
        Assert.Equal("value", inner.Name);
        Assert.Equal("std_collections", inner.Value.Call.Module);
        Assert.Equal("list_is_empty", inner.Value.Call.Function);

        var list = inner.Value.Call.Input.MessageCreation.Fields.Single();
        Assert.Equal("list", list.Name);
        Assert.Equal("values", list.Value.Reference.Name);
    }

    /// <summary>The 1-argument arms are untouched: <c>.Any(predicate)</c> stays
    /// <c>list_any</c> and <c>.First(predicate)</c> stays <c>list_find</c>. A new 0-arg arm
    /// that widened its own arity window would silently swallow the predicate.</summary>
    [Theory]
    [InlineData("values.Any(v => v > 1)", "list_any")]
    [InlineData("values.All(v => v > 1)", "list_all")]
    [InlineData("values.First(v => v > 1)", "list_find")]
    public void PredicateArmsAreUnchanged(string expression, string function)
    {
        var value = NthLetValue(OnValues($"        var x = {expression};"), 1);

        Assert.Equal("std_collections", value.Call.Module);
        Assert.Equal(function, value.Call.Function);
        Assert.Contains(value.Call.Input.MessageCreation.Fields, f => f.Name == "callback");
    }

    /// <summary>
    /// Every <c>*OrDefault</c> LINQ terminal must fail LOUD. Their contract is "return
    /// <c>default(T)</c> instead of throwing", and every tree available today
    /// (<c>list_first</c>/<c>list_last</c>/<c>list_find</c>) throws instead — routing one
    /// trades a loud encode error for a program that encodes, compiles, runs, and is wrong
    /// exactly on the empty/no-match input the name exists to handle. <c>FirstOrDefault</c>
    /// was the one name that did carry that defect (issue #588, fixed by removing it from
    /// <c>First</c>'s two arity windows); the whole family is now asserted here, by one test,
    /// for one reason. <see cref="FirstOrDefaultContractTests"/> records why the alternative —
    /// a nullable <c>list_first_or_null</c> primitive — was declined.
    /// </summary>
    [Theory]
    [InlineData("values.FirstOrDefault()")]
    [InlineData("values.FirstOrDefault(v => v > 1)")]
    [InlineData("values.LastOrDefault()")]
    [InlineData("values.SingleOrDefault()")]
    public void OrDefaultTerminalsFailLoud(string expression)
    {
        var ex = Assert.Throws<EncoderException>(() => TestHelpers.EncodeProgram(OnValues($"        var x = {expression};")));

        Assert.Contains("unsupported method call", ex.Message);
    }

    /// <summary>
    /// The end-to-end proof: bucket (j)'s own fixture, ENCODED, compiled back to C# by
    /// <see cref="CSharpCompiler"/>, and RUN. <c>[1,2,3].Last()</c> is <c>3</c>,
    /// <c>[1,2,3].Any()</c> is <c>true</c> and <c>[].Any()</c> is <c>false</c> — so an
    /// inverted or receiver-dropping route fails here, not merely in the tree assertions.
    /// (Bucket (e) is the precedent for insisting on a real run: its encoded fixture compiled
    /// clean and then crashed at run time.)
    /// </summary>
    [Fact]
    public void BucketJFixtureEncodesCompilesAndRuns()
    {
        var output = CSharpRunner.Run(CSharpCompiler.Compile(TestHelpers.EncodeProgram(BucketJFixture)));

        Assert.Equal("3\ntrue\nfalse\n", output);
    }

    /// <summary>
    /// <c>.Last()</c> on an EMPTY list must throw, exactly as C#'s own <c>.Last()</c> does —
    /// the property that makes <c>list_last</c> the right route rather than a convenient one.
    /// A route to some default-returning tree would pass the happy-path proof above and
    /// silently swallow this.
    /// </summary>
    [Fact]
    public void LastOnAnEmptyListThrowsAtRunTime()
    {
        var compiled = CSharpCompiler.Compile(TestHelpers.EncodeProgram(Snippet("""
                var empty = new List<int>();
                Console.WriteLine(empty.Last());
            """)));

        var ex = Assert.Throws<BallRuntimeException>(() => CSharpRunner.Run(compiled));

        Assert.Contains("last on an empty list", ex.Message);
    }

    /// <summary>A <c>List&lt;T&gt;</c> declared and filled through the routed collection ops
    /// still reads back through the new terminals — the receiver is an expression, not only a
    /// bare identifier.</summary>
    [Fact]
    public void TerminalsRunOnAComputedReceiver()
    {
        var compiled = CSharpCompiler.Compile(TestHelpers.EncodeProgram(Snippet("""
                var values = new List<int> { 1, 2, 3 };
                Console.WriteLine(values.Where(v => v > 1).Last());
                Console.WriteLine(values.Where(v => v > 99).Any());
            """)));

        Assert.Equal("3\nfalse\n", CSharpRunner.Run(compiled));
    }

    /// <summary>Wrap statement <paramref name="body"/> in a real, parseable program — the
    /// only entry point <see cref="CSharpEncoder.Encode"/> accepts (see
    /// <c>TestHelpers</c>'s doc comment).</summary>
    private static string Snippet(string body) => $$"""
        {{ListPreamble}}

        class Program
        {
            static void Main()
            {
        {{body}}
            }
        }
        """;

    /// <summary>A snippet whose statement 0 is the <c>values</c> list every tree assertion
    /// reads its receiver from, so the expression under test is always statement 1.</summary>
    private static string OnValues(string body) => Snippet($$"""
                var values = new List<int> { 1, 2, 3 };
        {{body}}
        """);

    private static Expression NthLetValue(string source, int index) =>
        TestHelpers.MainFunction(TestHelpers.EncodeProgram(source)).Body.Block.Statements[index].Let.Value;
}
