namespace Ball.Compiler.Tests;

/// <summary>
/// The Phase-4 proof bar (issue #381): compile the canonical
/// <c>hello_world</c> example plus the <c>fibonacci</c> / <c>factorial</c>
/// conformance fixtures to C#, execute the result, and assert byte-exact
/// stdout against the committed golden output. This is the "compiles AND runs
/// the corpus" definition-of-done, in miniature.
/// </summary>
public class EndToEndTests
{
    private static string CompileAndRun(string ballJsonPath) =>
        CSharpRunner.Run(CSharpCompiler.Compile(BallJson.Load(ballJsonPath)));

    private static string Golden(string expectedFile) =>
        File.ReadAllText(expectedFile).Replace("\r\n", "\n");

    [Fact]
    public void HelloWorld_Compiles_And_Prints_Greeting()
    {
        var output = CompileAndRun(RepoPaths.Example("hello_world"));
        Assert.Equal("Hello, World!\n", output);
    }

    [Fact]
    public void Fibonacci_Compiles_And_Runs_ByteExact()
    {
        var output = CompileAndRun(RepoPaths.Conformance("28_fibonacci.ball.json"));
        Assert.Equal(Golden(RepoPaths.Conformance("28_fibonacci.expected_output.txt")), output);
    }

    [Fact]
    public void Factorial_Compiles_And_Runs_ByteExact()
    {
        var output = CompileAndRun(RepoPaths.Conformance("57_recursion_factorial.ball.json"));
        Assert.Equal(Golden(RepoPaths.Conformance("57_recursion_factorial.expected_output.txt")), output);
    }

    [Fact]
    public void ComplexControlFlow_Fixture100_Runs_ByteExact()
    {
        // Nested loops with continue/break + compound assignment + a while loop
        // — the block-lowering readability micro-benchmark named in issue #381.
        var output = CompileAndRun(RepoPaths.Conformance("100_complex_control_flow.ball.json"));
        Assert.Equal(Golden(RepoPaths.Conformance("100_complex_control_flow.expected_output.txt")), output);
    }
}
