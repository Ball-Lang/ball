using Ball.V1;

namespace Ball.Encoder.Tests;

/// <summary>Control flow → LAZY <c>std</c> shapes (issue #382's "control flow (if/for/while/
/// foreach/switch/try) → LAZY std shapes" checklist item — invariant #4: every branch/body is
/// a sub-expression, never pre-evaluated by the encoder).</summary>
public class ControlFlowTests
{
    [Fact]
    public void EncodesIfElseAsStdIf()
    {
        var value = TestHelpers.NthValueExpr(
            "int a = 1; int r; if (a > 0) { r = 1; } else { r = -1; }", 2);
        Assert.Equal("if", value.Call.Function);
        var fields = value.Call.Input.MessageCreation.Fields;
        Assert.Equal("condition", fields[0].Name);
        Assert.Equal("then", fields[1].Name);
        Assert.Equal("else", fields[2].Name);
        Assert.Equal(Expression.ExprOneofCase.Block, fields[1].Value.ExprCase);
        Assert.Equal(Expression.ExprOneofCase.Block, fields[2].Value.ExprCase);
    }

    [Fact]
    public void EncodesIfWithNoElseAsNullElseBranch()
    {
        var value = TestHelpers.NthValueExpr("int a = 1; if (a > 0) { a = 2; }", 1);
        var elseBranch = value.Call.Input.MessageCreation.Fields[2].Value;
        Assert.Equal(Expression.ExprOneofCase.Literal, elseBranch.ExprCase);
        Assert.Equal(Literal.ValueOneofCase.None, elseBranch.Literal.ValueCase);
    }

    [Fact]
    public void EncodesForLoopWithInitConditionUpdateBody()
    {
        var value = TestHelpers.NthValueExpr("for (int i = 0; i < 3; i++) { int x = i; }", 0);
        Assert.Equal("for", value.Call.Function);
        var fields = value.Call.Input.MessageCreation.Fields;
        Assert.Equal("init", fields[0].Name);
        Assert.Equal("condition", fields[1].Name);
        Assert.Equal("update", fields[2].Name);
        Assert.Equal("body", fields[3].Name);
        // init is a block of fresh let-bindings with NO result.
        Assert.Equal(Expression.ExprOneofCase.Block, fields[0].Value.ExprCase);
        Assert.Equal("i", fields[0].Value.Block.Statements[0].Let.Name);
        Assert.Null(fields[0].Value.Block.Result);
    }

    [Fact]
    public void EncodesForEachAsForIn()
    {
        var value = TestHelpers.NthValueExpr(
            "var xs = new List<int> { 1 }; int total = 0; foreach (var x in xs) { total += x; }", 2);
        Assert.Equal("for_in", value.Call.Function);
        var fields = value.Call.Input.MessageCreation.Fields;
        Assert.Equal("variable", fields[0].Name);
        Assert.Equal("x", fields[0].Value.Literal.StringValue);
        Assert.Equal("iterable", fields[1].Name);
        Assert.Equal("body", fields[2].Name);
    }

    [Fact]
    public void EncodesWhileLoop()
    {
        var value = TestHelpers.NthValueExpr("int i = 0; while (i < 3) { i++; }", 1);
        Assert.Equal("while", value.Call.Function);
        var fields = value.Call.Input.MessageCreation.Fields;
        Assert.Equal("condition", fields[0].Name);
        Assert.Equal("body", fields[1].Name);
    }

    [Fact]
    public void EncodesDoWhileLoop()
    {
        var value = TestHelpers.NthValueExpr("int i = 0; do { i++; } while (i < 3);", 1);
        Assert.Equal("do_while", value.Call.Function);
        var fields = value.Call.Input.MessageCreation.Fields;
        Assert.Equal("body", fields[0].Name);
        Assert.Equal("condition", fields[1].Name);
    }

    [Fact]
    public void EncodesSwitchStatementWithLiteralCasesAndDefault()
    {
        var value = TestHelpers.NthValueExpr(
            "int day = 3; string label = \"\"; " +
            "switch (day) { case 1: label = \"Mon\"; break; case 3: label = \"Wed\"; break; " +
            "default: label = \"Other\"; break; }",
            2);
        Assert.Equal("switch", value.Call.Function);
        var fields = value.Call.Input.MessageCreation.Fields;
        Assert.Equal("subject", fields[0].Name);
        Assert.Equal("cases", fields[1].Name);
        var cases = fields[1].Value.Literal.ListValue.Elements;
        Assert.Equal(3, cases.Count);
        Assert.Equal("SwitchCase", cases[0].MessageCreation.TypeName);
        Assert.Equal(1, cases[0].MessageCreation.Fields[0].Value.Literal.IntValue);
        Assert.Contains(cases[2].MessageCreation.Fields, f => f.Name == "is_default" && f.Value.Literal.BoolValue);
    }

    [Fact]
    public void EncodesTryCatchFinally()
    {
        var value = TestHelpers.NthValueExpr(
            "int result = 0; " +
            "try { throw new Exception(\"boom\"); } " +
            "catch (Exception e) { result = 1; } " +
            "finally { result = 2; }",
            1);
        Assert.Equal("try", value.Call.Function);
        var fields = value.Call.Input.MessageCreation.Fields;
        Assert.Equal("body", fields[0].Name);
        Assert.Equal("catches", fields[1].Name);
        Assert.Equal("finally", fields[2].Name);

        var catchEntry = fields[1].Value.Literal.ListValue.Elements[0].MessageCreation;
        Assert.Contains(catchEntry.Fields, f => f.Name == "type" && f.Value.Literal.StringValue == "Exception");
        Assert.Contains(catchEntry.Fields, f => f.Name == "variable" && f.Value.Literal.StringValue == "e");
        Assert.Contains(catchEntry.Fields, f => f.Name == "body");
    }

    [Fact]
    public void EncodesBreakInsideForLoopBody()
    {
        var value = TestHelpers.NthValueExpr(
            "for (int i = 0; i < 3; i++) { if (i == 2) { break; } }", 0);
        var body = value.Call.Input.MessageCreation.Fields[3].Value;
        var ifCall = body.Block.Statements[0].Expression;
        var thenBranch = ifCall.Call.Input.MessageCreation.Fields[1].Value;
        var breakCall = thenBranch.Block.Statements[0].Expression;
        Assert.Equal("break", breakCall.Call.Function);
    }

    [Fact]
    public void EncodesContinueInsideForLoopBody()
    {
        var value = TestHelpers.NthValueExpr(
            "for (int i = 0; i < 3; i++) { if (i == 1) { continue; } }", 0);
        var body = value.Call.Input.MessageCreation.Fields[3].Value;
        var ifCall = body.Block.Statements[0].Expression;
        var thenBranch = ifCall.Call.Input.MessageCreation.Fields[1].Value;
        var continueCall = thenBranch.Block.Statements[0].Expression;
        Assert.Equal("continue", continueCall.Call.Function);
    }

    [Fact]
    public void EncodesThrowStatementAndExpression()
    {
        var stmtThrow = TestHelpers.NthValueExpr("throw new Exception(\"x\");", 0);
        Assert.Equal("throw", stmtThrow.Call.Function);
        Assert.Equal("Exception", stmtThrow.Call.Input.MessageCreation.Fields[0].Value.MessageCreation.TypeName);
    }

    [Fact]
    public void EncodesReturnAsExplicitStdReturnNotBlockResult()
    {
        var stmts = TestHelpers.MainStatements("return;");
        Assert.Equal("return", stmts[0].Expression.Call.Function);
    }
}
