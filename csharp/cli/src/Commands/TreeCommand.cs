namespace Ball.Cli.Commands;

/// <summary>
/// <c>ball tree &lt;program&gt;</c> — print a Ball program's module/import dependency tree (issue
/// #385, epic #361 cli-core adoption pattern).
///
/// <para>Delegates to the self-hosted <c>cli_core</c> verb <c>treeReport</c> (compiled from
/// <c>dart/shared/lib/cli_core.dart</c> — see <c>csharp/AGENTS.md</c>), byte-identical to
/// <c>dart/cli/lib/src/runner.dart</c>'s <c>_tree</c>. Behind the <c>CliCore</c> MSBuild property
/// — see <c>Ball.Cli.csproj</c>.</para>
/// </summary>
public static class TreeCommand
{
    /// <summary>Print the compiled <c>treeReport</c> for the program at <paramref name="programPath"/>.</summary>
    public static void Run(string programPath)
    {
#if CLI_CORE
        var engine = Loader.LoadEngine(programPath);
        var report = BallProgram.treeReport(engine.ProgramValue);
        Console.WriteLine(report.ToString());
#else
        _ = Loader.LoadEngine(programPath);
        throw new CliRuntimeError(
            "`ball tree` needs the self-hosted cli-core, built in via the `CliCore` MSBuild " +
            "property (off by default — see csharp/cli/Ball.Cli.csproj). Build with " +
            "`-p:CliCore=true` after regenerating csharp/cli/src/CompiledCli.cs (`dotnet run " +
            "--project csharp/cli/tool/Ball.Cli.Regen.csproj`, which itself needs " +
            "dart/self_host/cli.ball.json — see csharp/AGENTS.md).");
#endif
    }
}
