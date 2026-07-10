using System.Collections.Generic;
using Ball.V1;

namespace Ball.Shared;

/// <summary>
/// The universal base-function calling convention: pull named fields out of a
/// <see cref="FunctionCall"/>'s input expression (CLAUDE.md "Base functions have
/// no body"). Mirrors <c>rust/shared/src/value.rs</c>'s <c>extract_fields</c>
/// and Dart's <c>_extractFields</c>.
/// </summary>
public static class Fields
{
    /// <summary>
    /// Extract the named argument fields of <paramref name="call"/>, preserving
    /// declaration order:
    /// <list type="bullet">
    /// <item>No input at all → an empty map.</item>
    /// <item>A <c>MessageCreation</c> input → <c>{field.name: field.value, …}</c>
    /// (a field with no explicit value maps to a default, non-null
    /// <see cref="Expression"/>, matching Dart protobuf's auto-vivifying getter).</item>
    /// <item>Any other input (a unary base function's single argument) →
    /// <c>{"value": input}</c>.</item>
    /// </list>
    /// </summary>
    public static OrderedDictionary<string, Expression> Extract(FunctionCall call)
    {
        var fields = new OrderedDictionary<string, Expression>();
        var input = call.Input;
        if (input is null)
        {
            return fields;
        }

        if (input.ExprCase == Expression.ExprOneofCase.MessageCreation)
        {
            foreach (var pair in input.MessageCreation.Fields)
            {
                fields[pair.Name] = pair.Value ?? new Expression();
            }

            return fields;
        }

        fields["value"] = input;
        return fields;
    }
}
