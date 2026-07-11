using System.Text;
using Ball.Compiler;
using Ball.V1;

namespace Ball.Cli.Commands;

/// <summary>
/// <c>ball check &lt;program&gt;</c> — parse/validate a Ball program without running it (issue
/// #385).
/// </summary>
public static class CheckCommand
{
    /// <summary>
    /// Load <paramref name="programPath"/> (an I/O/parse failure here is the same as every other
    /// subcommand's — see <see cref="Loader"/>), then run a battery of structural checks against
    /// the loaded <see cref="Program"/> — mirrors <c>dart/cli/lib/src/runner.dart</c>'s
    /// <c>_validate</c> / <c>rust/cli/src/commands/check.rs</c>:
    /// <list type="bullet">
    /// <item><c>entry_module</c>/<c>entry_function</c> are set and resolve to a real module and function.</item>
    /// <item>Every module has a non-empty, unique name.</item>
    /// <item>Every non-base function carries a body or metadata (a bodiless, non-base function is malformed — base functions are the only ones allowed to omit a body).</item>
    /// </list>
    ///
    /// <para>When <paramref name="alsoCompile"/> is set (<c>ball check --compile</c>),
    /// additionally attempts a dry-run <see cref="CSharpCompiler"/> compile (output discarded) —
    /// a stronger, C#-target-specific check that catches shapes the structural checks above don't
    /// (an unregistered base call, an unsupported construct), at the cost of false positives for
    /// a program that is valid Ball but hits one of the compiler's documented scope gaps — hence
    /// opt-in rather than the default.</para>
    ///
    /// <para>Any finding is reported as a single <see cref="CliParseError"/> (exit <c>2</c>)
    /// listing every problem found, never a partial/silent failure. Success prints a one-line
    /// summary to stdout and returns normally (exit <c>0</c>).</para>
    /// </summary>
    public static void Run(string programPath, bool alsoCompile)
    {
        var engine = Loader.LoadEngine(programPath);
        var program = engine.Program;

        var errors = ValidateStructure(program);

        if (alsoCompile && errors.Count == 0)
        {
            try
            {
                CSharpCompiler.Compile(program);
            }
            catch (Exception e)
            {
                errors.Add($"does not compile to C#: {e.Message}");
            }
        }

        if (errors.Count > 0)
        {
            var message = new StringBuilder($"invalid program: {errors.Count} error(s) found");
            foreach (var err in errors)
            {
                message.Append($"\n  - {err}");
            }

            throw new CliParseError(message.ToString());
        }

        var functionCount = program.Modules.Sum(m => m.Functions.Count);
        Console.WriteLine($"Valid: \"{program.Name}\" v{program.Version}");
        Console.WriteLine($"  {program.Modules.Count} module(s), {functionCount} function(s)");
    }

    /// <summary>
    /// The structural checks proper — a plain list of human-readable findings, empty when the
    /// program is structurally sound. Split out from <see cref="Run"/> so it stays trivially
    /// unit-testable without a filesystem round trip.
    /// </summary>
    internal static List<string> ValidateStructure(Program program)
    {
        var errors = new List<string>();

        if (string.IsNullOrEmpty(program.EntryModule))
        {
            errors.Add("missing entry_module");
        }

        if (string.IsNullOrEmpty(program.EntryFunction))
        {
            errors.Add("missing entry_function");
        }

        if (!string.IsNullOrEmpty(program.EntryModule) && !string.IsNullOrEmpty(program.EntryFunction))
        {
            var entryModule = program.Modules.FirstOrDefault(m => m.Name == program.EntryModule);
            if (entryModule is null)
            {
                errors.Add($"entry module \"{program.EntryModule}\" not found in modules");
            }
            else if (!entryModule.Functions.Any(f => f.Name == program.EntryFunction))
            {
                errors.Add(
                    $"entry function \"{program.EntryFunction}\" not found in module \"{program.EntryModule}\"");
            }
        }

        for (var index = 0; index < program.Modules.Count; index++)
        {
            if (string.IsNullOrEmpty(program.Modules[index].Name))
            {
                errors.Add($"module at index {index} has no name");
            }
        }

        var seenNames = new HashSet<string>();
        foreach (var module in program.Modules)
        {
            if (!string.IsNullOrEmpty(module.Name) && !seenNames.Add(module.Name))
            {
                errors.Add($"duplicate module name: \"{module.Name}\"");
            }
        }

        foreach (var module in program.Modules)
        {
            foreach (var func in module.Functions)
            {
                if (!func.IsBase && func.Body is null && func.Metadata is null)
                {
                    errors.Add($"{module.Name}.{func.Name}: non-base function with no body or metadata");
                }
            }
        }

        return errors;
    }
}
