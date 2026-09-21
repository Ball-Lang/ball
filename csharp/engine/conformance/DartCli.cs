using System.Diagnostics;

namespace Ball.Engine.Conformance;

/// <summary>
/// The exact process launch one per-fixture Dart reference-engine run performs:
/// an executable plus the argument vector handed to it. Exposed (rather than
/// buried inside <see cref="DartCli.Run"/>) so the SHAPE of the launch is
/// assertable — issue #784's defect was entirely a property of that shape, and
/// a test that can only observe wall-clock time cannot name it.
/// </summary>
internal sealed record DartLaunchPlan(string FileName, IReadOnlyList<string> Arguments);

/// <summary>One finished Dart reference-engine run.</summary>
internal sealed record DartRunResult(string Stdout, string Stderr, int ExitCode, bool TimedOut);

/// <summary>
/// The round-trip leg's handle on the Dart reference CLI (<c>dart/cli/bin/ball.dart</c>),
/// which is ground truth for that leg: every re-encoded program is executed
/// there, not on the C# self-hosted engine.
///
/// <para><b>Prepared once, launched per fixture.</b> <see cref="Prepare"/> does
/// whatever setup the whole sweep shares; <see cref="Run"/> then costs one
/// process spawn per fixture. That split is the fix for issue #784 — see the
/// remarks on <see cref="Prepare"/>.</para>
/// </summary>
internal sealed class DartCli
{
    /// <summary>
    /// Per-fixture wall-clock cap. A re-encoded program that never terminates is
    /// the #55 class — structurally valid, <c>ball check</c>-clean, computing
    /// nothing — so the cap must stay, and the matrix row reds on ANY
    /// <c>TIMEOUT</c> status (issue #693, <c>tools/ci/roundtrip_floor.sh</c>).
    /// It budgets a fixture's own EXECUTION only: launching the reference CLI
    /// must not consume a meaningful part of it (issue #784).
    /// </summary>
    public static readonly TimeSpan FixtureTimeout = TimeSpan.FromSeconds(30);

    private readonly string dartExecutable;

    private DartCli(string dartExecutable, string workDir)
    {
        this.dartExecutable = dartExecutable;
        WorkDir = workDir;
    }

    /// <summary>The sweep-scoped scratch directory this instance was prepared into.</summary>
    public string WorkDir { get; }

    /// <summary>
    /// Prepare the reference CLI once for a whole sweep, materializing anything
    /// reusable under <paramref name="workDir"/> (the leg's temp directory,
    /// deleted when the sweep ends).
    /// </summary>
    public static DartCli Prepare(string dartExecutable, string workDir) => new(dartExecutable, workDir);

    /// <summary>The launch this instance performs for <paramref name="ballJsonPath"/>.</summary>
    public DartLaunchPlan PlanFor(string ballJsonPath)
    {
        var scriptPath = Path.Combine(Fixtures.RepoRoot, "dart", "cli", "bin", "ball.dart");

        // On Windows, the `dart` on PATH is typically a `.bat` shim (the SDK's
        // real dart.exe lives a few directories deeper) — .NET's Process.Start
        // resolves a bare command via CreateProcess, which (unlike a shell)
        // does not apply PATHEXT to find a batch script, so launching "dart"
        // directly throws Win32Exception "cannot find the file specified"
        // even though `dart` resolves fine in an interactive/CI shell. Route
        // through `cmd.exe /c` on Windows only; every other platform (CI runs
        // ubuntu-latest per the conformance-matrix precedent) invokes the
        // executable directly.
        if (OperatingSystem.IsWindows())
        {
            return new DartLaunchPlan(
                "cmd.exe",
                new[] { "/c", dartExecutable, "run", scriptPath, "run", ballJsonPath });
        }

        return new DartLaunchPlan(
            dartExecutable,
            new[] { "run", scriptPath, "run", ballJsonPath });
    }

    /// <summary>Run one <c>.ball.json</c> on the reference CLI.</summary>
    public DartRunResult Run(string ballJsonPath, TimeSpan timeout) => Launch(PlanFor(ballJsonPath), timeout);

    private static DartRunResult Launch(DartLaunchPlan plan, TimeSpan timeout)
    {
        var psi = new ProcessStartInfo(plan.FileName)
        {
            WorkingDirectory = Fixtures.RepoRoot,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };

        foreach (var argument in plan.Arguments)
        {
            psi.ArgumentList.Add(argument);
        }

        using var process = Process.Start(psi) ?? throw new InvalidOperationException($"failed to start '{plan.FileName}'");
        var stdoutTask = process.StandardOutput.ReadToEndAsync();
        var stderrTask = process.StandardError.ReadToEndAsync();
        var exited = process.WaitForExit((int)timeout.TotalMilliseconds);
        if (!exited)
        {
            try
            {
                process.Kill(entireProcessTree: true);
            }
            catch (InvalidOperationException)
            {
                // Already exited between the timeout check and Kill.
            }

            return new DartRunResult(string.Empty, string.Empty, -1, TimedOut: true);
        }

        return new DartRunResult(
            stdoutTask.GetAwaiter().GetResult(),
            stderrTask.GetAwaiter().GetResult(),
            process.ExitCode,
            TimedOut: false);
    }
}
