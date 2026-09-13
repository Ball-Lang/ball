using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;

namespace Ball.Encoder;

/// <summary>
/// Builds the one <see cref="CSharpCompilation"/> a project encode resolves against
/// (issue #492, W12-C slice 1).
///
/// <para><b>Reference assemblies are hermetic and version-pinned.</b> They come from
/// <c>Basic.Reference.Assemblies.Net100</c>, pinned in <c>csharp/Directory.Packages.props</c>
/// next to <c>Microsoft.CodeAnalysis.CSharp</c>. The obvious alternative — the SDK's own ref
/// pack under <c>$DOTNET_ROOT/packs/Microsoft.NETCore.App.Ref/&lt;ver&gt;/ref/net10.0</c> — is
/// deliberately NOT used: CI pins <c>dotnet-version: "10.0.x"</c>, so that <c>&lt;ver&gt;</c>
/// floats with whatever patch the runner happens to have and the encoder's answers would drift
/// with it. A CPM-pinned NuGet package restores from the existing cache (already keyed on
/// <c>Directory.Packages.props</c>) and changes only when someone bumps it deliberately.</para>
///
/// <para><b>Every reference failure is loud.</b> An empty reference list and an unreadable
/// reference path both throw. Continuing with a partial reference set would make the
/// compilation answer <em>wrongly</em> rather than <em>not-at-all</em>, which is precisely the
/// failure this seam exists to remove. That is a deliberate divergence from the Dart sibling
/// (<c>dart/encoder/lib/package_encoder.dart</c>'s <c>prepareStaticTypes</c> is documented
/// "Opt-in and fail-soft by design"): there, an unresolved package silently leaves
/// <c>staticType</c> null and the encoder falls back to its name heuristics, which is safe
/// because that fallback is the ONLY behaviour that path ever promised. Here the whole point of
/// the entry point is that the answers are symbol-grade, so degrading to heuristics would be a
/// silent fail-soft inside the mode advertised as resolved.</para>
/// </summary>
internal static class ProjectCompilationBuilder
{
    /// <summary>The assembly name given to the throwaway compilation. Never emitted — the
    /// compilation exists only to be asked questions.</summary>
    private const string AssemblyName = "ball_encode_project";

    internal static ProjectCompilation Build(string directory, ProjectEncodeOptions? options)
    {
        options ??= new ProjectEncodeOptions();

        if (!Directory.Exists(directory))
        {
            throw new EncoderException(
                $"ball-encoder: project directory `{directory}` does not exist");
        }

        var files = EnumerateSources(directory, options);
        if (files.Count == 0)
        {
            throw new EncoderException(
                $"ball-encoder: project directory `{directory}` holds no C# source after " +
                $"exclusions (directories: {Describe(options.ExcludeDirectories)}; suffixes: " +
                $"{Describe(options.ExcludeSuffixes)})");
        }

        var parseOptions = new CSharpParseOptions(
            LanguageVersion.Latest,
            preprocessorSymbols: options.Defines);

        var trees = new List<SyntaxTree>(files.Count);
        foreach (var path in files)
        {
            string text;
            try
            {
                // Read as BYTES and decode explicitly, exactly as the Tier A instrument does:
                // no newline translation, so a semantic lone \r survives into the encode.
                text = Encoding.UTF8.GetString(File.ReadAllBytes(path));
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                throw new EncoderException(
                    $"ball-encoder: could not read project source `{path}`: {ex.Message}");
            }

            var tree = CSharpSyntaxTree.ParseText(text, parseOptions, path: path);
            var errors = tree.GetDiagnostics()
                .Where(d => d.Severity == DiagnosticSeverity.Error)
                .ToList();
            if (errors.Count > 0)
            {
                throw new EncoderException(
                    $"ball-encoder: failed to parse C# source `{path}`: " +
                    string.Join("; ", errors));
            }

            trees.Add(tree);
        }

        var compilation = CSharpCompilation.Create(
            AssemblyName,
            trees,
            ResolveReferences(options),
            // `allowUnsafe` so that BINDING succeeds over pointer-bearing source. The encoder
            // still throws on the unsafe constructs themselves — symbols make the error
            // message better, never the construct representable.
            new CSharpCompilationOptions(OutputKind.DynamicallyLinkedLibrary, allowUnsafe: true));

        // Surfaced, never swallowed, and never fatal on its own: over third-party source these
        // are dominated by dependencies and `#define`s the caller may legitimately not have,
        // and Roslyn binds nearly everything in an error-bearing compilation anyway. A call
        // site it could NOT bind still ends at a loud EncoderException — in project mode even
        // the receiver-discriminated name routes refuse to guess (see Methods.cs's
        // GuardReceiverDiscriminatedCall).
        var diagnostics = compilation.GetDiagnostics()
            .Where(d => d.Severity == DiagnosticSeverity.Error)
            .Select(d => d.ToString())
            .ToList();

        return new ProjectCompilation(compilation, files, diagnostics);
    }

    /// <summary>
    /// Every hand-written <c>.cs</c> file under <paramref name="directory"/>, sorted ordinal so
    /// the encode is deterministic. The filter mirrors <c>csharp/coverage-study</c>'s own
    /// <c>CsFilesUnder</c> exactly, so the Tier A instrument and this seam sweep the same set:
    /// build output plus the generated-file suffixes nobody hand-wrote.
    /// </summary>
    internal static List<string> EnumerateSources(string directory, ProjectEncodeOptions options)
    {
        var excludedDirs = new HashSet<string>(options.ExcludeDirectories, StringComparer.OrdinalIgnoreCase);
        return Directory.EnumerateFiles(directory, "*.cs", SearchOption.AllDirectories)
            .Where(path =>
            {
                var relative = Path.GetRelativePath(directory, path).Replace('\\', '/');
                if (relative.Split('/').SkipLast(1).Any(excludedDirs.Contains))
                {
                    return false;
                }

                return !options.ExcludeSuffixes.Any(
                    suffix => relative.EndsWith(suffix, StringComparison.OrdinalIgnoreCase));
            })
            .Select(Path.GetFullPath)
            .OrderBy(path => path, StringComparer.Ordinal)
            .ToList();
    }

    private static IReadOnlyList<MetadataReference> ResolveReferences(ProjectEncodeOptions options)
    {
        if (options.ReferencePaths is null)
        {
            return Basic.Reference.Assemblies.Net100.References.All;
        }

        if (options.ReferencePaths.Count == 0)
        {
            throw new EncoderException(
                "ball-encoder: ProjectEncodeOptions.ReferencePaths is empty — pass null for the " +
                "pinned net10.0 reference set. A compilation with no reference assemblies makes " +
                "every BCL symbol unresolvable, which would answer wrongly rather than not at all");
        }

        var references = new List<MetadataReference>(options.ReferencePaths.Count);
        foreach (var path in options.ReferencePaths)
        {
            try
            {
                references.Add(MetadataReference.CreateFromFile(path));
            }
            catch (Exception ex) when (ex is ArgumentException or IOException)
            {
                throw new EncoderException(
                    $"ball-encoder: could not read reference assembly `{path}`: {ex.Message}. " +
                    "A partial reference set is never continued with — it would make the " +
                    "compilation answer wrongly instead of not at all");
            }
        }

        return references;
    }

    private static string Describe(IReadOnlyList<string> values) =>
        values.Count == 0 ? "none" : string.Join(", ", values);
}
