using Ball.Engine;

namespace Ball.Cli.Commands;

/// <summary>
/// <c>ball run &lt;program&gt;</c> — load and execute a Ball program (issue #385).
/// </summary>
public static class RunCommand
{
    /// <summary>
    /// Load <paramref name="programPath"/> and execute it via <see cref="Ball.Engine.BallEngine"/>,
    /// writing each captured stdout line to the real process stdout.
    ///
    /// <para><b>Self-host status:</b> without the <c>SelfHost</c> MSBuild property (off by
    /// default — see <c>csharp/engine/Ball.Engine.csproj</c>), <see cref="BallEngine.Run"/>
    /// always throws <see cref="SelfHostPendingException"/>, which surfaces here as a
    /// <see cref="CliRuntimeError"/> (exit <c>1</c>) — a program never silently "succeeds"
    /// without actually running. Built with <c>-p:SelfHost=true</c> (after regenerating
    /// <c>csharp/engine/src/CompiledEngine.cs</c> — see <c>csharp/AGENTS.md</c>), <c>run</c>
    /// executes the self-hosted engine for real. Either way, whatever the engine returns or
    /// throws is surfaced here faithfully, never swallowed.</para>
    /// </summary>
    public static void Run(string programPath)
    {
        var engine = Loader.LoadEngine(programPath);
        IReadOnlyList<string> lines;
        try
        {
            lines = engine.Run();
        }
        catch (SelfHostPendingException e)
        {
            throw new CliRuntimeError(e.Message);
        }
        catch (EngineException e)
        {
            throw new CliRuntimeError(e.Message);
        }

        foreach (var line in lines)
        {
            Console.WriteLine(line);
        }
    }
}
