// Aliased rather than `using Ball.V1;` — xunit v3 test projects are
// self-executing apps, so the SDK injects a global `Program` entry-point
// type into this project that would otherwise shadow `Ball.V1.Program`.
using BallProgram = Ball.V1.Program;
// ToByteArray()/etc. are extension methods on IMessage, not members of the
// generated type.
using Google.Protobuf;

namespace Ball.Shared.Tests;

/// <summary>
/// Phase 1 (#378) smoke test: proves the buf-generated bindings in
/// csharp/shared/gen/Ball.cs actually compile against the pinned
/// Google.Protobuf runtime and round-trip through binary protobuf. Full
/// wiring (helpers, well-known-type conveniences) lands in #379.
/// </summary>
public class ProtoBindingSmokeTests
{
    [Fact]
    public void Program_RoundTrips_ThroughBinaryProtobuf()
    {
        var program = new BallProgram
        {
            Name = "hello_world",
            Version = "1.0.0",
            EntryModule = "main",
            EntryFunction = "main",
        };

        var bytes = program.ToByteArray();
        var decoded = BallProgram.Parser.ParseFrom(bytes);

        Assert.Equal(program.Name, decoded.Name);
        Assert.Equal(program.Version, decoded.Version);
        Assert.Equal(program.EntryModule, decoded.EntryModule);
        Assert.Equal(program.EntryFunction, decoded.EntryFunction);
    }
}
