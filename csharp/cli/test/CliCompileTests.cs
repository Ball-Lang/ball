namespace Ball.Cli.Tests;

/// <summary><c>ball compile</c> — Ball -&gt; C# source. Mirrors <c>rust/cli/tests/cli_compile.rs</c>.</summary>
public sealed class CliCompileTests
{
    [Fact]
    public void Compiles_hello_world_to_csharp_source_on_stdout()
    {
        var program = TestPaths.RepoPath("examples", "hello_world", "hello_world.ball.json");
        var result = CliProcess.Run("compile", program);

        Assert.Equal(0, result.ExitCode);
        Assert.Contains("BallProgram", result.Stdout);
        Assert.Contains("Hello, World!", result.Stdout);
    }

    [Fact]
    public void Output_flag_writes_to_a_file_instead_of_stdout()
    {
        var program = TestPaths.RepoPath("examples", "hello_world", "hello_world.ball.json");
        var dir = Path.Combine(Path.GetTempPath(), $"ball_cli_test_compile_{Environment.ProcessId}");
        Directory.CreateDirectory(dir);
        try
        {
            var outputPath = Path.Combine(dir, "out.cs");
            var result = CliProcess.Run("compile", program, "--output", outputPath);

            Assert.Equal(0, result.ExitCode);
            Assert.Empty(result.Stdout);
            Assert.True(File.Exists(outputPath));
            Assert.Contains("Hello, World!", File.ReadAllText(outputPath));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public void Missing_file_is_an_io_error_exit_3()
    {
        var result = CliProcess.Run("compile", "does_not_exist.ball.json");
        Assert.Equal(3, result.ExitCode);
    }

    [Fact]
    public void Malformed_json_is_a_parse_error_exit_2()
    {
        var dir = Path.Combine(Path.GetTempPath(), $"ball_cli_test_compile_bad_{Environment.ProcessId}");
        Directory.CreateDirectory(dir);
        try
        {
            var path = Path.Combine(dir, "bad.ball.json");
            File.WriteAllText(path, "not json {{{");

            var result = CliProcess.Run("compile", path);
            Assert.Equal(2, result.ExitCode);
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }
}
