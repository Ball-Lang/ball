namespace Ball.Cli.Tests;

/// <summary>General CLI wiring: --help, an unrecognized command, and the exit-code-0 happy path shape. Mirrors <c>rust/cli/tests/cli_general.rs</c>.</summary>
public sealed class CliGeneralTests
{
    [Fact]
    public void Help_lists_every_subcommand_and_exits_0()
    {
        var result = CliProcess.Run("--help");
        Assert.Equal(0, result.ExitCode);
        Assert.Contains("run", result.Stdout);
        Assert.Contains("compile", result.Stdout);
        Assert.Contains("encode", result.Stdout);
        Assert.Contains("check", result.Stdout);
        Assert.Contains("info", result.Stdout);
        Assert.Contains("validate", result.Stdout);
        Assert.Contains("tree", result.Stdout);
        Assert.Contains("version", result.Stdout);
    }

    [Fact]
    public void Subcommand_help_is_available()
    {
        var result = CliProcess.Run("run", "--help");
        Assert.Equal(0, result.ExitCode);
        Assert.Contains("program", result.Stdout);
    }

    [Fact]
    public void Version_subcommand_prints_a_ball_prefixed_version_and_exits_0()
    {
        var result = CliProcess.Run("version");
        Assert.Equal(0, result.ExitCode);
        Assert.StartsWith("ball ", result.Stdout);
        Assert.Empty(result.Stderr);
    }

    [Fact]
    public void Missing_subcommand_argument_is_a_usage_error_not_a_silent_success()
    {
        var result = CliProcess.Run("run");
        Assert.NotEqual(0, result.ExitCode);
    }
}
