using System.Collections.Generic;
using System.Linq;
using Ball.V1;
using Microsoft.CodeAnalysis.CSharp.Syntax;

namespace Ball.Encoder;

/// <summary>
/// Control-flow encoding: <c>if</c> → <c>std.if</c>, <c>for</c> → <c>std.for</c>,
/// <c>foreach</c> → <c>std.for_in</c>, <c>while</c>/<c>do-while</c> → <c>std.while</c>/
/// <c>std.do_while</c>, <c>switch</c> → <c>std.switch</c>, <c>try/catch/finally</c> →
/// <c>std.try</c>. Field shapes match <c>Ball.Shared.StdModuleBuilders</c>'s documented
/// <c>IfInput</c>/<c>ForInput</c>/<c>ForInInput</c>/<c>WhileInput</c>/<c>DoWhileInput</c>/
/// <c>SwitchInput</c>/<c>SwitchCase</c>/<c>TryInput</c>/<c>CatchClause</c> shapes — verified
/// against <c>dart/encoder/lib/encoder.dart</c>'s own field names (the reference
/// implementation).
///
/// <b>Laziness (invariant #4):</b> every branch here is built as a Ball sub-expression operand
/// of the relevant <c>std</c> call (<c>then</c>/<c>else</c>/<c>body</c>/...), never evaluated by
/// this encoder — it only ever builds trees.
///
/// C# has no labeled loop <c>break</c>/<c>continue</c> (unlike Dart/Rust), so this file has no
/// loop-label wrapping; C# does have <c>goto</c>, which — along with switch pattern-matching
/// labels and catch exception filters — is a documented gap (fails loud, never silently
/// dropped).
/// </summary>
internal sealed partial class Encoder
{
    /// <summary>Encode a single (possibly non-block) statement position — an <c>if</c>/
    /// <c>while</c>/<c>for</c>/... body, or an <c>if</c>'s <c>else</c> arm — as one Ball
    /// <c>Expression</c>. A block statement encodes as its own nested block; any other single
    /// statement is wrapped in a fresh block so the <c>std</c> control-flow input's
    /// <c>then</c>/<c>else</c>/<c>body</c> field always receives exactly one expression.</summary>
    private Expression EncodeSingleStatementAsExpr(StatementSyntax stmt)
    {
        if (stmt is BlockSyntax block)
        {
            PushScope();
            var encoded = EncodeStatementsAsBlock(block.Statements);
            PopScope();
            return encoded;
        }

        PushScope();
        var stmts = EncodeStatement(stmt);
        PopScope();
        return Builders.BlockExpr(stmts, Builders.NullLiteral());
    }

    // ════════════════════════════════════════════════════════════
    // if
    // ════════════════════════════════════════════════════════════

    private Expression EncodeIfStatement(IfStatementSyntax ifStmt)
    {
        var condition = EncodeExpr(ifStmt.Condition);
        var then = EncodeSingleStatementAsExpr(ifStmt.Statement);
        var elseBranch = ifStmt.Else is null
            ? Builders.NullLiteral()
            : EncodeSingleStatementAsExpr(ifStmt.Else.Statement);
        return Builders.IfCall(condition, then, elseBranch);
    }

    // ════════════════════════════════════════════════════════════
    // Loops
    // ════════════════════════════════════════════════════════════

    private Expression EncodeForStatement(ForStatementSyntax forStmt)
    {
        PushScope();
        var initBindings = new List<(string Name, Expression Value)>();
        if (forStmt.Declaration is not null)
        {
            foreach (var variable in forStmt.Declaration.Variables)
            {
                var name = variable.Identifier.Text;
                var value = variable.Initializer is null
                    ? Builders.NullLiteral()
                    : EncodeExpr(variable.Initializer.Value);
                initBindings.Add((name, value));
                DeclareLocal(name);
            }
        }
        else if (forStmt.Initializers.Count > 0)
        {
            throw new EncoderException(
                "ball-encoder: a `for` loop with a non-declaration initializer " +
                "(e.g. `for (i = 0; ...)`) is not supported — use `for (var i = 0; ...)` " +
                "(issue #382's scope)");
        }

        var init = Builders.ForInitBlock(initBindings);
        var condition = forStmt.Condition is null ? Builders.BoolLiteral(true) : EncodeExpr(forStmt.Condition);

        Expression update;
        if (forStmt.Incrementors.Count == 0)
        {
            update = Builders.NullLiteral();
        }
        else if (forStmt.Incrementors.Count == 1)
        {
            update = EncodeExpr(forStmt.Incrementors[0]);
        }
        else
        {
            var leading = forStmt.Incrementors
                .Take(forStmt.Incrementors.Count - 1)
                .Select(e => Builders.ExprStmt(EncodeExpr(e)))
                .ToList();
            update = Builders.BlockExpr(leading, EncodeExpr(forStmt.Incrementors[^1]));
        }

        var body = EncodeSingleStatementAsExpr(forStmt.Statement);
        PopScope();
        return Builders.StdCall(
            "for",
            Builders.ArgsMessage(("init", init), ("condition", condition), ("update", update), ("body", body)));
    }

