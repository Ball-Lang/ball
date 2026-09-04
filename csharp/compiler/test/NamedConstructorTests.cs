using System.Text;

namespace Ball.Compiler.Tests;

/// <summary>
/// Named-constructor call resolution and constructor initializer lists
/// (issue #527).
///
/// <para>The Dart encoder emits <c>Class.name(args)</c> as an ordinary method
/// call whose packed <c>self</c> field is a bare <c>reference{name: "Class"}</c>
/// — the class name itself, not a bound value. <see cref="CSharpCompiler"/>'s
/// call fallback used to emit a bare <c>from(input)</c>, which is CS0103: named
/// constructors compile to <c>Owner__member</c> impls, never a top-level
/// <c>from</c>.</para>
///
/// <para>These run on EVERY PR (<c>dotnet test Ball.slnx</c> in ci.yml's
/// <c>csharp</c> job, default build). The whole-corpus <c>csharp-compiler</c>
/// leg that would also have measured this lives only in conformance-matrix.yml,
/// which has no <c>pull_request:</c> trigger and is a ratchet on an aggregate
/// count — not a parity gate.</para>
/// </summary>
public class NamedConstructorTests
{
    /// <summary>Reads a golden as BYTES, normalising only CRLF pairs (a lone <c>\r</c> can be semantic).</summary>
    private static string Golden(string expectedFile) =>
        Encoding.UTF8.GetString(File.ReadAllBytes(expectedFile)).Replace("\r\n", "\n");

    [Fact]
    public void NamedConstructorCall_ResolvesToTheConstructorImpl()
    {
        var source = CSharpCompiler.Compile(BallJson.Load(RepoPaths.Conformance("436_recursive_ctor_named.ball.json")));
        // Each impl name must appear more than once: its own declaration PLUS at
        // least one resolved call site (a bare `from(...)` is CS0103).
        Assert.True(Occurrences(source, "Countdown__from(") >= 2, "no resolved Countdown__from call site");
        Assert.True(Occurrences(source, "Countdown__pair(") >= 2, "no resolved Countdown__pair call site");
    }

    private static int Occurrences(string haystack, string needle)
    {
        var count = 0;
        for (var i = haystack.IndexOf(needle, StringComparison.Ordinal); i >= 0;
             i = haystack.IndexOf(needle, i + needle.Length, StringComparison.Ordinal))
        {
            count++;
        }

        return count;
    }

    [Fact]
    public void Fixture436_RecursiveNamedConstructor_Runs_ByteExact()
    {
        var output = CSharpRunner.Run(
            CSharpCompiler.Compile(BallJson.Load(RepoPaths.Conformance("436_recursive_ctor_named.ball.json"))));
        Assert.Equal(Golden(RepoPaths.Conformance("436_recursive_ctor_named.expected_output.txt")), output);
    }

    [Fact]
    public void Fixture438_ConstructorInitializerListWithBody_Runs_ByteExact()
    {
        var output = CSharpRunner.Run(
            CSharpCompiler.Compile(BallJson.Load(RepoPaths.Conformance("438_ctor_initializer_list_with_body.ball.json"))));
        Assert.Equal(Golden(RepoPaths.Conformance("438_ctor_initializer_list_with_body.expected_output.txt")), output);
    }

    [Fact]
    public void ConstructorInitializerList_IsAppliedWhenTheConstructorHasABody()
    {
        var source = CSharpCompiler.Compile(BallJson.Load(RepoPaths.Conformance("438_ctor_initializer_list_with_body.ball.json")));
        // Non-parameter initializer values must be lowered, not left at Null.
        foreach (var want in new[] { "\"pt\"", "\"origin\"", "\"axis\"", "\"constants\"", "0.5" })
        {
            Assert.Contains(want, source, StringComparison.Ordinal);
        }
    }

    [Fact]
    public void UnnamedConstructor_IsNotShadowedByALaterNamedConstructor()
    {
        // `Point(3, 4)` (a messageCreation) must run Point's OWN constructor
        // body, not the last-indexed named constructor's. Its golden's first
        // three lines are 3 / 4 / pt!.
        var output = CSharpRunner.Run(
            CSharpCompiler.Compile(BallJson.Load(RepoPaths.Conformance("438_ctor_initializer_list_with_body.ball.json"))));
        Assert.StartsWith("3\n4\npt!\n", output, StringComparison.Ordinal);
    }
}
