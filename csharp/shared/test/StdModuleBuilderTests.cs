using System.Text.Json;
using System.Text.RegularExpressions;
using Ball.Shared;
using Ball.V1;

namespace Ball.Shared.Tests;

/// <summary>
/// Cross-checks the C# module builders against the canonical Dart inventory —
/// never a bare hardcoded count. The <c>std</c> module is verified against the
/// committed proto3-JSON artifact <c>dart/shared/std.json</c> (name-for-name);
/// <c>std_collections</c>/<c>std_io</c>/<c>std_memory</c> (which have no committed
/// JSON) are verified against their canonical Dart source
/// (<c>dart/shared/lib/std_*.dart</c>) by extracting each <c>_fn('name', …)</c>
/// registration. Mirrors <c>rust/shared/src/std_*_module.rs</c>.
/// </summary>
public partial class StdModuleBuilderTests
{
    [GeneratedRegex(@"_fn\(\s*'([^']+)'")]
    private static partial Regex FnRegistrationRegex();

    /// <summary>
    /// <c>_fn('name', 'inputType', 'outputType', …)</c> — the first three
    /// arguments are always plain single-quoted literals (the description may be
    /// an adjacent-string concatenation, so it is not captured).
    /// </summary>
    [GeneratedRegex(@"_fn\(\s*'([^']+)'\s*,\s*'([^']*)'\s*,\s*'([^']*)'")]
    private static partial Regex FnOutputTypeRegex();

