using Ball.Compiler;

namespace Ball.Cli.Commands;

/// <summary>
/// <c>ball compile &lt;program&gt;</c> — Ball -&gt; C# source (issue #385).
/// </summary>
public static class CompileCommand
{
    /// <summary>
    /// Load <paramref name="programPath"/>, compile it via <see cref="CSharpCompiler"/>, and
    /// write the emitted C# source to <paramref name="output"/> (or stdout when
    /// <paramref name="output"/> is <see langword="null"/>).
    ///
    /// <para><see cref="CSharpCompiler.Compile"/> throws on a program shape it doesn't support
    /// (a missing entry module, an unregistered base call, ...) rather than silently degrading
    /// (see <c>csharp/compiler/src/CSharpCompiler.cs</c>'s dispatch tables) —
    /// <see cref="ExceptionGuard.Guard{T}"/> converts that into a <see cref="CliParseError"/>
    /// (exit <c>2</c>) instead of letting it escape as an unhandled exception.</para>
    /// </summary>
    public static void Run(string programPath, string? output)
    {
        var engine = Loader.LoadEngine(programPath);
        var csharpSource = ExceptionGuard.Guard(() => CSharpCompiler.Compile(engine.Program));
        Output.WriteText(output, csharpSource);
    }
}