    private Expression EncodeForEachStatement(ForEachStatementSyntax forEach)
    {
        var iterable = EncodeExpr(forEach.Expression);
        PushScope();
        DeclareLocal(forEach.Identifier.Text);
        var body = EncodeSingleStatementAsExpr(forEach.Statement);
        PopScope();
        return Builders.StdCall(
            "for_in",
            Builders.ArgsMessage(
                ("variable", Builders.StringLiteral(forEach.Identifier.Text)),
                ("iterable", iterable),
                ("body", body)));
    }

    private Expression EncodeWhileStatement(WhileStatementSyntax whileStmt)
    {
        var condition = EncodeExpr(whileStmt.Condition);
        var body = EncodeSingleStatementAsExpr(whileStmt.Statement);
        return Builders.StdCall("while", Builders.ArgsMessage(("condition", condition), ("body", body)));
    }

    private Expression EncodeDoStatement(DoStatementSyntax doStmt)
    {
        var body = EncodeSingleStatementAsExpr(doStmt.Statement);
        var condition = EncodeExpr(doStmt.Condition);
        return Builders.StdCall("do_while", Builders.ArgsMessage(("body", body), ("condition", condition)));
    }

    // ════════════════════════════════════════════════════════════
    // switch (statement form — literal/default labels only)
    // ════════════════════════════════════════════════════════════

    private Expression EncodeSwitchStatement(SwitchStatementSyntax switchStmt)
    {
        var subject = EncodeExpr(switchStmt.Expression);
        var cases = new List<Expression>();
        foreach (var section in switchStmt.Sections)
        {
            PushScope();
            var body = Builders.BlockExpr(
                section.Statements.SelectMany(EncodeStatement).ToList(),
                Builders.NullLiteral());
            PopScope();

            foreach (var label in section.Labels)
            {
                switch (label)
                {
                    case DefaultSwitchLabelSyntax:
                        cases.Add(Builders.NamedMessage(
                            "SwitchCase",
                            ("is_default", Builders.BoolLiteral(true)),
                            ("body", body)));
                        break;
                    case CaseSwitchLabelSyntax caseLabel:
                        cases.Add(Builders.NamedMessage(
                            "SwitchCase",
                            ("value", EncodeExpr(caseLabel.Value)),
                            ("is_default", Builders.BoolLiteral(false)),
                            ("body", body)));
                        break;
                    default:
                        throw new EncoderException(
                            $"ball-encoder: unsupported switch label kind `{label.Kind()}` " +
                            "(only literal `case`/`default` labels are supported — pattern " +
                            "matching is a documented gap)");
                }
            }
        }

        return Builders.StdCall(
            "switch",
            Builders.ArgsMessage(("subject", subject), ("cases", Builders.ListLiteralExpr(cases))));
    }

    // ════════════════════════════════════════════════════════════
    // try / catch / finally
    // ════════════════════════════════════════════════════════════

    private Expression EncodeTryStatement(TryStatementSyntax tryStmt)
    {
        PushScope();
        var body = EncodeStatementsAsBlock(tryStmt.Block.Statements);
        PopScope();

        var fields = new List<(string Name, Expression Value)> { ("body", body) };

        if (tryStmt.Catches.Count > 0)
        {
            var catches = new List<Expression>();
            foreach (var catchClause in tryStmt.Catches)
            {
                if (catchClause.Filter is not null)
                {
                    throw new EncoderException(
                        "ball-encoder: a `catch` exception filter (`when (...)`) is not " +
                        "supported (issue #382's scope)");
                }

                PushScope();
                var catchFields = new List<(string Name, Expression Value)>();
                if (catchClause.Declaration is not null)
                {
                    catchFields.Add(("type", Builders.StringLiteral(catchClause.Declaration.Type.ToString())));
                    var varName = catchClause.Declaration.Identifier.Text;
                    if (!string.IsNullOrEmpty(varName))
                    {
                        catchFields.Add(("variable", Builders.StringLiteral(varName)));
                        DeclareLocal(varName);
                    }
                }

                var catchBody = EncodeStatementsAsBlock(catchClause.Block.Statements);
                catchFields.Add(("body", catchBody));
                catches.Add(Builders.ArgsMessage(catchFields.ToArray()));
                PopScope();
            }

            fields.Add(("catches", Builders.ListLiteralExpr(catches)));
        }

        if (tryStmt.Finally is not null)
        {
            PushScope();
            var finallyBody = EncodeStatementsAsBlock(tryStmt.Finally.Block.Statements);
            PopScope();
            fields.Add(("finally", finallyBody));
        }

        return Builders.StdCall("try", Builders.ArgsMessage(fields.ToArray()));
    }
}
