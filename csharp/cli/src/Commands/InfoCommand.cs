namespace Ball.Cli.Commands;

/// <summary>
/// <c>ball info &lt;program&gt;</c> — inspect a Ball program's structure (issue #385, epic #361
/// cli-core adoption pattern).
///
/// <para>Delegates to the self-hosted <c>cli_core</c> verb <c>infoReport</c> (compiled from
/// <c>dart/shared/lib/cli_core.dart</c> via <c>dotnet run --project csharp/cli/tool</c> — see
/// <c>csharp/AGENTS.md</c>), byte-identical to <c>dart/cli/lib/src/runner.dart</c>'s
/// <c>_info</c> (which calls the same <c>cli_core.infoReport</c>). Behind the <c>CliCore</c>
/// MSBuild property — see <c>Ball.Cli.csproj</c>.</para>
/// </summary>
public static class InfoCommand
{
    /// <summary>Print the compiled <c>infoReport</c> for the program at <paramref name="programPath"/>.</summary>
    public static void Run(string programPath)
    {
#if CLI_CORE
        var engine = Loader.LoadEngine(programPath);
        var report = BallProgram.infoReport(engine.ProgramValue);
        Console.WriteLine(report.ToString());
#else
        // Loading still validates the input honestly (a missing/malformed file reports its own
        // CliIoError/CliParseError) before surfacing the feature gap — mirrors `run`'s
        // SelfHostPendingException pattern in Commands/RunCommand.cs.
        _ = Loader.LoadEngine(programPath);
        throw new CliRuntimeError(
            "`ball info` needs the self-hosted cli-core, built in via the `CliCore` MSBuild " +
            "property (off by default — see csharp/cli/Ball.Cli.csproj). Build with " +
            "`-p:CliCore=true` after regenerating csharp/cli/src/CompiledCli.cs (`dotnet run " +
            "--project csharp/cli/tool/Ball.Cli.Regen.csproj`, which itself needs " +
            "dart/self_host/cli.ball.json — see csharp/AGENTS.md).");
#endif
    }
}
