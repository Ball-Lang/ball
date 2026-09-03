using System.Text;
using System.Text.Json.Nodes;
using Ball.Compiler;
using Ball.Encoder;
using Ball.V1;
using Google.Protobuf;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

namespace Ball.CoverageStudy;

/// <summary>One file's verdict. Mirrors rq1_study.dart's <c>FileResult</c>.</summary>
/// <param name="Package">The pinned package the file came from.</param>
/// <param name="File">The file's path relative to the studied subtree.</param>
/// <param name="Scored">False for files with nothing to compile (a
/// directives-only file, a generated stub). Not counted in the Tier A
/// denominator — a file with no declarations is not evidence either way.</param>
/// <param name="Clean">Survived every scored stage.</param>
/// <param name="IrStable">INFORMATIONAL, not part of <paramref name="Clean"/>:
/// the metadata-stripped Ball IR of the re-encoded output is identical to the
/// first pass.</param>
/// <param name="Reason">Taxonomy tag plus detail, e.g. <c>encode-error: …</c>.</param>
public sealed record FileResult(
    string Package,
    string File,
    bool Scored,
    bool Clean,
    bool IrStable,
    string Reason);

/// <summary>Tier A of the third-party coverage study — C# port (issue #493).
///
/// <para>For every .cs file of a pinned third-party library, does</para>
///
/// <code>C# source -> CSharpEncoder.EncodeLibrary -> CSharpCompiler.Compile
///             -> C# source -> CSharpEncoder.EncodeLibrary</code>
///
/// <para>come back with the same declarations and the same semantic Ball IR? A
/// file is clean only when it encodes, compiles back, re-encodes, keeps every
/// declaration it started with, and reaches a SECOND-GENERATION FIXPOINT
/// (compiling the re-encoded program again produces the same C# and the same
/// metadata-stripped IR). Cleanliness is deliberately strict; the first
/// baselines are expected to be low, and measuring that honestly is the
/// point.</para>
///
/// <para><b>The load-bearing setting: library-mode encoding, never
/// <c>Encode</c>.</b> Real class libraries have no <c>Main</c>, and
/// <see cref="CSharpEncoder.Encode"/> throws on every one of them.
/// <see cref="CSharpEncoder.EncodeLibrary"/> (issue #492) is the opt-in that
/// accepts them, and <see cref="CSharpCompiler.Compile"/> already tolerates the
/// resulting entry-function-less <see cref="Program"/> — it emits
/// <c>Main</c> only when the entry function exists. Reaching for
/// <c>Encode</c> here would silently skip exactly the files #493 exists to
/// look at.</para>
/// </summary>
public static class TierA
{
    /// <summary>How far a scored file got, keyed by taxonomy tag. The clean
    /// percentage alone cannot tell "the encoder rejected the file outright"
    /// from "everything worked but generation three drifted", and on a pipeline
    /// that is not round-trip-closed the whole signal lives in that
    /// difference.</summary>
    private static readonly Dictionary<string, int> StageByTag = new(StringComparer.Ordinal)
    {
        ["read-error"] = 0,
        ["parse-error"] = 0,
        ["encode-error"] = 0,
        ["compile-error"] = 1,
        ["reencode-error"] = 2,
        ["declaration-drift"] = 3,
        ["fixpoint-error"] = 4,
        ["fixpoint-drift"] = 4,
        ["clean"] = 5,
    };

    /// <summary>The funnel rows, in order.</summary>
    public static readonly (int Threshold, string Label)[] Stages =
    [
        (1, "1 encoded"),
        (2, "2 compiled back"),
        (3, "3 re-encoded"),
        (4, "4 declarations kept"),
        (5, "5 fixpoint (clean)"),
    ];

    /// <summary>The last stage a scored file survived, from its taxonomy tag.
    /// An unknown tag throws rather than defaulting, so a new failure mode
    /// cannot be silently mis-attributed into the funnel.</summary>
    public static int StageReached(string reason)
    {
        var tag = reason.Split(':', 2)[0];
        if (!StageByTag.TryGetValue(tag, out var stage))
        {
            throw new InvalidOperationException(
                $"unknown taxonomy tag \"{tag}\" — the funnel would silently lie");
        }

        return stage;
    }

