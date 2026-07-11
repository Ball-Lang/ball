using Ball.V1;

namespace Ball.Encoder.Tests;

/// <summary>Literals and operators → universal <c>std</c> calls (issue #382's "operators →
/// std calls" checklist item).</summary>
public class LiteralsAndOperatorsTests
{
    [Fact]
    public void EncodesEveryLiteralKind()
    {
        var stmts = TestHelpers.MainStatements(
            "var a = 42; var b = 3.5; var c = \"hi\"; var d = true; var e = false; string? f = null;");

        Assert.Equal(Literal.ValueOneofCase.IntValue, stmts[0].Let.Value.Literal.ValueCase);
        Assert.Equal(42, stmts[0].Let.Value.Literal.IntValue);
        Assert.Equal(Literal.ValueOneofCase.DoubleValue, stmts[1].Let.Value.Literal.ValueCase);
        Assert.Equal(3.5, stmts[1].Let.Value.Literal.DoubleValue);
        Assert.Equal(Literal.ValueOneofCase.StringValue, stmts[2].Let.Value.Literal.ValueCase);
        Assert.Equal("hi", stmts[2].Let.Value.Literal.StringValue);
        Assert.True(stmts[3].Let.Value.Literal.BoolValue);
        Assert.False(stmts[4].Let.Value.Literal.BoolValue);
        Assert.Equal(Literal.ValueOneofCase.None, stmts[5].Let.Value.Literal.ValueCase);
    }

    [Fact]
    public void EncodesCharLiteralAsOneCharacterString()
    {
        var value = TestHelpers.NthValueExpr("var c = 'x';", 0);
        Assert.Equal("x", value.Literal.StringValue);
    }

    [Theory]
    [InlineData("a + b", "add")]
    [InlineData("a - b", "subtract")]
    [InlineData("a * b", "multiply")]
    [InlineData("a % b", "modulo")]
    [InlineData("a == b", "equals")]
    [InlineData("a != b", "not_equals")]
    [InlineData("a < b", "less_than")]
    [InlineData("a > b", "greater_than")]
    [InlineData("a <= b", "lte")]
    [InlineData("a >= b", "gte")]
    [InlineData("a && b", "and")]
    [InlineData("a || b", "or")]
    [InlineData("a & b", "bitwise_and")]
    [InlineData("a | b", "bitwise_or")]
    [InlineData("a ^ b", "bitwise_xor")]
    [InlineData("a << b", "left_shift")]
    [InlineData("a >> b", "right_shift")]
    [InlineData("a ?? b", "null_coalesce")]
    public void EncodesBinaryOperatorsAsStdCalls(string csExpr, string stdFn)
    {
        var value = TestHelpers.NthValueExpr($"int a = 1; int b = 2; var r = {csExpr};", 2);
        Assert.Equal(Expression.ExprOneofCase.Call, value.ExprCase);
        Assert.Equal("std", value.Call.Module);
        Assert.Equal(stdFn, value.Call.Function);
        Assert.Equal(2, value.Call.Input.MessageCreation.Fields.Count);
        Assert.Equal("left", value.Call.Input.MessageCreation.Fields[0].Name);
        Assert.Equal("right", value.Call.Input.MessageCreation.Fields[1].Name);
    }

    [Fact]
    public void DivideTruncatesByDefaultButUsesDoubleForAFloatLiteralOperand()
    {
        var truncating = TestHelpers.NthValueExpr("int a = 1; var r = a / 2;", 1);
        Assert.Equal("divide", truncating.Call.Function);

        var floating = TestHelpers.NthValueExpr("int a = 1; var r = a / 2.0;", 1);
        Assert.Equal("divide_double", floating.Call.Function);
    }

    [Theory]
    [InlineData("-a", "negate")]
    [InlineData("!a", "not")]
    [InlineData("~a", "bitwise_not")]
    [InlineData("++a", "pre_increment")]
    [InlineData("--a", "pre_decrement")]
    public void EncodesPrefixUnaryOperators(string csExpr, string stdFn)
    {
        var value = TestHelpers.NthValueExpr($"int a = 1; var r = {csExpr};", 1);
        Assert.Equal("std", value.Call.Module);
        Assert.Equal(stdFn, value.Call.Function);
    }

    [Theory]
    [InlineData("a++", "post_increment")]
    [InlineData("a--", "post_decrement")]
    public void EncodesPostfixUnaryOperators(string csExpr, string stdFn)
    {
        var value = TestHelpers.NthValueExpr($"int a = 1; var r = {csExpr};", 1);
        Assert.Equal(stdFn, value.Call.Function);
    }

    [Fact]
    public void EncodesSimpleAssignmentWithNoOpField()
    {
        var value = TestHelpers.NthValueExpr("int a = 1; a = 2;", 1);
        Assert.Equal("assign", value.Call.Function);
        Assert.DoesNotContain(value.Call.Input.MessageCreation.Fields, f => f.Name == "op");
        Assert.Equal("target", value.Call.Input.MessageCreation.Fields[0].Name);
        Assert.Equal("value", value.Call.Input.MessageCreation.Fields[1].Name);
    }

    [Fact]
    public void EncodesCompoundAssignmentWithOpField()
    {
        var value = TestHelpers.NthValueExpr("int a = 1; a += 3;", 1);
        Assert.Equal("assign", value.Call.Function);
        var op = Assert.Single(value.Call.Input.MessageCreation.Fields, f => f.Name == "op");
        Assert.Equal("+=", op.Value.Literal.StringValue);
    }

    [Fact]
    public void EncodesTernaryAsLazyIfCall()
    {
        var value = TestHelpers.NthValueExpr("int a = 1; var r = a > 0 ? 1 : -1;", 1);
        Assert.Equal("if", value.Call.Function);
        var fields = value.Call.Input.MessageCreation.Fields;
        Assert.Equal("condition", fields[0].Name);
        Assert.Equal("then", fields[1].Name);
        Assert.Equal("else", fields[2].Name);
        // Both branches must be present as sub-expressions — never pre-evaluated
        // (invariant #4: lazy control flow).
        Assert.Equal(Expression.ExprOneofCase.Literal, fields[1].Value.ExprCase);
        Assert.Equal(Expression.ExprOneofCase.Call, fields[2].Value.ExprCase);
        Assert.Equal("negate", fields[2].Value.Call.Function);
    }

    [Fact]
    public void EncodesIndexerAccessAndAssignment()
    {
        var stmts = TestHelpers.MainStatements(
            "var xs = new List<int> { 1, 2, 3 }; var first = xs[0]; xs[0] = 9;");
        var readExpr = stmts[1].Let.Value;
        Assert.Equal("index", readExpr.Call.Function);

        var writeExpr = stmts[2].Expression;
        Assert.Equal("assign", writeExpr.Call.Function);
        var target = writeExpr.Call.Input.MessageCreation.Fields[0].Value;
        Assert.Equal("index", target.Call.Function);
    }
}
