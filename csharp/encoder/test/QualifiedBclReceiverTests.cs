using System.Linq;
using Ball.V1;

namespace Ball.Encoder.Tests;

/// <summary>
/// Namespace-qualified BCL static receivers — <c>System.Console.WriteLine(...)</c>,
/// <c>System.Math.Abs(...)</c> — encode identically to their bare spellings.
///
/// <para>Required by issue #492's slices A and B: the committed bucket-(b) and bucket-(g)
/// fixtures both write <c>System.Console.WriteLine(...)</c>, so once their own gap
/// (bodyless members) closed, they would still have failed on this unrelated one —
/// <c>EncodeMemberInvocation</c> only special-cased a receiver that is a bare
/// <c>IdentifierNameSyntax</c>, so a <c>MemberAccessExpressionSyntax</c> receiver fell
/// through to <c>DispatchInstanceOrBuiltinMethod</c> and threw <c>unsupported method call
/// `.WriteLine(...)`</c>. Fixing it here is what lets those buckets flip on their
/// <b>unmodified</b> committed fixtures, rather than by rewriting a fixture to dodge a
/// failure.</para>
///
/// <para>Only the <c>System</c> namespace is unwrapped — see
/// <c>Encoder.StaticReceiverName</c> for why deeper namespaces keep failing loud.</para>
/// </summary>
public class QualifiedBclReceiverTests
{
    [Fact]
    public void SystemQualifiedConsoleWriteLineEncodesAsStdPrint()
    {
        const string source = """
            class Program
            {
                static void Main()
                {
                    System.Console.WriteLine("hi");
                }
            }
            """;
        var main = TestHelpers.MainFunction(TestHelpers.EncodeProgram(source));
        var print = main.Body.Block.Statements[0].Expression;
        Assert.Equal("std", print.Call.Module);
        Assert.Equal("print", print.Call.Function);
    }

    [Fact]
    public void SystemQualifiedMathCallEncodesLikeTheBareSpelling()
    {
        const string qualified = """
            class Program
            {
                static void Main()
                {
                    var a = System.Math.Abs(-3);
                }
            }
            """;
        const string bare = """
            using System;

            class Program
            {
                static void Main()
                {
                    var a = Math.Abs(-3);
                }
            }
            """;
        Assert.Equal(FirstLetValue(bare), FirstLetValue(qualified));
    }

    /// <summary>A deeper namespace names a type this encoder has no mapping for, so it must
    /// keep failing loud rather than being silently mis-resolved to its last segment.</summary>
    [Fact]
    public void DeeperNamespaceQualificationStillFailsLoud()
    {
        const string source = """
            class Program
            {
                static void Main()
                {
                    var s = System.Text.Encoding.GetEncoding("utf-8");
                }
            }
            """;
        Assert.Throws<EncoderException>(() => TestHelpers.EncodeProgram(source));
    }

    /// <summary>A local variable named <c>Console</c> still shadows the BCL static — the
    /// bare-identifier path's existing shadowing check is untouched.</summary>
    [Fact]
    public void ALocalNamedConsoleStillShadowsTheBclStatic()
    {
        const string source = """
            using System;

            class Program
            {
                static void Main()
                {
                    var Console = "not the BCL one";
                    var n = Console.Length;
                }
            }
            """;
        var main = TestHelpers.MainFunction(TestHelpers.EncodeProgram(source));
        var length = main.Body.Block.Statements[1].Let.Value;
        Assert.Equal("length", length.Call.Function);
        Assert.Equal("Console", length.Call.Input.MessageCreation.Fields.Single().Value.Reference.Name);
    }

    private static Expression FirstLetValue(string source) =>
        TestHelpers.MainFunction(TestHelpers.EncodeProgram(source)).Body.Block.Statements[0].Let.Value;
}
