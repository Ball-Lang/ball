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
        var expected = File.ReadAllText(
                Path.Combine(TestPaths.RepoRoot(), "tests", "conformance", "28_fibonacci.expected_output.txt"))
            .Replace("\r\n", "\n")
            .TrimEnd('\n')
            .Split('\n');
        Assert.Equal(expected, output);
    }
}
#endif
