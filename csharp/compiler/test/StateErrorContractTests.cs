using Ball.Shared;
using Ball.V1;
using static Ball.Compiler.Tests.Ast;

namespace Ball.Compiler.Tests;

/// <summary>
/// What a CAUGHT <c>StateError</c> READS AS, on the compiled C# target
/// (issue #616).
///
/// <para><b>The bug.</b> #597/#604 settled that <c>list_find</c>'s no-match
/// THROWS and that the throw is typed; <c>ListFindContractTests</c> pins both.
/// Neither settled what the program then observes, because conformance fixture
/// <c>463_list_find_no_match</c> prints a HARDCODED literal from its catch
/// bodies. Two separate defects hid behind that:</para>
/// <list type="bullet">
///   <item><c>BallThrow("StateError", "No element")</c>'s payload is a
///   <see cref="BallMessage"/>, which rendered as the generic map form
///   <c>{message: No element}</c> — so <c>to_string(e)</c> in a catch body
///   printed that, where the Dart reference engine prints Dart's own
///   <c>StateError.toString()</c>, <c>Bad state: No element</c>.</item>
///   <item><c>BallRuntime.ListFirst</c>/<c>ListLast</c> threw a native
///   <see cref="BallRuntimeException"/> — the exact anti-pattern #597 fixed for
///   <c>list_find</c>: the compiled <c>try</c> only catches
///   <see cref="BallThrow"/>, so the program's own <c>on StateError catch</c>
///   never ran and the process died instead.</item>
/// </list>
///
/// <para>These tests RUN the compiled program: a shape assertion cannot tell
/// "prints Bad state: No element" from "prints {message: No element}". The
/// cross-target guard is <c>tests/conformance/465_state_error_message</c>.</para>
/// </summary>
public class StateErrorContractTests
{
    private static string Run(Ball.V1.Program program) =>
        CSharpRunner.Run(CSharpCompiler.Compile(program));

    /// <summary><c>try { print(to_string(&lt;body&gt;)) } on StateError catch (e) { print(to_string(e)) }</c>.</summary>
    private static Ball.V1.Program CatchAndPrint(Expression body) =>
        Program(Block(new[]
        {
            Expr(Call("std", "try", Msg(
                ("body", Print(Call("std", "to_string", Msg(("value", body))))),
                ("catches", ListLit(Msg(
                    ("type", Str("StateError")),
                    ("variable", Str("e")),
                    ("body", Print(Call("std", "to_string", Msg(("value", Ref("e")))))))))))),
        }));

    private static Expression FindNoMatch() =>
        Call("std_collections", "list_find", Msg(
            ("list", ListLit(Int(1), Int(2), Int(3))),
            ("callback", Lambda(Bin("greater_than", Ref("input"), Int(100))))));

    private static Expression FirstOfEmpty() =>
        Call("std_collections", "list_first", Msg(("list", ListLit())));

    [Fact]
    public void ACaughtListFindStateError_ReadsAsDartsToString()
    {
        Assert.Equal("Bad state: No element\n", Run(CatchAndPrint(FindNoMatch())));
    }

    [Fact]
    public void ACaughtListFirstStateError_ReadsTheSame_AndIsCaughtAtAll()
    {
        Assert.Equal("Bad state: No element\n", Run(CatchAndPrint(FirstOfEmpty())));
    }

    [Fact]
    public void ListFirstAndListLast_ThrowATypedStateError_NotANativeRuntimeFault()
    {
        foreach (var function in new[] { "list_first", "list_last" })
        {
            var program = Program(Block(new[]
            {
                Expr(Print(Call("std_collections", function, Msg(("list", ListLit()))))),
            }));

            var ex = Assert.Throws<BallThrow>(() => Run(program));
            Assert.Equal("StateError", ex.TypeName);
            Assert.Equal("No element", ex.Message);
            Assert.Equal("Bad state: No element", ex.Payload.ToString());
        }
    }

    /// <summary>
    /// The Dart-error rendering table is closed over the type names
    /// <see cref="BallThrow"/> raises. A user class that merely declares a
    /// <c>message</c> field is not a Dart error and keeps the map rendering.
    /// </summary>
    [Fact]
    public void AUserMessageCarryingAMessageField_IsNotRenderedAsADartError()
    {
        var user = new BallMessage("main:Notification", new BallMap { ["message"] = BallValue.Str("hello") });

        Assert.Equal("{message: hello}", user.ToString());
    }
}
