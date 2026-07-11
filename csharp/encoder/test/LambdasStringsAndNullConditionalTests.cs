using System.Linq;
using Ball.V1;

namespace Ball.Encoder.Tests;

/// <summary>Lambdas, string interpolation, and null-conditional (<c>?.</c>) access — issue
/// #382's explicit checklist items.</summary>
public class LambdasStringsAndNullConditionalTests
{
    [Fact]
    public void EncodesZeroParamLambdaWithNoParamsMetadata()
    {
        var value = TestHelpers.NthValueExpr("Func<int> f = () => 42;", 0);
        Assert.Equal(Expression.ExprOneofCase.Lambda, value.ExprCase);
        Assert.Equal(string.Empty, value.Lambda.Name);
        Assert.Null(value.Lambda.Metadata);
    }

    [Fact]
    public void EncodesSingleParamLambdaWithParamsMetadata()
    {
        var value = TestHelpers.NthValueExpr("Func<int, int> square = x => x * x;", 0);
        Assert.Equal(Expression.ExprOneofCase.Lambda, value.ExprCase);
        var paramsList = value.Lambda.Metadata.Fields["params"].ListValue.Values;
        Assert.Single(paramsList);
        Assert.Equal("x", paramsList[0].StructValue.Fields["name"].StringValue);

        var body = value.Lambda.Body.Call;
        Assert.Equal("multiply", body.Function);
        Assert.Equal("x", body.Input.MessageCreation.Fields[0].Value.Reference.Name);
    }

    [Fact]
    public void EncodesMultiParamLambdaListingEveryParamByRealName()
    {
        var value = TestHelpers.NthValueExpr("Func<int, int, int> add = (a, b) => a + b;", 0);
        var paramsList = value.Lambda.Metadata.Fields["params"].ListValue.Values;
        Assert.Equal(new[] { "a", "b" }, paramsList.Select(p => p.StructValue.Fields["name"].StringValue));

        var addCall = value.Lambda.Body.Call;
        Assert.Equal("add", addCall.Function);
        Assert.Equal("a", addCall.Input.MessageCreation.Fields[0].Value.Reference.Name);
        Assert.Equal("b", addCall.Input.MessageCreation.Fields[1].Value.Reference.Name);
    }

    [Fact]
    public void EncodesLambdaPassedDirectlyToListSelect()
    {
        var value = TestHelpers.NthValueExpr(
            "var xs = new List<int> { 1, 2 }; var doubled = xs.Select(x => x * 2);", 1);
        Assert.Equal("std_collections", value.Call.Module);
        Assert.Equal("list_map", value.Call.Function);
        var callback = value.Call.Input.MessageCreation.Fields.Single(f => f.Name == "callback").Value;
        Assert.Equal(Expression.ExprOneofCase.Lambda, callback.ExprCase);
    }

    [Fact]
    public void EncodesInterpolatedStringAsConcatToStringChain()
    {
        var value = TestHelpers.NthValueExpr("int n = 5; var s = $\"n={n}!\";", 1);
        // "n=" + to_string(n) + "!"
        Assert.Equal("concat", value.Call.Function);
        var right = value.Call.Input.MessageCreation.Fields[1].Value;
        Assert.Equal("!", right.Literal.StringValue);
        var left = value.Call.Input.MessageCreation.Fields[0].Value;
        Assert.Equal("concat", left.Call.Function);
        var leftLeft = left.Call.Input.MessageCreation.Fields[0].Value;
        Assert.Equal("n=", leftLeft.Literal.StringValue);
        var leftRight = left.Call.Input.MessageCreation.Fields[1].Value;
        Assert.Equal("to_string", leftRight.Call.Function);
        Assert.Equal("n", leftRight.Call.Input.MessageCreation.Fields[0].Value.Reference.Name);
    }

    [Fact]
    public void EncodesEmptyInterpolatedStringAsEmptyLiteral()
    {
        var value = TestHelpers.NthValueExpr("var s = $\"\";", 0);
        Assert.Equal(Expression.ExprOneofCase.Literal, value.ExprCase);
        Assert.Equal(string.Empty, value.Literal.StringValue);
    }

    [Fact]
    public void EncodesNullConditionalFieldAccessAsEqualsNullGuard()
    {
        var value = TestHelpers.NthValueExpr("string? s = null; var len = s?.Length;", 1);
        Assert.Equal("if", value.Call.Function);
        var fields = value.Call.Input.MessageCreation.Fields;
        var condition = fields[0].Value;
        Assert.Equal("equals", condition.Call.Function);
        Assert.Equal("s", condition.Call.Input.MessageCreation.Fields[0].Value.Reference.Name);
        Assert.Equal(Literal.ValueOneofCase.None, condition.Call.Input.MessageCreation.Fields[1].Value.Literal.ValueCase);

        var thenBranch = fields[1].Value;
        Assert.Equal(Literal.ValueOneofCase.None, thenBranch.Literal.ValueCase);

        var elseBranch = fields[2].Value;
        Assert.Equal("length", elseBranch.Call.Function);
    }

    [Fact]
    public void EncodesNullConditionalCombinedWithNullCoalesce()
    {
        var value = TestHelpers.NthValueExpr("string? s = null; var len = s?.Length ?? -1;", 1);
        Assert.Equal("null_coalesce", value.Call.Function);
        var left = value.Call.Input.MessageCreation.Fields[0].Value;
        Assert.Equal("if", left.Call.Function);
    }

    [Fact]
    public void EncodesNullConditionalMethodCall()
    {
        var value = TestHelpers.NthValueExpr("string? s = null; var upper = s?.ToUpper();", 1);
        var elseBranch = value.Call.Input.MessageCreation.Fields[2].Value;
        Assert.Equal("string_to_upper", elseBranch.Call.Function);
    }
}