    /// <summary>Recursively drops every <c>metadata</c> map and orders keys, so
    /// two programs that differ only in cosmetic metadata (Ball invariant #2)
    /// compare equal — the project's own definition of semantic equality.</summary>
    public static JsonNode? StripMetadata(JsonNode? node)
    {
        switch (node)
        {
            case JsonObject obj:
                var stripped = new JsonObject();
                foreach (var pair in obj.OrderBy(p => p.Key, StringComparer.Ordinal))
                {
                    if (pair.Key == "metadata")
                    {
                        continue;
                    }

                    stripped[pair.Key] = StripMetadata(pair.Value?.DeepClone());
                }

                return stripped;
            case JsonArray array:
                var mapped = new JsonArray();
                foreach (var item in array)
                {
                    mapped.Add(StripMetadata(item?.DeepClone()));
                }

                return mapped;
            default:
                return node?.DeepClone();
        }
    }

    private static string CanonicalIr(Program program)
    {
        var node = JsonNode.Parse(JsonFormatter.Default.Format(program));
        return StripMetadata(node)?.ToJsonString() ?? "null";
    }

    /// <summary>The declaration inventory of <paramref name="source"/>: one
    /// entry per declaration, type members included, so a lost method is
    /// visible and mere reordering is not. Walked with Roslyn directly —
    /// independent of <see cref="CSharpEncoder"/>'s own walk.</summary>
    public static SortedSet<string> DeclarationInventory(string source)
    {
        var walker = new InventoryWalker();
        walker.Visit(CSharpSyntaxTree.ParseText(source).GetRoot());
        return walker.Names;
    }

    private sealed class InventoryWalker : CSharpSyntaxWalker
    {
        public SortedSet<string> Names { get; } = new(StringComparer.Ordinal);

        private readonly Stack<string> _owners = new();

        private string Owner => _owners.Count == 0 ? string.Empty : _owners.Peek() + ".";

        private void VisitType(string kind, SyntaxToken name, Action recurse)
        {
            var qualified = Owner + name.ValueText;
            Names.Add($"{kind} {qualified}");
            _owners.Push(qualified);
            recurse();
            _owners.Pop();
        }

        public override void VisitClassDeclaration(ClassDeclarationSyntax node) =>
            VisitType("class", node.Identifier, () => base.VisitClassDeclaration(node));

        public override void VisitStructDeclaration(StructDeclarationSyntax node) =>
            VisitType("struct", node.Identifier, () => base.VisitStructDeclaration(node));

        public override void VisitRecordDeclaration(RecordDeclarationSyntax node) =>
            VisitType("record", node.Identifier, () => base.VisitRecordDeclaration(node));

        public override void VisitInterfaceDeclaration(InterfaceDeclarationSyntax node) =>
            VisitType("interface", node.Identifier, () => base.VisitInterfaceDeclaration(node));

        public override void VisitEnumDeclaration(EnumDeclarationSyntax node)
        {
            var qualified = Owner + node.Identifier.ValueText;
            Names.Add($"enum {qualified}");
            foreach (var member in node.Members)
            {
                Names.Add($"enum {qualified}.{member.Identifier.ValueText}");
            }
        }

        public override void VisitMethodDeclaration(MethodDeclarationSyntax node) =>
            Names.Add($"method {Owner}{node.Identifier.ValueText}");

        public override void VisitConstructorDeclaration(ConstructorDeclarationSyntax node) =>
            Names.Add($"ctor {Owner}{node.Identifier.ValueText}");

        public override void VisitPropertyDeclaration(PropertyDeclarationSyntax node) =>
            Names.Add($"property {Owner}{node.Identifier.ValueText}");

        public override void VisitFieldDeclaration(FieldDeclarationSyntax node)
        {
            foreach (var variable in node.Declaration.Variables)
            {
                Names.Add($"field {Owner}{variable.Identifier.ValueText}");
            }
        }

        public override void VisitDelegateDeclaration(DelegateDeclarationSyntax node) =>
            Names.Add($"delegate {Owner}{node.Identifier.ValueText}");
    }

    private static string FirstLine(Exception error)
    {
        var text = error.Message.Replace("\r", string.Empty);
        var cut = text.IndexOf('\n');
        var line = cut == -1 ? text : text[..cut];
        return line.Length > 160 ? line[..160] + "…" : line;
    }

