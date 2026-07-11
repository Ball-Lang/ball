namespace Ball.Engine.Conformance;

/// <summary>
/// Entry point for the C# Phase-7 conformance harness (issue #384).
///
/// <code>
/// dotnet run --project csharp/engine/conformance -c Release -p:SelfHost=true -- --leg=engine
/// dotnet run --project csharp/engine/conformance -c Release -- --leg=compiler
/// dotnet run --project csharp/engine/conformance -c Release -- --leg=roundtrip [--dart=dart]
/// dotnet run --project csharp/engine/conformance -c Release -p:SelfHost=true -- --leg=all
/// </code>
///
/// <c>--fixture=&lt;name&gt;</c> (or the <c>BALL_FIXTURE</c> env var, matching
/// the Rust runner's convention) narrows every requested leg to one fixture
/// and dumps actual-vs-expected detail for it. Exit code is nonzero iff any
/// requested leg has a failure.
/// </summary>
internal static class ConformanceProgram
{
    private static int Main(string[] args)
    {
        var leg = "engine";
        string? fixture = Environment.GetEnvironmentVariable("BALL_FIXTURE");
        var dartExecutable = "dart";

        foreach (var arg in args)
        {
            if (arg.StartsWith("--leg=", StringComparison.Ordinal))
            {
                leg = arg["--leg=".Length..];
            }
            else if (arg.StartsWith("--fixture=", StringComparison.Ordinal))
            {
                fixture = arg["--fixture=".Length..];
            }
            else if (arg.StartsWith("--dart=", StringComparison.Ordinal))
            {
                dartExecutable = arg["--dart=".Length..];
            }
            else
            {
                Console.Error.WriteLine($"unrecognized argument: {arg}");
                return 2;
            }
        }

        var exit = 0;
        if (leg is "engine" or "all")
        {
            exit |= EngineLeg.Run(fixture);
        }

        if (leg is "compiler" or "all")
        {
            exit |= CompilerLeg.Run(fixture);
        }

        if (leg is "roundtrip" or "all")
        {
            exit |= RoundTripLeg.Run(fixture, dartExecutable);
        }

        if (leg is not ("engine" or "compiler" or "roundtrip" or "all"))
        {
            Console.Error.WriteLine($"unknown --leg={leg} (expected engine|compiler|roundtrip|all)");
            return 2;
        }

        return exit;
    }
}
