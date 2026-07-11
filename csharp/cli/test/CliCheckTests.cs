namespace Ball.Cli.Tests;

/// <summary><c>ball check</c> — structural validation, plus the opt-in <c>--compile</c> dry-run. Mirrors <c>rust/cli/tests/cli_check.rs</c>.</summary>
public sealed class CliCheckTests
{
    [Fact]
    public void A_well_formed_program_is_valid()
    {
        var program = TestPaths.RepoPath("examples", "hello_world", "hello_world.ball.json");
        var result = CliProcess.Run("check", program);

        Assert.Equal(0, result.ExitCode);
        Assert.Contains("Valid:", result.Stdout);
    }

    [Fact]
    public void Compile_flag_also_dry_run_compiles()
    {
        var program = TestPaths.RepoPath("examples", "hello_world", "hello_world.ball.json");
        var result = CliProcess.Run("check", program, "--compile");

        Assert.Equal(0, result.ExitCode);
        Assert.Contains("Valid:", result.Stdout);
    }

    [Fact]
    public void A_structurally_invalid_program_is_a_parse_error_exit_2()
    {
        var dir = Path.Combine(Path.GetTempPath(), $"ball_cli_test_check_invalid_{Environment.ProcessId}");
        Directory.CreateDirectory(dir);
        try
        {
            var path = Path.Combine(dir, "invalid.ball.json");
            File.WriteAllText(
                path,
                """{"@type":"type.googleapis.com/ball.v1.Program","name":"bad","version":"1.0.0"}""");

            var result = CliProcess.Run("check", path);

            Assert.Equal(2, result.ExitCode);
            Assert.Empty(result.Stdout);
            Assert.Contains("missing entry_module", result.Stderr);
            Assert.Contains("missing entry_function", result.Stderr);
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public void Missing_file_is_an_io_error_exit_3()
    {
        var result = CliProcess.Run("check", "does_not_exist.ball.json");
        Assert.Equal(3, result.ExitCode);
    }
}
