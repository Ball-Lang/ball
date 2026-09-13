using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.Loader;
using System.Text;
using System.Text.Json.Nodes;
using Google.Protobuf;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using BallV1Program = Ball.V1.Program;

namespace Ball.Compiler.Tests;

/// <summary>Locates repo-root-relative files at test time (walks up to the <c>dart/shared/std.json</c> marker).</summary>
internal static class RepoPaths
{
    public static string RepoRoot { get; } = FindRepoRoot();

    private static string FindRepoRoot([CallerFilePath] string callerFilePath = "")
    {
        foreach (var start in new[] { Path.GetDirectoryName(callerFilePath), AppContext.BaseDirectory })
        {
            var dir = start;
            while (!string.IsNullOrEmpty(dir))
            {
                if (File.Exists(Path.Combine(dir, "dart", "shared", "std.json")))
                {
                    return dir;
                }

                dir = Path.GetDirectoryName(dir);
            }
        }

        throw new InvalidOperationException("could not locate repo root (dart/shared/std.json marker not found)");
    }

    public static string Conformance(string fixture) =>
        Path.Combine(RepoRoot, "tests", "conformance", fixture);

    public static string Example(string name) =>
        Path.Combine(RepoRoot, "examples", name, name + ".ball.json");
}

/// <summary>
/// Loads a <c>.ball.json</c> program file (a proto3-JSON
/// <c>google.protobuf.Any</c> envelope — <c>"@type"</c> key + the message
/// body) into a <see cref="BallV1Program"/>, mirroring the canonical Dart
/// reader (<c>dart/shared/lib/ball_file.dart</c>): strip <c>@type</c>, parse
/// the remainder with <see cref="JsonParser"/>.
/// </summary>
internal static class BallJson
{
    private static readonly JsonParser Parser =
        new(JsonParser.Settings.Default.WithIgnoreUnknownFields(true));

    public static BallV1Program Load(string path)
    {
        var envelope = JsonNode.Parse(File.ReadAllText(path))!.AsObject();
        envelope.Remove("@type");
        return Parser.Parse<BallV1Program>(envelope.ToJsonString());
    }
}

/// <summary>
/// Per-execution-context stdout capture (issue #611).
///
/// <para><b>The defect this replaces.</b> The capture used to be a plain
/// <c>Console.SetOut(stringWriter)</c> around the invoke, serialised by a
/// <c>lock</c>. <c>Console.Out</c> is PROCESS-GLOBAL, so while that redirect was
/// installed <em>every</em> write anywhere in the process was captured — and a
/// lock only restrains the code that takes it. <c>Ball.Encoder.Tests</c> has a
/// writer that never did:
/// <c>RealWorldSweepTests.RealWorldSweep_ReportsHonestBaseline</c> ends with a bare
/// <c>Console.Write(report)</c> so a plain runner can grep its <c>Results:</c> line.
/// xUnit v3 puts each test class in its own collection and runs collections in
/// parallel by default (<see href="https://xunit.net/docs/running-tests-in-parallel"/>;
/// this repo ships no <c>xunit.runner.json</c> and no assembly-level
/// <c>CollectionBehavior</c> attribute that would turn it off), so that write could
/// land inside a sibling class's capture. On CI run 34732470492,
/// <c>BclStaticGuardCallTests.BucketIFixtureEncodesCompilesAndRuns</c> expected
/// <c>"BALL\n"</c> and read the sweep's
/// <c>"Results: 9 passed, 2 failed, 11 total\n…"</c> instead.</para>
///
/// <para><b>The fix, and why at this layer.</b> Rather than schedule around the
/// shared mutable state, remove it: <c>Console.Out</c> is swapped ONCE for a writer
/// that routes each write to the capture registered for the CALLING execution
/// context (an <see cref="AsyncLocal{T}"/>), and to the real console when there is
/// none. A capture therefore collects only what its own call tree wrote —
/// including work the program spawns, since <see cref="AsyncLocal{T}"/> flows with
/// <see cref="ExecutionContext"/> — and a foreign writer is unaffected no matter how
/// the runner schedules it. The alternative the issue offered, one
/// <c>[Collection]</c> with parallelisation disabled, would have serialised the
/// suite AND left the hole open for the next class that writes to
/// <c>Console</c> without joining it; xUnit's own docs are explicit that the
/// grouping is opt-in per class. Capture is now also lock-free, so compile+run legs
/// run concurrently again.</para>
///
/// <para><b>Installing once is safe — measured, not assumed.</b> Under <c>dotnet
/// test</c> the VSTest test host leaves <c>Console.Out</c> as a single
/// <c>System.IO.TextWriter+NullTextWriter</c>, the SAME instance observed from two
/// different test classes: xUnit v3 does not hand each test its own
/// <c>Console.Out</c>. So the passthrough captured at install time is stable, and an
/// uncaptured write is discarded there exactly as it was before this change (which is
/// why <c>RealWorldSweepTests</c> writes to <em>both</em> <c>ITestOutputHelper</c> and
/// <c>Console</c>, and why its stray write was invisible until a capture swallowed
/// it). <see cref="Install"/> still re-checks, so a host that did swap the writer
/// would be re-wrapped rather than silently losing the capture.</para>
/// </summary>
internal static class ConsoleCapture
{
    /// <summary>The capture in force for the current execution context, if any.</summary>
    private static readonly AsyncLocal<TextWriter?> Active = new();

    /// <summary>Guards the one-time <c>Console.SetOut</c> swap, nothing else.</summary>
    private static readonly Lock InstallLock = new();

