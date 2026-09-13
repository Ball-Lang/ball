using System.Collections.Generic;
using Microsoft.CodeAnalysis.CSharp;

namespace Ball.Encoder;

/// <summary>
/// One Roslyn <see cref="CSharpCompilation"/> built over a whole source directory, plus the
/// file set that went into it and the error diagnostics it reported — the resolved context
/// <see cref="CSharpEncoder.EncodeFileInProject"/> encodes individual files against.
///
/// <para>This is the C# analogue of <c>dart/encoder/lib/package_encoder.dart</c>'s
/// <c>prepareStaticTypes()</c>: resolve the package ONCE, then encode file by file. Keeping
/// the two steps separate is what lets the Tier A instrument stay on its file-at-a-time basis
/// — a whole-project, abort-on-first-error encode cannot produce a per-file funnel at
/// all.</para>
/// </summary>
/// <param name="Compilation">The bound compilation. One
/// <see cref="Microsoft.CodeAnalysis.SemanticModel"/> per tree is cached behind it (Roslyn's
/// own guidance: "it is much more efficient to use a single instance of SemanticModel when
/// asking multiple questions about a syntax tree").</param>
/// <param name="Files">Absolute paths of the compiled sources, in sweep order.</param>
/// <param name="CompilationDiagnostics">Error diagnostics about the input — surfaced, never
/// swallowed.</param>
public sealed record ProjectCompilation(
    CSharpCompilation Compilation,
    IReadOnlyList<string> Files,
    IReadOnlyList<string> CompilationDiagnostics);

/// <summary>
/// Inputs to the project-wide, semantic-model-backed encode seam
/// (<see cref="CSharpEncoder.EncodeProject"/> — issue #492, W12-C slice 1).
/// </summary>
public sealed record ProjectEncodeOptions
{
    /// <summary>
    /// Paths to the reference assemblies the compilation binds against.
    ///
    /// <para><c>null</c> (the default) means "the version-pinned net10.0 reference set" — it
    /// does <b>not</b> mean "no references". An EMPTY list is a loud
    /// <see cref="EncoderException"/> rather than a reference-less compilation: without a
    /// corlib every BCL symbol becomes unresolvable, and an encoder that answers WRONGLY is
    /// worse than one that answers not-at-all.</para>
    /// </summary>
    public IReadOnlyList<string>? ReferencePaths { get; init; }

    /// <summary>
    /// <c>#define</c>d preprocessor symbols, fed to <c>CSharpParseOptions</c>. A first-class
    /// input because real projects need them: Newtonsoft.Json's own build defines
    /// <c>HAVE_LINQ</c>, and without it 177 call sites bind to its polyfill <c>Func&lt;&gt;</c>
    /// instead of <c>System.Func&lt;&gt;</c>.
    /// </summary>
    public IReadOnlyList<string> Defines { get; init; } = [];

    /// <summary>Directory names (any depth) whose files are not source — build output.</summary>
    public IReadOnlyList<string> ExcludeDirectories { get; init; } = ["bin", "obj"];

    /// <summary>
    /// Filename suffixes excluded as generated, not hand-written, source. Mirrors
    /// <c>csharp/coverage-study</c>'s own <c>CsFilesUnder</c> filter exactly, so the Tier A
    /// instrument and this seam sweep the same file set.
    /// </summary>
    public IReadOnlyList<string> ExcludeSuffixes { get; init; } =
        [".Designer.cs", ".g.cs", ".generated.cs"];

    /// <summary>Require an entry point, as <see cref="CSharpEncoder.Encode"/> does, instead of
    /// accepting an entry-point-less library project.</summary>
    public bool RequireEntryPoint { get; init; }
}

/// <summary>
/// The outcome of <see cref="CSharpEncoder.EncodeProject"/>: the encoded program, the exact
/// file set that went into it, and the compilation's own error diagnostics.
/// </summary>
/// <param name="Program">The encoded Ball program — one flat <c>"main"</c> module.</param>
/// <param name="Files">Every source file that was compiled, in sweep order. An explicit,
/// printed input: a surprising sweep must be visible rather than inferred.</param>
/// <param name="CompilationDiagnostics">Roslyn error diagnostics about the INPUT (a missing
/// third-party dependency, a missing <c>#define</c>). Surfaced, never swallowed — and never
/// fatal on their own, because Roslyn binds nearly everything in an error-bearing compilation
/// and a call site it could not bind still ends at a loud
/// <see cref="EncoderException"/>.</param>
public sealed record ProjectEncodeResult(
    Ball.V1.Program Program,
    IReadOnlyList<string> Files,
    IReadOnlyList<string> CompilationDiagnostics);
