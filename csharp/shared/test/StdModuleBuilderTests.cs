using System.Text.Json;
using System.Text.RegularExpressions;
using Ball.Shared;

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

    private static IReadOnlyList<string> DartStdJsonFunctionNames()
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(RepoPaths.StdJson));
        return doc.RootElement.GetProperty("functions")
            .EnumerateArray()
            .Select(f => f.GetProperty("name").GetString()!)
            .ToList();
    }

    private static IReadOnlyList<string> DartSourceFunctionNames(string module)
    {
        var text = File.ReadAllText(RepoPaths.DartStdSource(module));
        return FnRegistrationRegex().Matches(text)
            .Select(m => m.Groups[1].Value)
            .ToList();
    }

    [Fact]
    public void StdModuleMatchesStdJsonNameForName()
    {
        var expected = DartStdJsonFunctionNames();
        var actual = StdModuleBuilders.BuildStdModule().Functions.Select(f => f.Name).ToList();

        Assert.Equal(expected.Count, actual.Count);
        Assert.Equal(expected.OrderBy(n => n), actual.OrderBy(n => n));
        Assert.Equal("std", StdModuleBuilders.BuildStdModule().Name);
    }

    [Fact]
    public void StdCollectionsMatchesDartSource()
    {
        var expected = DartSourceFunctionNames("std_collections");
        var actual = StdModuleBuilders.BuildStdCollectionsModule().Functions.Select(f => f.Name).ToList();
        Assert.NotEmpty(expected);
        Assert.Equal(expected.Count, actual.Count);
        Assert.Equal(expected.OrderBy(n => n), actual.OrderBy(n => n));
    }

    [Fact]
    public void StdIoMatchesDartSource()
    {
        var expected = DartSourceFunctionNames("std_io");
        var actual = StdModuleBuilders.BuildStdIoModule().Functions.Select(f => f.Name).ToList();
        Assert.NotEmpty(expected);
        Assert.Equal(expected.Count, actual.Count);
        Assert.Equal(expected.OrderBy(n => n), actual.OrderBy(n => n));
    }

    [Fact]
    public void StdMemoryMatchesDartSource()
    {
        var expected = DartSourceFunctionNames("std_memory");
        var actual = StdModuleBuilders.BuildStdMemoryModule().Functions.Select(f => f.Name).ToList();
        Assert.NotEmpty(expected);
        Assert.Equal(expected.Count, actual.Count);
        Assert.Equal(expected.OrderBy(n => n), actual.OrderBy(n => n));
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
