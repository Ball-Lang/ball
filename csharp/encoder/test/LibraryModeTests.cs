using System;
using System.IO;
using System.Linq;
using Ball.Encoder;
using Ball.V1;

namespace Ball.Encoder.Tests;

/// <summary>
/// Library mode (issue #492, slice 2): <see cref="CSharpEncoder.EncodeLibrary"/> encodes source
/// with <b>no <c>Main</c> entry point</b> — the shape every real class library has, and the
/// single largest bucket (38/200 files) in #492's real-code study.
///
/// <para>The fixture used here is the sweep's own bucket-(a) fixture
/// (<c>fixtures/realworld/a_namespaced_library_no_main.cs</c>), so this test and
/// <see cref="RealWorldSweepTests"/> can never disagree about what "library mode works" means.</para>
///
/// <para><b>The deliberate boundary.</b> A library-mode program carries
/// <c>EntryModule = "main"</c> but an empty <c>EntryFunction</c>: structurally legal, and
/// deliberately not runnable (<c>ball check</c> reports <c>missing entry_function</c> — see
/// <c>csharp/cli/test/CliEncodeTests.cs</c>). Mirrors the Rust encoder's <c>encode_library</c>
/// exactly. Never "fix" it by synthesising a fake entry function.</para>
/// </summary>
public class LibraryModeTests
{
    private const string LibraryFixture = "a_namespaced_library_no_main.cs";

    private static string ReadRealWorldFixture(string name)
    {
        var path = Path.Combine(AppContext.BaseDirectory, "fixtures", "realworld", name);
        Assert.True(File.Exists(path), $"missing real-world fixture: {path}");
        return File.ReadAllText(path);
    }

    [Fact]
    public void EncodeLibrary_encodes_a_namespaced_class_library_with_no_main()
    {
        var program = CSharpEncoder.EncodeLibrary(ReadRealWorldFixture(LibraryFixture));

        Assert.Equal("main", program.EntryModule);
        Assert.Equal(string.Empty, program.EntryFunction);

        var main = program.Modules.Single(m => m.Name == "main");
        // An instance method is named `<qualified owner>.<method>` — see
        // `Encoder.QualifiedTypeName`/`Types.cs`'s module doc comment.
        var greet = main.Functions.Single(f => f.Name == "main:Greeter.Greet");
        Assert.NotNull(greet.Body);

        // The class itself round-trips as a type declaration, not just its members.
        Assert.Contains(main.TypeDefs, t => t.Name == "main:Greeter");

        // Std accumulation ran exactly as `Encode`'s does — `Greet` concatenates
        // two strings, which is a `std.add` base call.
        var std = program.Modules.Single(m => m.Name == "std");
        Assert.Contains(std.Functions, f => f is { Name: "add", IsBase: true });
    }

    [Fact]
    public void Encode_still_rejects_the_same_main_less_source()
    {
        // The default contract is unchanged — library mode is strictly opt-in.
        var ex = Assert.Throws<EncoderException>(
            () => CSharpEncoder.Encode(ReadRealWorldFixture(LibraryFixture)));
        Assert.Contains("requires a `Main` entry point", ex.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void EncodeLibrary_still_throws_on_every_other_documented_gap()
    {
        // Library mode relaxes the entry-point requirement and nothing else: a
        // target-typed `new()` (bucket f, still open) fails loud here exactly as it
        // does through `Encode`.
        //
        // This used to use bucket (g)'s bodyless abstract member, which issue #492's
        // slice A closed — a bodyless member is now OMITTED rather than thrown on
        // (see BodylessMembersTests), so it is no longer a gap to demonstrate with.
        Assert.Throws<EncoderException>(
            () => CSharpEncoder.EncodeLibrary(ReadRealWorldFixture("f_target_typed_new.cs")));
    }
}
