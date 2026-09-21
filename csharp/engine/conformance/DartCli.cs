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
/// <para><b>Prepared once, launched per fixture.</b> <see cref="Prepare"/>
/// AOT-compiles the CLI a single time for the whole sweep; <see cref="Run"/>
/// then costs one spawn of that native executable per fixture. That split is
/// the fix for issue #784 — see the remarks on <see cref="Prepare"/>.</para>
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

    /// <summary>
    /// Budget for the one-time <c>dart compile exe</c>. Measured at ~26 s on the
    /// Windows machine that filed #784, and less on a Linux runner; ten minutes
    /// is a hang detector, not a performance bound.
    /// </summary>
    private static readonly TimeSpan CompileTimeout = TimeSpan.FromMinutes(10);

    private readonly string preparedExecutable;

    private DartCli(string preparedExecutable, string workDir)
    {
        this.preparedExecutable = preparedExecutable;
        WorkDir = workDir;
    }

    /// <summary>The sweep-scoped scratch directory this instance was prepared into.</summary>
    public string WorkDir { get; }

    /// <summary>
    /// AOT-compile the reference CLI ONCE for a whole sweep, into
    /// <paramref name="workDir"/> (the leg's temp directory, deleted when the
    /// sweep ends), and answer a handle that launches that executable directly.
    ///
    /// <para><b>Why this, and not merely a bigger timeout (issue #784).</b> The
    /// leg used to spend one <c>dart run dart/cli/bin/ball.dart run …</c> per
    /// fixture. <c>dart run</c> of a package script re-resolves the package
    /// config and pays JIT front-end work on every invocation — measured at
    /// 15.8 s warm and 25–31 s cold on the reporting machine, where a
    /// <c>dart run</c> of a NONEXISTENT path costs 23 s: essentially all of it is
    /// startup and none of it the program. Against the 30 s per-fixture cap that
    /// turned ~14 fixtures CI counts as PASS into local <c>TIMEOUT</c>s, so the
    /// locally reported number stopped being a proxy for the gated one. A
    /// prepared native executable runs the same fixture in 42–74 ms, so the
    /// one-time compile pays for itself after about two fixtures of a 350+
    /// corpus — and the cap goes back to budgeting a fixture's own EXECUTION,
    /// which is what the no-fixture-may-hang gate (#693) needs it to mean.</para>
    ///
    /// <para>Preparation failure is LOUD: a non-zero <c>dart compile exe</c>, a
    /// missing output, or a compile that outlives <see cref="CompileTimeout"/>
    /// all throw. A sweep that quietly fell back to the per-fixture path would
    /// report the very undercount this method exists to remove.</para>
    /// </summary>
    public static DartCli Prepare(string dartExecutable, string workDir)
    {
        var scriptPath = Path.Combine(Fixtures.RepoRoot, "dart", "cli", "bin", "ball.dart");
        var exePath = Path.Combine(workDir, OperatingSystem.IsWindows() ? "ball_cli.exe" : "ball_cli");

        // `dart` itself still needs the shell on Windows — see the PATHEXT note
        // on CompilePlan — but that cost is paid HERE, once per sweep, rather
        // than once per fixture.
        var compile = Launch(CompilePlan(dartExecutable, scriptPath, exePath), CompileTimeout);
        if (compile.TimedOut)
        {
            throw new InvalidOperationException(
                $"`{dartExecutable} compile exe {scriptPath}` did not finish within {CompileTimeout.TotalMinutes:0} minutes");
        }

        if (compile.ExitCode != 0 || !File.Exists(exePath))
        {
            throw new InvalidOperationException(
                $"`{dartExecutable} compile exe {scriptPath}` failed (exit {compile.ExitCode}). The " +
                "Dart SDK plus a resolved workspace (`dart pub get` at the repo root) is a " +
                $"prerequisite of the round-trip leg.{Environment.NewLine}{compile.Stderr}{compile.Stdout}");
        }

        return new DartCli(exePath, workDir);
    }

    /// <summary>The launch this instance performs for <paramref name="ballJsonPath"/>.</summary>
    public DartLaunchPlan PlanFor(string ballJsonPath) =>
        new(preparedExecutable, new[] { "run", ballJsonPath });

    /// <summary>
    /// The one-time AOT compile. On Windows the <c>dart</c> on PATH is typically
    /// a <c>.bat</c> shim (the SDK's real <c>dart.exe</c> lives a few directories
    /// deeper) — .NET's <c>Process.Start</c> resolves a bare command via
    /// <c>CreateProcess</c>, which (unlike a shell) does not apply <c>PATHEXT</c>
    /// to find a batch script, so launching <c>dart</c> directly throws
    /// <c>Win32Exception</c> "cannot find the file specified" even though
    /// <c>dart</c> resolves fine in an interactive/CI shell. Route through
    /// <c>cmd.exe /c</c> there. What this step produces is a real executable, so
    /// no PER-FIXTURE launch needs the shell on any platform.
    /// </summary>
    private static DartLaunchPlan CompilePlan(string dartExecutable, string scriptPath, string exePath)
    {
        string[] arguments = ["compile", "exe", scriptPath, "-o", exePath];
        if (OperatingSystem.IsWindows())
        {
            return new DartLaunchPlan("cmd.exe", ["/c", dartExecutable, .. arguments]);
        }

        return new DartLaunchPlan(dartExecutable, arguments);
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
