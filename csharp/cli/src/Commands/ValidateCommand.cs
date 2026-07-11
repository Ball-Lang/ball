namespace Ball.Cli.Commands;

/// <summary>
/// <c>ball validate &lt;program&gt;</c> — check a Ball program's validity (issue #385, epic #361
/// cli-core adoption pattern).
///
/// <para>Delegates to the self-hosted <c>cli_core</c> verbs <c>validateOk</c>/<c>validateReport</c>
/// (compiled from <c>dart/shared/lib/cli_core.dart</c> — see <c>csharp/AGENTS.md</c>),
/// byte-identical report text to <c>dart/cli/lib/src/runner.dart</c>'s <c>_validate</c>. Behind
/// the <c>CliCore</c> MSBuild property — see <c>Ball.Cli.csproj</c>.</para>
///
/// <para><b>Exit code note:</b> the Dart CLI exits <c>1</c> on an invalid program (its generic
/// "command failed" code — Dart has no exit-code contract of its own). This CLI's own documented
/// contract (<see cref="CliError"/>) reserves <c>1</c> for a <i>runtime</i> failure and <c>2</c>
/// for an <i>invalid/unparseable program</i> — a failed <c>ball validate</c> is squarely the
/// latter, so this maps to <see cref="CliParseError"/> (exit <c>2</c>) rather than mirroring
/// Dart's <c>1</c>. Text output still matches Dart exactly; only the numeric exit code is adapted
/// to this target's own (issue #385) contract — the same adaptation
/// <c>rust/cli/src/commands/validate.rs</c> makes, and the same one
/// <see cref="CheckCommand"/> already makes for structurally similar findings.</para>
/// </summary>
public static class ValidateCommand
{
    /// <summary>
    /// Print the compiled <c>validateReport</c> for the program at <paramref name="programPath"/>
    /// on success; throw <see cref="CliParseError"/> carrying that same report on failure.
    /// </summary>
    public static void Run(string programPath)
    {
#if CLI_CORE
        var engine = Loader.LoadEngine(programPath);
        var programValue = engine.ProgramValue;
        var ok = BallProgram.validateOk(programValue);
        var report = BallProgram.validateReport(programValue);
        if (ok is Ball.Shared.BallBool { Value: true })
        {
            Console.WriteLine(report.ToString());
        }
        else
        {
            throw new CliParseError(report.ToString() ?? string.Empty);
        }
#else
        _ = Loader.LoadEngine(programPath);
        throw new CliRuntimeError(
            "`ball validate` needs the self-hosted cli-core, built in via the `CliCore` MSBuild " +
            "property (off by default — see csharp/cli/Ball.Cli.csproj). Build with " +
            "`-p:CliCore=true` after regenerating csharp/cli/src/CompiledCli.cs (`dotnet run " +
            "--project csharp/cli/tool/Ball.Cli.Regen.csproj`, which itself needs " +
            "dart/self_host/cli.ball.json — see csharp/AGENTS.md).");
#endif
    }
}
