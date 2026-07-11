using System.Reflection;
using System.Runtime.Loader;
using Google.Protobuf;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;

namespace Ball.Engine.Conformance;

/// <summary>
/// Compiles emitted C# source in-memory with Roslyn against the running
/// runtime + <c>Ball.Shared</c>, executes its entry point, and captures
/// stdout. The conformance harness's copy of
/// <c>csharp/compiler/test/TestSupport.cs</c>'s <c>CSharpRunner</c> — kept as
/// a small, self-contained duplicate rather than a cross-project dependency
/// on the compiler test assembly (test assemblies are not meant to be
/// referenced as libraries), returning outcomes instead of throwing so a
/// single fixture's compile/run failure never aborts the whole corpus sweep.
/// </summary>
internal static class CSharpRunner
{
    private static readonly MetadataReference[] References = BuildReferences();

    /// <summary>Compile + run <paramref name="source"/>. Never throws — failures are reported via <see cref="RunOutcome"/>.</summary>
    public static RunOutcome Run(string source)
    {
        Assembly assembly;
        try
        {
            var compiled = CompileToAssembly(source, out var diagnostics);
            if (compiled is null)
            {
                return RunOutcome.CompileError(string.Join("; ", diagnostics));
            }

            assembly = compiled;
        }
        catch (Exception ex)
        {
            return RunOutcome.CompileError(ex.Message);
        }

        var entryPoint = assembly.EntryPoint;
        if (entryPoint is null)
        {
            return RunOutcome.CompileError("compiled program has no entry point");
        }

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
            return RunOutcome.RuntimeError((ex.InnerException ?? ex).Message);
        }
        catch (Exception ex)
        {
            return RunOutcome.RuntimeError(ex.Message);
        }
        finally
        {
            Console.SetOut(originalOut);
        }

        return RunOutcome.Ok(writer.ToString());
    }

    private static Assembly? CompileToAssembly(string source, out IReadOnlyList<string> errors)
    {
        var tree = CSharpSyntaxTree.ParseText(source);
        var compilation = CSharpCompilation.Create(
            "BallConformance_" + Guid.NewGuid().ToString("N"),
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

        refs.Add(MetadataReference.CreateFromFile(typeof(Ball.Shared.BallValue).Assembly.Location));
        refs.Add(MetadataReference.CreateFromFile(typeof(ByteString).Assembly.Location));
        return refs.DistinctBy(r => r.Display).ToArray();
    }
}

/// <summary>The result of compiling + running one C# source: success with stdout, or a categorized failure.</summary>
internal sealed class RunOutcome
{
    private RunOutcome(bool success, string? stdout, string? error)
    {
        Success = success;
        Stdout = stdout;
        Error = error;
    }

    public bool Success { get; }

    public string? Stdout { get; }

    public string? Error { get; }

    public static RunOutcome Ok(string stdout) => new(true, stdout, null);

    public static RunOutcome CompileError(string message) => new(false, null, $"compile: {message}");

    public static RunOutcome RuntimeError(string message) => new(false, null, $"runtime: {message}");
}