    /// <summary>Run <paramref name="body"/> with stdout captured for this execution
    /// context only, and return what it wrote (<c>\n</c> line endings).</summary>
    public static string Capture(Action body)
    {
        Install();

        var sink = new StringWriter { NewLine = "\n" };
        var previous = Active.Value;
        // Synchronized: a captured program is free to write from threads it spawned,
        // and those inherit this capture through ExecutionContext.
        Active.Value = TextWriter.Synchronized(sink);
        try
        {
            body();
        }
        finally
        {
            Active.Value = previous;
        }

        return sink.ToString();
    }

    /// <summary>Idempotent: installs the router the first time, and re-installs it if
    /// something else has since taken over <c>Console.Out</c>.</summary>
    private static void Install()
    {
        if (Console.Out is RoutingWriter)
        {
            return;
        }

        lock (InstallLock)
        {
            if (Console.Out is not RoutingWriter)
            {
                Console.SetOut(new RoutingWriter(Console.Out));
            }
        }
    }

    /// <summary>
    /// The installed <c>Console.Out</c>. Every write is forwarded to the calling
    /// context's capture when there is one, otherwise to the console writer that was
    /// in place when this was installed. Each overload delegates explicitly (rather
    /// than falling through <see cref="TextWriter"/>'s defaults) so the target's own
    /// <see cref="TextWriter.NewLine"/> applies — that is what keeps a capture's line
    /// endings <c>\n</c> on Windows, exactly as the old <c>StringWriter</c> did.
    /// </summary>
    private sealed class RoutingWriter(TextWriter passthrough) : TextWriter
    {
        private TextWriter Target => Active.Value ?? passthrough;

        public override Encoding Encoding => passthrough.Encoding;

        public override void Write(char value) => Target.Write(value);

        public override void Write(string? value) => Target.Write(value);

        public override void Write(char[] buffer, int index, int count) => Target.Write(buffer, index, count);

        public override void Write(ReadOnlySpan<char> buffer) => Target.Write(buffer);

        public override void WriteLine() => Target.WriteLine();

        public override void WriteLine(string? value) => Target.WriteLine(value);

        public override void WriteLine(ReadOnlySpan<char> buffer) => Target.WriteLine(buffer);

        public override void Flush() => Target.Flush();
    }
}

/// <summary>
/// Compiles emitted C# source in-memory with Roslyn against the running
/// runtime + <c>Ball.Shared</c>, executes its entry point, and captures
/// stdout — so a test can assert on the compiled program's <em>real</em>
/// output (the C# analog of the Rust suites shelling out to <c>rustc</c>).
/// Capture is per-execution-context — see <see cref="ConsoleCapture"/>.
/// </summary>
internal static class CSharpRunner
{
    private static readonly MetadataReference[] References = BuildReferences();

    /// <summary>Compile + run <paramref name="source"/>, returning its stdout (with <c>\n</c> line endings preserved).</summary>
    public static string Run(string source)
    {
        var assembly = CompileToAssembly(source, out var diagnostics);
        if (assembly is null)
        {
            throw new InvalidOperationException(
                "compiled C# did not build:\n" + string.Join("\n", diagnostics)
                + "\n\n--- generated source ---\n" + source);
        }

        var entryPoint = assembly.EntryPoint
            ?? throw new InvalidOperationException("compiled program has no entry point");

        return ConsoleCapture.Capture(() =>
        {
            try
            {
                var parameters = entryPoint.GetParameters().Length == 1
                    ? new object?[] { Array.Empty<string>() }
                    : null;
                entryPoint.Invoke(null, parameters);
            }
            catch (TargetInvocationException ex)
            {
                throw ex.InnerException ?? ex;
            }
        });
    }

    /// <summary>Compile <paramref name="source"/> only, returning whether it built (for compile-only assertions).</summary>
    public static bool Compiles(string source, out IReadOnlyList<string> errors)
    {
        var assembly = CompileToAssembly(source, out var diagnostics);
        errors = diagnostics;
        return assembly is not null;
    }

    private static Assembly? CompileToAssembly(string source, out IReadOnlyList<string> errors)
    {
        var tree = CSharpSyntaxTree.ParseText(source);
        var compilation = CSharpCompilation.Create(
            "BallCompiled_" + Guid.NewGuid().ToString("N"),
            new[] { tree },
            References,
            new CSharpCompilationOptions(OutputKind.ConsoleApplication, optimizationLevel: OptimizationLevel.Release));

        using var stream = new MemoryStream();
        var result = compilation.Emit(stream);
        if (!result.Success)
        {
            errors = result.Diagnostics
                .Where(d => d.Severity == DiagnosticSeverity.Error)
                .Select(d => d.ToString())
                .ToList();
            return null;
        }

        errors = Array.Empty<string>();
        stream.Position = 0;
        return AssemblyLoadContext.Default.LoadFromStream(stream);
    }

    private static MetadataReference[] BuildReferences()
    {
        var refs = new List<MetadataReference>();
        var trusted = (string?)AppContext.GetData("TRUSTED_PLATFORM_ASSEMBLIES");
        if (trusted is not null)
        {
            foreach (var path in trusted.Split(Path.PathSeparator))
            {
                if (path.Length > 0)
                {
                    refs.Add(MetadataReference.CreateFromFile(path));
                }
            }
        }

        // Ball.Shared (BallValue/BallRuntime/…) and Google.Protobuf are what the
        // emitted code binds against — add them explicitly in case they are not
        // already in the trusted-platform set.
        refs.Add(MetadataReference.CreateFromFile(typeof(Ball.Shared.BallValue).Assembly.Location));
        refs.Add(MetadataReference.CreateFromFile(typeof(ByteString).Assembly.Location));
        return refs.DistinctBy(r => r.Display).ToArray();
    }
}