    private static IReadOnlyList<string> DartStdJsonFunctionNames()
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(RepoPaths.StdJson));
        return doc.RootElement.GetProperty("functions")
            .EnumerateArray()
            .Select(f => f.GetProperty("name").GetString()!)
            .ToList();
    }

    /// <summary>
    /// Every function's declared <c>outputType</c> in <c>dart/shared/std.json</c>.
    /// proto3 JSON omits an empty string, so an absent field means <c>""</c>.
    /// </summary>
    private static IReadOnlyDictionary<string, string> DartStdJsonOutputTypes()
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(RepoPaths.StdJson));
        return doc.RootElement.GetProperty("functions")
            .EnumerateArray()
            .ToDictionary(
                f => f.GetProperty("name").GetString()!,
                f => f.TryGetProperty("outputType", out var o) ? o.GetString() ?? string.Empty : string.Empty);
    }

    private static IReadOnlyList<string> DartSourceFunctionNames(string module)
    {
        var text = File.ReadAllText(RepoPaths.DartStdSource(module));
        return FnRegistrationRegex().Matches(text)
            .Select(m => m.Groups[1].Value)
            .ToList();
    }

    /// <summary>
    /// Every function's declared <c>outputType</c> in the canonical Dart source
    /// for <paramref name="module"/>.
    /// </summary>
    private static IReadOnlyDictionary<string, string> DartSourceOutputTypes(string module)
    {
        var text = File.ReadAllText(RepoPaths.DartStdSource(module));
        return FnOutputTypeRegex().Matches(text)
            .ToDictionary(m => m.Groups[1].Value, m => m.Groups[3].Value);
    }

    /// <summary>
    /// Assert every function this project's builder declares carries the SAME
    /// <c>outputType</c> the canonical Dart declaration does.
    ///
    /// The name-for-name checks above cannot see this drift: issue #545 gave
    /// <c>set_add</c>/<c>set_remove</c> Dart's <c>outputType: 'bool'</c> and this
    /// project kept declaring <c>""</c> — both sides green while the contract
    /// itself had split (issue #557; PR #562's round-2 review, item 1). A
    /// declared <c>outputType</c> is load-bearing: it is what
    /// <c>dart/engine/test/std_output_type_contract_test.dart</c> gates the Dart
    /// engine's handlers against.
    /// </summary>
    private static void AssertOutputTypesMatch(
        string module,
        IReadOnlyDictionary<string, string> expected,
        IReadOnlyList<FunctionDefinition> actual)
    {
        Assert.True(
            expected.Count >= 10,
            $"extracted only {expected.Count} declarations for {module} — the scan " +
            "has stopped matching, so this gate would pass vacuously");

        var mismatches = actual
            // A function present in only one source is the name gate's report,
            // not this one's.
            .Where(fn => expected.ContainsKey(fn.Name) && expected[fn.Name] != fn.OutputType)
            .Select(fn => $"{fn.Name}: Dart declares \"{expected[fn.Name]}\", this project declares \"{fn.OutputType}\"")
            .ToList();

        Assert.True(
            mismatches.Count == 0,
            $"`{module}` outputType drifted from the canonical Dart declarations:\n  " +
            string.Join("\n  ", mismatches) +
            "\n  Port the Dart `outputType` into csharp/shared/src/StdModuleBuilders.cs — a " +
            "declared outputType is a cross-target CONTRACT (issue #545/#557), not documentation.");
    }

    [Fact]
    public void StdModuleMatchesStdJsonNameForName()
    {
        var expected = DartStdJsonFunctionNames();
        var actual = StdModuleBuilders.BuildStdModule().Functions.Select(f => f.Name).ToList();

        Assert.Equal(expected.Count, actual.Count);
        Assert.Equal(expected.OrderBy(n => n), actual.OrderBy(n => n));
        Assert.Equal("std", StdModuleBuilders.BuildStdModule().Name);

        AssertOutputTypesMatch(
            "std", DartStdJsonOutputTypes(), StdModuleBuilders.BuildStdModule().Functions);
    }

    [Fact]
    public void StdCollectionsMatchesDartSource()
    {
        var expected = DartSourceFunctionNames("std_collections");
        var actual = StdModuleBuilders.BuildStdCollectionsModule().Functions.Select(f => f.Name).ToList();
        Assert.NotEmpty(expected);
        Assert.Equal(expected.Count, actual.Count);
        Assert.Equal(expected.OrderBy(n => n), actual.OrderBy(n => n));

        AssertOutputTypesMatch(
            "std_collections",
            DartSourceOutputTypes("std_collections"),
            StdModuleBuilders.BuildStdCollectionsModule().Functions);
    }

    [Fact]
    public void StdIoMatchesDartSource()
    {
        var expected = DartSourceFunctionNames("std_io");
        var actual = StdModuleBuilders.BuildStdIoModule().Functions.Select(f => f.Name).ToList();
        Assert.NotEmpty(expected);
        Assert.Equal(expected.Count, actual.Count);
        Assert.Equal(expected.OrderBy(n => n), actual.OrderBy(n => n));

        AssertOutputTypesMatch(
            "std_io", DartSourceOutputTypes("std_io"), StdModuleBuilders.BuildStdIoModule().Functions);
    }

    [Fact]
    public void StdMemoryMatchesDartSource()
    {
        var expected = DartSourceFunctionNames("std_memory");
        var actual = StdModuleBuilders.BuildStdMemoryModule().Functions.Select(f => f.Name).ToList();
        Assert.NotEmpty(expected);
        Assert.Equal(expected.Count, actual.Count);
        Assert.Equal(expected.OrderBy(n => n), actual.OrderBy(n => n));

        AssertOutputTypesMatch(
            "std_memory",
            DartSourceOutputTypes("std_memory"),
            StdModuleBuilders.BuildStdMemoryModule().Functions);
    }

    [Theory]
    [InlineData("std")]
    [InlineData("std_collections")]
    [InlineData("std_io")]
    [InlineData("std_memory")]
    public void EveryFunctionIsBaseWithNoBody(string moduleName)
    {
        var module = moduleName switch
        {
            "std" => StdModuleBuilders.BuildStdModule(),
            "std_collections" => StdModuleBuilders.BuildStdCollectionsModule(),
            "std_io" => StdModuleBuilders.BuildStdIoModule(),
            "std_memory" => StdModuleBuilders.BuildStdMemoryModule(),
            _ => throw new ArgumentOutOfRangeException(nameof(moduleName)),
        };

        Assert.Equal(moduleName, module.Name);
        Assert.NotEmpty(module.Functions);
        foreach (var fn in module.Functions)
        {
            Assert.True(fn.IsBase, $"{fn.Name} must be is_base");
            Assert.Null(fn.Body);
        }
    }

    [Fact]
    public void InputTypesResolveToDeclaredTypeDefs()
    {
        // Every non-empty input_type a function references must be declared in
        // the module's own type_defs (the descriptor-backed calling convention).
        foreach (var module in new[]
                 {
                     StdModuleBuilders.BuildStdModule(),
                     StdModuleBuilders.BuildStdCollectionsModule(),
                     StdModuleBuilders.BuildStdIoModule(),
                     StdModuleBuilders.BuildStdMemoryModule(),
                 })
        {
            var declared = module.TypeDefs.Select(t => t.Name).ToHashSet();
            foreach (var fn in module.Functions.Where(f => !string.IsNullOrEmpty(f.InputType)))
            {
                Assert.Contains(fn.InputType, declared);
            }
        }
    }
}
