using System.Collections.Generic;
using Ball.V1;
using Google.Protobuf.WellKnownTypes;

namespace Ball.Encoder;

/// <summary>
/// Free helper functions that build Ball <see cref="Expression"/>/<see cref="Statement"/>/
/// <see cref="Google.Protobuf.WellKnownTypes.Struct"/> trees. Mirrors the free-function
/// helper section at the bottom of <c>rust/encoder/src/lib.rs</c> (int_literal,
/// reference, args_message, std_call, MetaBuilder, ...) — kept as one static toolbox
/// rather than instance methods, since none of them need encoder state.
/// </summary>
internal static class Builders
{
    // ── Literals ─────────────────────────────────────────────

    internal static Expression IntLiteral(long value) => new()
    {
        Literal = new Literal { IntValue = value },
    };

    internal static Expression DoubleLiteral(double value) => new()
    {
        Literal = new Literal { DoubleValue = value },
    };

    internal static Expression StringLiteral(string value) => new()
    {
        Literal = new Literal { StringValue = value },
    };

    internal static Expression BoolLiteral(bool value) => new()
    {
        Literal = new Literal { BoolValue = value },
    };

    internal static Expression BytesLiteral(Google.Protobuf.ByteString value) => new()
    {
        Literal = new Literal { BytesValue = value },
    };

    /// <summary>A Ball <c>literal</c> with no oneof case set at all — the canonical "null"
    /// value every reference engine's literal evaluator treats as null (see
    /// <c>dart/engine/lib/engine_eval.dart</c>'s literal-with-no-case handling).</summary>
    internal static Expression NullLiteral() => new() { Literal = new Literal() };

    internal static Expression ListLiteralExpr(IEnumerable<Expression> elements)
    {
        var list = new ListLiteral();
        list.Elements.AddRange(elements);
        return new Expression { Literal = new Literal { ListValue = list } };
    }

    // ── References / field access ───────────────────────────

    internal static Expression ReferenceExpr(string name) => new()
    {
        Reference = new Reference { Name = name },
    };

    internal static Expression FieldAccessExpr(Expression target, string field) => new()
    {
        FieldAccess = new FieldAccess { Object = target, Field = field },
    };

    /// <summary><c>field_access(reference("self"), field)</c> — the receiver-field access
    /// shape every instance method body uses (see the engine's automatic <c>self</c>
    /// binding — <c>dart/engine/lib/engine_invocation.dart</c>'s
    /// <c>if (inputMap.containsKey('self')) { scope.bind('self', self); ... }</c>).</summary>
    internal static Expression SelfFieldAccess(string field) => FieldAccessExpr(ReferenceExpr("self"), field);

    // ── Message creation (base-function call inputs) ────────

    /// <summary>An anonymous (<c>type_name</c> empty) <c>message_creation</c> — the "pack
    /// named arguments for a base-function call" shape every base function's input uses.
    /// Field order is preserved (matters for round-trip readability, never for semantics —
    /// <see cref="Ball.Shared.Fields.Extract"/> looks fields up by name).</summary>
    internal static Expression ArgsMessage(params (string Name, Expression Value)[] fields)
    {
        var creation = new MessageCreation();
        foreach (var (name, value) in fields)
        {
            creation.Fields.Add(new FieldValuePair { Name = name, Value = value });
        }

        return new Expression { MessageCreation = creation };
    }

    /// <summary>A named (<c>type_name</c> non-empty) <c>message_creation</c> — used for
    /// user-defined types (<c>new Foo { X = 1 }</c>) and the typed base-input shapes
    /// (<c>SwitchCase</c>, <c>CatchClause</c>) documented in <c>StdModuleBuilders</c>.</summary>
    internal static Expression NamedMessage(string typeName, params (string Name, Expression Value)[] fields)
    {
        var creation = new MessageCreation { TypeName = typeName };
        foreach (var (name, value) in fields)
        {
            creation.Fields.Add(new FieldValuePair { Name = name, Value = value });
        }

        return new Expression { MessageCreation = creation };
    }

    internal static Expression NamedMessage(string typeName, List<(string Name, Expression Value)> fields) =>
        NamedMessage(typeName, fields.ToArray());

    // ── Statements / blocks ──────────────────────────────────

    internal static Statement LetStmt(string name, Expression value, Struct? metadata = null) => new()
    {
        Let = new LetBinding { Name = name, Value = value, Metadata = metadata },
    };

    internal static Statement ExprStmt(Expression value) => new() { Expression = value };

    internal static Expression BlockExpr(List<Statement> statements, Expression result) => new()
    {
        Block = new Block { Statements = { statements }, Result = result },
    };

    /// <summary>A <c>for</c> loop's <c>init</c> clause shape: a <c>block</c> of fresh
    /// <c>let</c>-bindings with <b>no</b> result (mirrors
    /// <c>rust/encoder/src/lib.rs::for_init_block</c>).</summary>
    internal static Expression ForInitBlock(List<(string Name, Expression Value)> bindings)
    {
        var block = new Block();
        foreach (var (name, value) in bindings)
        {
            block.Statements.Add(LetStmt(name, value));
        }

        return new Expression { Block = block };
    }

