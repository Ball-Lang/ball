using System.Linq;
using Ball.Shared;

namespace Ball.Encoder.Tests;

/// <summary>Issue #382's two hard invariants: (1) zero language-specific base modules — every
/// module the encoder ever emits is one of the universal four (or the user's own <c>main</c>);
/// (2) std modules are accumulated from actual usage, not the whole ~119-function catalog.</summary>
public class StdModuleAccumulationTests
{
    private static readonly string[] UniversalModuleNames =
    {
        "std", "std_collections", "std_io", "std_memory", "main",
    };

    [Theory]
    [InlineData("Console.WriteLine(\"hi\");")]
    [InlineData("int a = 1; int b = 2; var r = a + b * (a - b) / 2 % 3;")]
    [InlineData("var xs = new List<int> { 1, 2, 3 }; xs.Add(4); var y = xs.Select(x => x * 2);")]
    [InlineData("int r = 0; try { throw new Exception(\"e\"); } catch (Exception e) { r = 1; } finally { r = 2; }")]
    public void NeverEmitsANonUniversalBaseModule(string body)
    {
        var program = TestHelpers.EncodeProgram(body);
        foreach (var module in program.Modules)
        {
            Assert.Contains(module.Name, UniversalModuleNames);
        }

        // The hard invariant, stated directly: no `csharp_std` module, ever.
        Assert.DoesNotContain(program.Modules, m => m.Name == "csharp_std");
    }

    [Fact]
    public void StdModuleDeclaresOnlyFunctionsActuallyCalled()
    {
        var program = TestHelpers.EncodeProgram("int a = 1; int b = 2; var r = a + b;");
        var stdModule = program.Modules.Single(m => m.Name == "std");
        var names = stdModule.Functions.Select(f => f.Name).ToList();
        Assert.Contains("add", names);
        // Nowhere near the full ~119-function std catalog for a program that only adds.
        Assert.True(names.Count < 5, $"expected a minimal std module, got {names.Count} functions: {string.Join(", ", names)}");
    }

    [Fact]
    public void EveryDeclaredStdFunctionIsBaseWithNoBody()
    {
        var program = TestHelpers.EncodeProgram("int a = 1; var r = -a;");
        var stdModule = program.Modules.Single(m => m.Name == "std");
        Assert.All(stdModule.Functions, f =>
        {
            Assert.True(f.IsBase);
            Assert.Null(f.Body);
        });
    }

    [Fact]
    public void StdCollectionsModuleOnlyPresentWhenActuallyUsed()
    {
        var withoutCollections = TestHelpers.EncodeProgram("int a = 1; var r = a + 1;");
        Assert.DoesNotContain(withoutCollections.Modules, m => m.Name == "std_collections");

        var withCollections = TestHelpers.EncodeProgram("var xs = new List<int> { 1 }; xs.Add(2);");
        Assert.Contains(withCollections.Modules, m => m.Name == "std_collections");
    }

    [Fact]
    public void MainModuleDeclaresModuleImportsForEveryUsedBaseModule()
    {
        var program = TestHelpers.EncodeProgram("var xs = new List<int> { 1 }; xs.Add(2);");
        var main = TestHelpers.MainModule(program);
        var importNames = main.ModuleImports.Select(i => i.Name).ToList();
        Assert.Contains("std", importNames);
        Assert.Contains("std_collections", importNames);
    }

    [Fact]
    public void UsedStdFunctionNamesMatchTheCanonicalDartInventory()
    {
        // Every name this encoder ever emits as a `std` call must resolve against the
        // canonical inventory StdModuleBuilders exposes — CSharpEncoder throws loud
        // (EncoderException) at encode time otherwise (see BuildUsedModule). Exercise a
        // broad mix of constructs and assert the whole std module is well-formed.
        const string source = """
            using System;
            using System.Collections.Generic;
            using System.Linq;

            class Program
            {
                static void Main()
                {
                    int a = 1, b = 2;
                    var sum = a + b - a * b / 2 % 2;
                    var cmp = a < b && a != b || a >= b;
                    var bits = a & b | a ^ b;
                    var shifted = a << 1 >> 1;
                    var not = !(a == b);
                    var neg = -a;
                    var bnot = ~a;
                    a++;
                    a--;
                    Console.WriteLine($"sum={sum}");
                    var s = "hello";
                    var upper = s.ToUpper();
                    var trimmed = s.Trim();
                    var xs = new List<int> { 1, 2, 3 };
                    xs.Add(4);
                    var mapped = xs.Select(x => x * 2);
                    string? maybe = null;
                    var len = maybe?.Length ?? 0;
                }
            }
            """;
        var program = TestHelpers.EncodeProgram(source);
        var stdModule = program.Modules.Single(m => m.Name == "std");
        var canonicalNames = StdModuleBuilders.BuildStdModule().Functions.Select(f => f.Name).ToHashSet();
        Assert.All(stdModule.Functions, f => Assert.Contains(f.Name, canonicalNames));
        Assert.NotEmpty(stdModule.Functions);
    }
}
