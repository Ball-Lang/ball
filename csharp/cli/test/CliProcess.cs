using System.Diagnostics;

namespace Ball.Cli.Tests;

/// <summary>
/// Spawns the actual built <c>ball</c> binary and captures stdout/stderr/exit code — the C#
/// analog of <c>rust/cli/tests/common/mod.rs</c>'s <c>Command::new(env!("CARGO_BIN_EXE_ball"))</c>
/// helper. Black-box, end-to-end: exercises the real <c>System.CommandLine</c> wiring and
/// <see cref="CliError"/> -&gt; exit-code mapping in <c>Program.cs</c>, not just the
/// <c>Commands/*.cs</c> methods in isolation.
///
/// <para>Locates <c>ball.dll</c> next to the test assembly: this test project's
/// <c>ProjectReference</c> on <c>Ball.Cli.csproj</c> copies the referenced exe's output
/// (<c>ball.dll</c>/<c>.deps.json</c>/<c>.runtimeconfig.json</c>) into this project's own output
/// directory as a normal build dependency, so no extra wiring is needed to find it.</para>
/// </summary>
internal static class CliProcess
{
    private static readonly string BallDllPath = Path.Combine(AppContext.BaseDirectory, "ball.dll");

    /// <summary>The result of running the CLI once: captured stdout, stderr, and process exit code.</summary>
    public sealed record Result(string Stdout, string Stderr, int ExitCode);

    /// <summary>
    /// Run <c>ball</c> with <paramref name="args"/> (working directory = the repo root, so
    /// relative fixture paths like <c>examples/hello_world/hello_world.ball.json</c> resolve),
    /// and return its captured stdout/stderr/exit code.
    /// </summary>
    public static Result Run(params string[] args)
    {
        Assert.True(File.Exists(BallDllPath), $"ball.dll not found at {BallDllPath} — build Ball.Cli.csproj first.");

        var startInfo = new ProcessStartInfo("dotnet")
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            WorkingDirectory = TestPaths.RepoRoot(),
        };
        startInfo.ArgumentList.Add("exec");
        startInfo.ArgumentList.Add(BallDllPath);
        foreach (var arg in args)
        {
            startInfo.ArgumentList.Add(arg);
        }

        using var process = Process.Start(startInfo)
            ?? throw new InvalidOperationException("failed to start the ball process");
        var stdout = process.StandardOutput.ReadToEnd();
        var stderr = process.StandardError.ReadToEnd();
        process.WaitForExit();
        return new Result(stdout, stderr, process.ExitCode);
    }
}
