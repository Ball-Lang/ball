namespace Ball.Cli.Tests;

/// <summary>
/// <c>ball run</c> — default-build honest degradation plus, under <c>-p:SelfHost=true</c>, real
/// execution. Mirrors <c>rust/cli/tests/cli_run.rs</c>.
/// </summary>
public sealed class CliRunTests
{
#if !SELF_HOST
    [Fact]
    public void Default_build_reports_self_host_pending_honestly_for_a_valid_program()
    {
        var program = TestPaths.RepoPath("examples", "hello_world", "hello_world.ball.json");
        var result = CliProcess.Run("run", program);

        Assert.Equal(1, result.ExitCode);
        Assert.Empty(result.Stdout);
        Assert.Contains("SelfHost", result.Stderr);
    }
#endif

#if SELF_HOST
    [Fact]
    public void Self_host_hello_world_prints_the_greeting()
    {
        var program = TestPaths.RepoPath("examples", "hello_world", "hello_world.ball.json");
        var result = CliProcess.Run("run", program);

        Assert.Equal(0, result.ExitCode);
        Assert.Equal("Hello, World!\n", result.Stdout);
        Assert.Empty(result.Stderr);
    }

    [Fact]
    public void Self_host_fibonacci_matches_dart()
    {
        var program = TestPaths.RepoPath("tests", "conformance", "28_fibonacci.ball.json");
        var expected = File.ReadAllText(TestPaths.RepoPath("tests", "conformance", "28_fibonacci.expected_output.txt"))
            .ReplaceLineEndings("\n");

        var result = CliProcess.Run("run", program);

        Assert.Equal(0, result.ExitCode);
        Assert.Equal(expected, result.Stdout.ReplaceLineEndings("\n"));
    }

    [Fact]
    public void Self_host_runs_a_ball_bin_binary_input_too()
    {
        var dir = Path.Combine(Path.GetTempPath(), $"ball_cli_test_run_bin_{Environment.ProcessId}");
        Directory.CreateDirectory(dir);
        try
        {
            var sourcePath = Path.Combine(dir, "hello.cs");
            File.WriteAllText(sourcePath, "Console.WriteLine(\"Hello, binary!\");");

            var binPath = Path.Combine(dir, "hello.ball.bin");
            var encodeResult = CliProcess.Run("encode", sourcePath, "--format", "binary", "--output", binPath);
            Assert.Equal(0, encodeResult.ExitCode);

            var runResult = CliProcess.Run("run", binPath);
            Assert.Equal(0, runResult.ExitCode);
            Assert.Equal("Hello, binary!\n", runResult.Stdout.ReplaceLineEndings("\n"));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }
#endif

    [Fact]
    public void Missing_file_is_an_io_error_exit_3()
    {
        var result = CliProcess.Run("run", "does_not_exist.ball.json");
        Assert.Equal(3, result.ExitCode);
        Assert.Empty(result.Stdout);
        Assert.Contains("ball:", result.Stderr);
    }

    [Fact]
    public void Malformed_json_is_a_parse_error_exit_2()
    {
        var dir = Path.Combine(Path.GetTempPath(), $"ball_cli_test_run_malformed_{Environment.ProcessId}");
        Directory.CreateDirectory(dir);
        try
        {
            var path = Path.Combine(dir, "bad.ball.json");
            File.WriteAllText(path, "not json at all {{{");

            var result = CliProcess.Run("run", path);

            Assert.Equal(2, result.ExitCode);
            Assert.Empty(result.Stdout);
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }
}
