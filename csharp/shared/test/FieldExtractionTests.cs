using Ball.Shared;
using Ball.V1;

namespace Ball.Shared.Tests;

/// <summary>
/// Tests for <see cref="Fields.Extract(FunctionCall)"/> — the universal
/// base-function calling convention (CLAUDE.md "Base functions have no body").
/// Mirrors <c>rust/shared/src/value.rs</c>'s <c>extract_fields</c> tests and
/// Dart's <c>_extractFields</c>.
/// </summary>
public class FieldExtractionTests
{
    private static Expression IntLiteral(long value) =>
        new() { Literal = new Literal { IntValue = value } };

    [Fact]
    public void MessageCreationInputMapsEachFieldPair()
    {
        var call = new FunctionCall
        {
            Function = "add",
            Input = new Expression
            {
                MessageCreation = new MessageCreation
                {
                    TypeName = "BinaryInput",
                    Fields =
                    {
                        new FieldValuePair { Name = "left", Value = IntLiteral(1) },
                        new FieldValuePair { Name = "right", Value = IntLiteral(2) },
                    },
                },
            },
        };

        var fields = Fields.Extract(call);
        Assert.Equal(new[] { "left", "right" }, fields.Keys);
        Assert.Equal(IntLiteral(1), fields["left"]);
        Assert.Equal(IntLiteral(2), fields["right"]);
    }

    [Fact]
    public void NonMessageInputMapsToValueKey()
    {
        var call = new FunctionCall { Function = "negate", Input = IntLiteral(5) };
        var fields = Fields.Extract(call);
        Assert.Equal(new[] { "value" }, fields.Keys);
        Assert.Equal(IntLiteral(5), fields["value"]);
    }

    [Fact]
    public void NoInputIsEmpty()
    {
        var call = new FunctionCall { Function = "read_line" };
        Assert.Empty(Fields.Extract(call));
    }

    [Fact]
    public void MessageFieldWithNoValueMapsToDefaultExpression()
    {
        var call = new FunctionCall
        {
            Function = "f",
            Input = new Expression
            {
                MessageCreation = new MessageCreation
                {
                    TypeName = "X",
                    Fields = { new FieldValuePair { Name = "a" } },
                },
            },
        };

        var fields = Fields.Extract(call);
        Assert.Equal(new[] { "a" }, fields.Keys);
        Assert.NotNull(fields["a"]); // absent value → default Expression, never null
    }

    [Fact]
    public void PreservesFieldOrder()
    {
        var call = new FunctionCall
        {
            Function = "f",
            Input = new Expression
            {
                MessageCreation = new MessageCreation
                {
                    TypeName = "X",
                    Fields =
                    {
                        new FieldValuePair { Name = "z", Value = IntLiteral(1) },
                        new FieldValuePair { Name = "a", Value = IntLiteral(2) },
                        new FieldValuePair { Name = "m", Value = IntLiteral(3) },
                    },
                },
            },
        };

        Assert.Equal(new[] { "z", "a", "m" }, Fields.Extract(call).Keys);
    }
}
