using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.Loader;
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
/// Compiles emitted C# source in-memory with Roslyn against the running
/// runtime + <c>Ball.Shared</c>, executes its entry point, and captures
/// stdout — so a test can assert on the compiled program's <em>real</em>
/// output (the C# analog of the Rust suites shelling out to <c>rustc</c>).
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

        var originalOut = Console.Out;
        var writer = new StringWriter { NewLine = "\n" };
        Console.SetOut(writer);
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
        finally
        {
            Console.SetOut(originalOut);
        }

        return writer.ToString();
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
