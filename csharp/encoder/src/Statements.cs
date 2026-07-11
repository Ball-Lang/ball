using System.Collections.Generic;
using System.Linq;
using Ball.V1;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

namespace Ball.Encoder;

/// <summary>
/// Statement/block encoding — C# <c>{ stmt; stmt; ... }</c> → Ball <c>Block</c>. Unlike Rust's
/// tail-expression convention (mirrored in <c>rust/encoder/src/block.rs</c>), C# has no
/// implicit "last expression with no semicolon is the value" rule — every value-producing exit
/// is an explicit <c>return</c> statement, which this encoder always compiles to a genuine
/// <c>std.return(value)</c> **expression statement** (never <c>Block.result</c>), relying on the
/// engine's <c>return</c> flow-signal to unwind to the enclosing function call regardless of
/// nesting depth. A block's <c>result</c> is therefore always the null literal — purely a
/// protocol-required field, never load-bearing here. Expression-bodied members
/// (<c>int Square(int x) =&gt; x * x;</c>) skip this file entirely — see
/// <c>Types.cs</c>/<c>Methods.cs</c>, which encode the bare expression directly as the
/// function's <c>body</c>.
/// </summary>
internal sealed partial class Encoder
{
    internal Expression EncodeStatementsAsBlock(IReadOnlyList<StatementSyntax> statements)
    {
        var stmts = new List<Statement>();
        foreach (var statement in statements)
        {
            stmts.AddRange(EncodeStatement(statement));
        }

        return Builders.BlockExpr(stmts, Builders.NullLiteral());
    }

    private List<Statement> EncodeStatement(StatementSyntax stmt)
    {
        switch (stmt)
        {
            case LocalDeclarationStatementSyntax local:
                return EncodeLocalDeclaration(local);
            case ExpressionStatementSyntax exprStmt:
                return new List<Statement> { Builders.ExprStmt(EncodeExpr(exprStmt.Expression)) };
            case BlockSyntax nested:
                PushScope();
                var nestedBlock = EncodeStatementsAsBlock(nested.Statements);
                PopScope();
                return new List<Statement> { Builders.ExprStmt(nestedBlock) };
            case EmptyStatementSyntax:
                return new List<Statement>();
            case IfStatementSyntax ifStmt:
                return new List<Statement> { Builders.ExprStmt(EncodeIfStatement(ifStmt)) };
            case ForStatementSyntax forStmt:
                return new List<Statement> { Builders.ExprStmt(EncodeForStatement(forStmt)) };
            case ForEachStatementSyntax forEachStmt:
                return new List<Statement> { Builders.ExprStmt(EncodeForEachStatement(forEachStmt)) };
            case WhileStatementSyntax whileStmt:
                return new List<Statement> { Builders.ExprStmt(EncodeWhileStatement(whileStmt)) };
            case DoStatementSyntax doStmt:
                return new List<Statement> { Builders.ExprStmt(EncodeDoStatement(doStmt)) };
            case SwitchStatementSyntax switchStmt:
                return new List<Statement> { Builders.ExprStmt(EncodeSwitchStatement(switchStmt)) };
            case TryStatementSyntax tryStmt:
                return new List<Statement> { Builders.ExprStmt(EncodeTryStatement(tryStmt)) };
            case BreakStatementSyntax:
                return new List<Statement> { Builders.ExprStmt(Builders.StdCall("break", null)) };
            case ContinueStatementSyntax:
                return new List<Statement> { Builders.ExprStmt(Builders.StdCall("continue", null)) };
            case ReturnStatementSyntax returnStmt:
                return new List<Statement>
                {
                    Builders.ExprStmt(Builders.StdCall(
                        "return",
                        Builders.ArgsMessage(("value", returnStmt.Expression is null
                            ? Builders.NullLiteral()
                            : EncodeExpr(returnStmt.Expression))))),
                };
            case ThrowStatementSyntax throwStmt:
                return new List<Statement>
                {
                    Builders.ExprStmt(Builders.StdCall(
                        "throw",
                        Builders.ArgsMessage(("value", throwStmt.Expression is null
                            ? Builders.NullLiteral()
                            : EncodeExpr(throwStmt.Expression))))),
                };
            default:
                throw new EncoderException(
                    $"ball-encoder: unsupported C# statement kind `{stmt.Kind()}` " +
                    $"(deferred — see the module doc comment for issue #382's scope): `{stmt}`");
        }
    }

    private List<Statement> EncodeLocalDeclaration(LocalDeclarationStatementSyntax local)
    {
        var typeText = local.Declaration.Type.ToString();
        var isConst = local.Modifiers.Any(SyntaxKind.ConstKeyword);
        var result = new List<Statement>();
        foreach (var variable in local.Declaration.Variables)
        {
            var name = variable.Identifier.Text;
            var value = variable.Initializer is null
                ? Builders.NullLiteral()
                : EncodeExpr(variable.Initializer.Value);

            var meta = new MetaBuilder();
            if (typeText != "var")
            {
                meta.SetString("type", typeText);
            }

            meta.SetBoolIfTrue("is_const", isConst);
            result.Add(Builders.LetStmt(name, value, meta.Build()));
            DeclareLocal(name);
            RecordLocalLambda(name, variable.Initializer?.Value);
        }

        return result;
    }
}