    /// <summary>Runs Tier A over one file's <paramref name="source"/>.</summary>
    public static FileResult StudyFile(string package, string file, string source)
    {
        var before = DeclarationInventory(source);
        if (before.Count == 0)
        {
            return new FileResult(package, file, Scored: false, Clean: false, IrStable: false,
                "skipped: no declarations to compile");
        }

        // Stage 1 — encode in LIBRARY mode (see the class doc).
        Program program;
        string firstIr;
        try
        {
            program = CSharpEncoder.EncodeLibrary(source);
            firstIr = CanonicalIr(program);
        }
        catch (Exception ex)
        {
            return new FileResult(package, file, true, false, false, $"encode-error: {FirstLine(ex)}");
        }

        // Stage 2 — compile back. Compile() emits Main only when the entry
        // function exists, so an entry-point-less library Program is fine.
        string compiled;
        try
        {
            compiled = CSharpCompiler.Compile(program);
        }
        catch (Exception ex)
        {
            return new FileResult(package, file, true, false, false, $"compile-error: {FirstLine(ex)}");
        }

        if (string.IsNullOrWhiteSpace(compiled))
        {
            return new FileResult(package, file, false, false, false,
                "skipped: the file compiles to nothing (no user module)");
        }

        // Stage 3 — re-encode the compiled C#.
        Program program2;
        string secondIr;
        try
        {
            program2 = CSharpEncoder.EncodeLibrary(compiled);
            secondIr = CanonicalIr(program2);
        }
        catch (Exception ex)
        {
            return new FileResult(package, file, true, false, false, $"reencode-error: {FirstLine(ex)}");
        }

        var irStable = firstIr == secondIr;

        // Stage 4 — declaration inventory preserved?
        var after = DeclarationInventory(compiled);
        var lost = before.Where(name => !after.Contains(name)).ToList();
        if (lost.Count > 0)
        {
            var shown = string.Join(", ", lost.Take(3));
            return new FileResult(package, file, true, false, irStable,
                $"declaration-drift: lost {lost.Count} declaration(s) — {shown}");
        }

        // Stage 5 — SECOND-GENERATION FIXPOINT. Generation 1 vs. 2 is not a
        // usable signal (the compiler faithfully lowers Ball's single `input`
        // parameter back to a named local, so almost nothing is stable across
        // the first pass). From generation 2 on that lowering is already
        // applied, so a pipeline that neither loses nor invents meaning must
        // reach a fixpoint.
        string compiled2;
        string thirdIr;
        try
        {
            compiled2 = CSharpCompiler.Compile(program2);
            thirdIr = CanonicalIr(CSharpEncoder.EncodeLibrary(compiled2));
        }
        catch (Exception ex)
        {
            return new FileResult(package, file, true, false, irStable,
                $"fixpoint-error: generation 2 failed to compile — {FirstLine(ex)}");
        }

        if (compiled != compiled2 || secondIr != thirdIr)
        {
            return new FileResult(package, file, true, false, irStable,
                "fixpoint-drift: recompiling the re-encoded program changed it again");
        }

        return new FileResult(package, file, true, true, irStable, "clean");
    }

    /// <summary>Every hand-written .cs file under <paramref name="directory"/>,
    /// sorted. Build outputs and generated/designer files are excluded — they
    /// are nobody's hand-written library surface.</summary>
    public static List<string> CsFilesUnder(string directory) =>
        Directory.EnumerateFiles(directory, "*.cs", SearchOption.AllDirectories)
            .Where(path =>
            {
                var normalized = path.Replace('\\', '/');
                return !normalized.Contains("/obj/", StringComparison.Ordinal)
                    && !normalized.Contains("/bin/", StringComparison.Ordinal)
                    && !normalized.EndsWith(".Designer.cs", StringComparison.Ordinal)
                    && !normalized.EndsWith(".g.cs", StringComparison.Ordinal)
                    && !normalized.EndsWith(".generated.cs", StringComparison.Ordinal);
            })
            .OrderBy(path => path, StringComparer.Ordinal)
            .ToList();

    /// <summary>Runs Tier A over every .cs file under <paramref name="directory"/>.</summary>
    public static List<FileResult> StudyDirectory(string package, string directory)
    {
        var results = new List<FileResult>();
        foreach (var path in CsFilesUnder(directory))
        {
            var rel = Path.GetRelativePath(directory, path).Replace('\\', '/');
            string source;
            try
            {
                // Read as BYTES and decode explicitly: no newline translation,
                // so a semantic lone \r survives into the measurement.
                source = Encoding.UTF8.GetString(File.ReadAllBytes(path));
            }
            catch (Exception ex)
            {
                results.Add(new FileResult(package, rel, true, false, false,
                    $"read-error: {FirstLine(ex)}"));
                continue;
            }

            results.Add(StudyFile(package, rel, source));
        }

        return results;
    }
}
