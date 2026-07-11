#if SELF_HOST
using Ball.Engine;

namespace Ball.Engine.Tests;

/// <summary>
/// First-execution tests for the self-hosted engine (issue #383, Round 3) —
/// compiled only under <c>-p:SelfHost=true</c>, when the generated
/// <c>CompiledEngine.cs</c> and the driver are in the build. Loads a real Ball
/// program and runs it through the compiled engine, asserting byte-exact stdout
/// against the committed golden. The C# analog of Rust's <c>self_host_run</c>
/// acceptance tests.
/// </summary>
public sealed class SelfHostRunTests
{
    private static IReadOnlyList<string> Run(string relativePath)
    {
        var path = Path.Combine(TestPaths.RepoRoot(), relativePath);
        return BallEngine.FromJson(File.ReadAllText(path)).Run();
    }

    [Fact]
    public void HelloWorld_prints_the_greeting()
    {
        var output = Run(Path.Combine("examples", "hello_world", "hello_world.ball.json"));
        Assert.Equal(new[] { "Hello, World!" }, output);
    }

    [Fact]
    public void Fibonacci_prints_the_sequence()
    {
        var output = Run(Path.Combine("tests", "conformance", "28_fibonacci.ball.json"));
        var expected = ExpectedLines("28_fibonacci");
        Assert.Equal(expected, output);
    }

    /// <summary>
    /// Byte-exact conformance for the last self-host corpus residuals closed in
    /// this round (issue #383): the whole <c>tests/conformance/*.ball.json</c>
    /// corpus now runs through the compiled engine at Dart parity, and these are
    /// the three root-cause categories that brought it there — bytes-literal
    /// list/iterate ops, a two-variable <c>catch (e, stackTrace)</c> binding, and
    /// a <c>logical_and</c>/<c>logical_or</c> pattern merging its bindings back
    /// through the shared map. Guards against a silent regression in the runtime
    /// helpers / compiler emission those depend on.
    /// </summary>
    [Theory]
    [InlineData("399_bytes_literal")]
    [InlineData("300_enc_catch_stack")]
    [InlineData("258_logical_and_pattern")]
    public void Conformance_fixture_matches_golden(string fixture)
    {
        var output = Run(Path.Combine("tests", "conformance", fixture + ".ball.json"));
        Assert.Equal(ExpectedLines(fixture), output);
    }

    private static string[] ExpectedLines(string fixture) =>
        File.ReadAllText(
                Path.Combine(TestPaths.RepoRoot(), "tests", "conformance", fixture + ".expected_output.txt"))
            .Replace("\r\n", "\n")
            .TrimEnd('\n')
            .Split('\n');
}
#endif
