using Ball.V1;
using Google.Protobuf.Reflection;

namespace Ball.Shared;

/// <summary>
/// Shared protobuf-descriptor construction helpers for the std module builders.
/// Mirrors <c>rust/shared/src/descriptor_builders.rs</c> (and the small private
/// <c>_type</c>/<c>_fn</c>/<c>_exprField</c>/… helpers at the bottom of every
/// <c>dart/shared/lib/std*.dart</c>). Kept in one place rather than copy-pasted
/// per module.
/// </summary>
internal static class DescriptorBuilders
{
    /// <summary>Fully-qualified type name used for every <c>Expression</c>-typed descriptor field.</summary>
    private const string ExpressionTypeName = ".ball.v1.Expression";

    /// <summary>Build a base-function input <see cref="TypeDefinition"/> from a name and its fields.</summary>
    internal static TypeDefinition TypeDef(string name, params FieldDescriptorProto[] fields)
    {
        var descriptor = new DescriptorProto { Name = name };
        descriptor.Field.AddRange(fields);
        return new TypeDefinition { Name = name, Descriptor_ = descriptor };
    }

    /// <summary>A single-valued <c>Expression</c> field (<c>LABEL_OPTIONAL</c>).</summary>
    internal static FieldDescriptorProto ExprField(string name, int number) => new()
    {
        Name = name,
        Number = number,
        Type = FieldDescriptorProto.Types.Type.Message,
        TypeName = ExpressionTypeName,
        Label = FieldDescriptorProto.Types.Label.Optional,
    };

    /// <summary>A repeated <c>Expression</c> field (<c>LABEL_REPEATED</c>).</summary>
    internal static FieldDescriptorProto ExprListField(string name, int number) => new()
    {
        Name = name,
        Number = number,
        Type = FieldDescriptorProto.Types.Type.Message,
        TypeName = ExpressionTypeName,
        Label = FieldDescriptorProto.Types.Label.Repeated,
    };

    /// <summary>A single-valued <c>string</c> field.</summary>
    internal static FieldDescriptorProto StringField(string name, int number) => new()
    {
        Name = name,
        Number = number,
        Type = FieldDescriptorProto.Types.Type.String,
        Label = FieldDescriptorProto.Types.Label.Optional,
    };

    /// <summary>A single-valued <c>bool</c> field.</summary>
    internal static FieldDescriptorProto BoolField(string name, int number) => new()
    {
        Name = name,
        Number = number,
        Type = FieldDescriptorProto.Types.Type.Bool,
        Label = FieldDescriptorProto.Types.Label.Optional,
    };

    /// <summary>A single-valued <c>int64</c> field.</summary>
    internal static FieldDescriptorProto IntField(string name, int number) => new()
    {
        Name = name,
        Number = number,
        Type = FieldDescriptorProto.Types.Type.Int64,
        Label = FieldDescriptorProto.Types.Label.Optional,
    };

    /// <summary>
    /// Build a base <see cref="FunctionDefinition"/>: <c>is_base = true</c>, no
    /// <c>body</c> — the per-platform compiler/engine supplies the implementation
    /// (invariant #3).
    /// </summary>
    internal static FunctionDefinition BaseFn(string name, string inputType, string outputType, string description) => new()
    {
        Name = name,
        InputType = inputType,
        OutputType = outputType,
        Description = description,
        IsBase = true,
    };
}