    // ── Base-function calls ──────────────────────────────────

    internal static Expression StdCall(string function, Expression? input) => new()
    {
        Call = new FunctionCall { Module = "std", Function = function, Input = input },
    };

    internal static Expression CollectionsCall(string function, Expression? input) => new()
    {
        Call = new FunctionCall { Module = "std_collections", Function = function, Input = input },
    };

    /// <summary>A same-file user-function/method call: <c>module=""</c>, resolved by
    /// ordinary Ball name lookup (free function in the same module, or an instance method
    /// keyed by the receiver's runtime type — see <c>lib.rs::encode_user_call</c>).</summary>
    internal static Expression UserCall(string function, Expression? input) => new()
    {
        Call = new FunctionCall { Module = "", Function = function, Input = input },
    };

    internal static Expression BinaryStd(string function, Expression left, Expression right) =>
        StdCall(function, ArgsMessage(("left", left), ("right", right)));

    internal static Expression UnaryStd(string function, Expression value) =>
        StdCall(function, ArgsMessage(("value", value)));

    /// <summary><c>std.if(condition, then, else)</c> — lazy control flow (invariant #4):
    /// every branch is threaded through as a sub-expression, never pre-evaluated here.</summary>
    internal static Expression IfCall(Expression condition, Expression then, Expression elseBranch) =>
        StdCall("if", ArgsMessage(("condition", condition), ("then", then), ("else", elseBranch)));

    // ── Cosmetic metadata (Google.Protobuf.WellKnownTypes.Struct/Value) ─────

    internal static Value StrValue(string value) => new() { StringValue = value };

    internal static Value BoolValue(bool value) => new() { BoolValue = value };

    internal static Value StructValue(params (string Name, Value Value)[] fields)
    {
        var s = new Struct();
        foreach (var (name, value) in fields)
        {
            s.Fields[name] = value;
        }

        return new Value { StructValue = s };
    }

    internal static Value ListValueOf(IEnumerable<Value> items)
    {
        var list = new ListValue();
        list.Values.AddRange(items);
        return new Value { ListValue = list };
    }

    /// <summary><c>metadata.params = [{name: &lt;name&gt;}, ...]</c> — the engine-level
    /// (not merely compiler-cosmetic) parameter-binding contract: <c>_extractParams</c> in
    /// <c>dart/engine/lib/engine_invocation.dart</c> reads this list to bind a function's
    /// declared parameter name(s) into scope (single param → bind directly; 2+ → extract
    /// each by name from the packed input map). For an instance method, list only the
    /// <b>non-self</b> parameters — the engine binds <c>self</c> unconditionally whenever
    /// the input map carries a <c>"self"</c> key, regardless of what <c>params</c> says.</summary>
    internal static Struct SingleParamMetadata(string name) => new Struct
    {
        Fields =
        {
            ["params"] = ListValueOf(new[] { StructValue(("name", StrValue(name))) }),
        },
    };

    internal static Struct ParamsMetadata(IReadOnlyList<string> names)
    {
        var values = new List<Value>();
        foreach (var name in names)
        {
            values.Add(StructValue(("name", StrValue(name))));
        }

        return new Struct { Fields = { ["params"] = ListValueOf(values) } };
    }

    /// <summary>Merge two optional metadata Structs (disjoint key sets in every caller —
    /// mirrors <c>rust/encoder/src/lib.rs::merge_struct</c>).</summary>
    internal static Struct? MergeStruct(Struct? a, Struct? b)
    {
        if (a is null) return b;
        if (b is null) return a;
        var merged = new Struct();
        merged.Fields.Add(a.Fields);
        merged.Fields.Add(b.Fields);
        return merged;
    }
}

/// <summary>
/// Accumulates cosmetic <c>metadata</c> Struct entries: visibility, generics, a
/// type/function's <c>kind</c>, and per-field documentation. Every key this builder sets
/// is purely cosmetic (invariant #2) EXCEPT <c>params</c> (set via
/// <see cref="Builders.ParamsMetadata"/>/<see cref="Builders.SingleParamMetadata"/>
/// separately, since that one IS read by the engine — see their doc comments). Mirrors
/// <c>rust/encoder/src/lib.rs::MetaBuilder</c>.
/// </summary>
internal sealed class MetaBuilder
{
    private readonly Dictionary<string, Value> _fields = new();

    internal MetaBuilder SetString(string key, string value)
    {
        _fields[key] = Builders.StrValue(value);
        return this;
    }

    /// <summary>Only sets <paramref name="key"/> when <paramref name="value"/> is true —
    /// absence means false, so a construct that never uses a feature carries no
    /// forest of false-valued metadata keys.</summary>
    internal MetaBuilder SetBoolIfTrue(string key, bool value)
    {
        if (value)
        {
            _fields[key] = Builders.BoolValue(true);
        }

        return this;
    }

    internal MetaBuilder SetListIfNonempty(string key, List<Value> values)
    {
        if (values.Count > 0)
        {
            _fields[key] = Builders.ListValueOf(values);
        }

        return this;
    }

    internal Struct? Build() => _fields.Count == 0 ? null : new Struct { Fields = { _fields } };
}
