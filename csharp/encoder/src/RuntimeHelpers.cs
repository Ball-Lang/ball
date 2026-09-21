using Ball.V1;
using Microsoft.CodeAnalysis.CSharp.Syntax;

namespace Ball.Encoder;

/// <summary>
/// Recognizing the Ball C# runtime's own dispatch helpers (<c>BallRuntime.*</c>)
/// and the <c>BallValue</c> literal factories.
///
/// <para><c>Ball.Shared</c> is an ordinary referenced assembly, so
/// <c>BallRuntime.Add(a, b)</c> is a perfectly normal thing to find in
/// hand-written C# — but the reason this file exists is the ROUND-TRIP leg
/// (issue #642): <c>Ball.Compiler</c> emits every Ball base-function call as
/// exactly one of these helpers, and the encoder used to refuse all of them
/// (<c>unsupported method call `.Print(...)`</c>), so not one of the conformance
/// fixtures could survive Ball → C# → Ball. The leg measured a flat 0 and its CI
/// row went green on it.</para>
///
/// <para>Every entry below is the exact INVERSE of one line in
/// <c>compiler/src/BaseCall.cs</c>: the helper's name, the base function it is
/// the emission of, and that base function's input field for each positional
/// argument (a base call's input is always a message keyed by field name —
/// <c>{left, right}</c>, <c>{value}</c>, …). Keep the two in step. A helper the
/// compiler emits but this table does not name is NOT silently mis-encoded: it
/// falls through to the encoder's existing loud refusal (issue #55 doctrine),
/// which is why the table is deliberately restricted to helpers whose shape is
/// unambiguous:</para>
/// <list type="bullet">
///   <item>fixed arity, every argument a real expression — helpers the compiler
///   calls with a <c>BallValue.Null</c> placeholder for an omitted optional
///   argument (<c>StringSubstring</c>, <c>ToStringAsExponential</c>) are left
///   out rather than guessed at;</item>
///   <item>a <c>std</c> base function <c>dart/shared/std.json</c> actually
///   declares (the canonical base-function inventory);</item>
///   <item>no type-name string operands (<c>IsType</c>/<c>AsType</c>/
///   <c>TypeLiteral</c> take a C# string literal, not an encodable
///   expression).</item>
/// </list>
///
/// <para>Four helpers sit OUTSIDE that table on purpose, as named node-shaped
/// arms (<see cref="FieldGet"/>, <see cref="ArgGet"/>, <see cref="FieldSet"/>,
/// <see cref="MessageTypeName"/> — issue #689): their inverses are not "one
/// <c>std</c> base call whose positional arguments fill named input fields" at
/// all, so expressing them as rows would have meant widening every row to carry
/// a shape it does not have. Each arm keeps the same fail-loud boundary — a
/// non-literal key, or the wrong arity, is an error.</para>
///
/// <para>The compiler's OBJECT MODEL is three more shapes that are not helper
/// calls at all but <c>new</c> expressions over <c>Ball.Shared</c>'s own value
/// types — <see cref="MessageClass"/>, <see cref="MapClass"/>,
/// <see cref="ListClass"/>. They are inverted in <c>encoder/src/Types.cs</c>'s
/// <c>EncodeObjectCreation</c>, AFTER a same-file class declaration of the same
/// name has had its chance to win (the shadowing order C# itself uses, and the
/// one the <c>*Exception</c> fallback beside them already follows).</para>
///
/// <para>Statement-shaped lowerings (<c>if</c>/<c>for</c>/<c>while</c>/
/// <c>try</c>) are not here at all: the compiler emits them as native C#
/// statements, which the encoder already reads back from that syntax.</para>
/// </summary>
internal static class RuntimeHelpers
{
    /// <summary>The static class every compiled program dispatches its base calls through.</summary>
    internal const string RuntimeClass = "BallRuntime";

    /// <summary>The value type whose static factories the compiler emits for literals.</summary>
    internal const string ValueClass = "BallValue";

    /// <summary>
    /// <c>new BallMessage("&lt;type&gt;", new BallMap { … })</c> — the compiler's emission of a
    /// TYPED <c>message_creation</c> node (<c>CSharpCompiler.CompileMessageCreation</c>'s
    /// <c>mc.TypeName.Length != 0</c> arm, and the same shape
    /// <c>compiler/src/Constructors.cs</c> and <c>compiler/src/TypeEmit.cs</c> build).
    /// </summary>
    internal const string MessageClass = "BallMessage";

    /// <summary>
    /// <c>new BallMap { ["k"] = v }</c> — the emission of an UNTYPED <c>message_creation</c>
    /// (the same method's <c>mc.TypeName.Length == 0</c> arm): a base call's named arguments, and
    /// every instance-method call site's <c>{self, …}</c> input. A genuine Ball map LITERAL is a
    /// different emission (<c>BallRuntime.MapCreate(…)</c>, <c>compiler/src/BaseCall.cs</c>), so
    /// there is no ambiguity between the two.
    /// </summary>
    internal const string MapClass = "BallMap";

    /// <summary>
    /// <c>new BallList(new BallValue[] { … })</c> / <c>new BallList()</c> — the emission of a Ball
    /// list literal (<c>CSharpCompiler.CompileListLiteral</c>).
    /// </summary>
    internal const string ListClass = "BallList";

    /// <summary><c>BallRuntime.Truthy(x)</c> coerces to a C# bool at a condition site. Ball
    /// performs that coercion implicitly wherever a condition is evaluated (<c>std.and</c>,
    /// <c>std.if</c>, …), so it encodes back to its operand unchanged.</summary>
    internal const string Truthy = "Truthy";

    /// <summary>
    /// <c>BallRuntime.FieldGet(obj, "name")</c> — the compiler's emission of a
    /// <c>field_access</c> EXPRESSION NODE, not of a base call, so it cannot be a
    /// <see cref="Table"/> row (issue #689). Its inverse is
    /// <c>field_access(obj, name)</c>: <c>BallRuntime.FieldGet</c>'s own contract
    /// (<c>csharp/shared/src/BallRuntime.cs</c>) is "read a field of a message / key of a map,
    /// or a virtual property" — exactly what the reference engine evaluates a
    /// <c>field_access</c> node to.
    /// </summary>
    internal const string FieldGet = "FieldGet";

    /// <summary>
    /// <c>BallRuntime.ArgGet(input, "name", "argN")</c> — the compiler's parameter prologue for a
    /// 2+-parameter callee (<c>CSharpCompiler.ParamPrologue</c>): read the declared parameter by
    /// NAME out of the one input message, falling back to its positional <c>argN</c> slot for a
    /// call site that had no names to pack (a first-class <c>invoke</c> of a function value).
    /// Node-shaped like <see cref="FieldGet"/>, and a two-key read rather than one, so it is not
    /// a <see cref="Table"/> row either: the inverse is
    /// <c>std.null_coalesce(map_get(input, name), map_get(input, argN))</c>, which is
    /// <c>BallMethods.ArgGet</c>'s <c>?? ?? Null</c> chain written in Ball. Both operands are a
    /// TOLERANT keyed read rather than a <c>field_access</c> node, because exactly one of the two
    /// keys is present in any real input and <c>std.null_coalesce</c> is eager — see
    /// <c>Methods.EncodeArgGetHelper</c> for the full statement of why.
    /// </summary>
    internal const string ArgGet = "ArgGet";

    /// <summary>
    /// <c>BallRuntime.FieldSet(obj, "name", value)</c> — the compiler's emission of
    /// <c>obj.name = value</c>. Node-shaped like <see cref="FieldGet"/> and for the same reason:
    /// its inverse is <c>std.assign</c> over a <c>field_access</c> TARGET, and a Ball
    /// <c>field_access</c>'s <c>field</c> is a NAME, not an encodable expression, so it cannot be
    /// a <see cref="Table"/> row whose every positional argument is one. That target shape is
    /// exactly what <c>dart/engine/lib/engine_control_flow.dart</c>'s <c>_evalAssign</c> routes
    /// through <c>_trySetterDispatch</c> before writing, and like <c>FieldSet</c> itself the
    /// assignment evaluates to the written value.
    /// </summary>
    internal const string FieldSet = "FieldSet";

    /// <summary>
    /// <c>BallRuntime.MessageTypeName(obj)</c> — the receiver-type probe every dispatcher the
    /// compiler emits opens with (<c>compiler/src/TypeEmit.cs</c>'s <c>CompileDispatcher</c>,
    /// <c>compiler/src/Accessors.cs</c>'s getter/setter accessors), which then compares it against
    /// BOTH the full <c>module:Type</c> name and the short one. Its portable Ball counterpart is
    /// <c>std.type_of</c>: by <c>dart/shared/std.json</c>'s own declaration, "the canonical base
    /// type name … with any module prefix stripped" — i.e. the SHORT name, one of the two spellings
    /// the dispatcher already tests, so the same arm is selected.
    ///
    /// <para><b>This is the one arm here that is an APPROXIMATION, and the difference is stated
    /// rather than hidden.</b> <c>MessageTypeName</c> answers <c>""</c> for a non-message
    /// (<c>csharp/shared/src/BallRuntime.cs</c>); <c>std.type_of</c> answers that value's base type
    /// name (<c>int</c>, <c>String</c>, <c>Map</c>, …). Both are unequal to any user type name a
    /// dispatcher tests, so both fall through to the same arm — UNLESS a user class is literally
    /// named <c>int</c>/<c>String</c>/<c>List</c>/<c>Map</c>/<c>Set</c>/<c>Function</c>/
    /// <c>Null</c>/<c>bool</c>/<c>double</c>, the single case where the two disagree. The
    /// alternative — reading the engine-internal <c>__type__</c> tag — is exact on the Dart
    /// reference engine and meaningless on the five targets that do not represent a message as a
    /// tagged map, so <c>std.type_of</c> is the portable choice.</para>
    /// </summary>
    internal const string MessageTypeName = "MessageTypeName";

    private static readonly string[] Unary = { "value" };
    private static readonly string[] Binary = { "left", "right" };

    /// <summary><c>BallRuntime.&lt;Name&gt;</c> → the <c>std</c> base function it emits, plus the
    /// input field each positional argument fills.</summary>
    internal static readonly Dictionary<string, (string Function, string[] Fields)> Table =
        new(StringComparer.Ordinal)
        {
            // I/O
            ["Print"] = ("print", new[] { "message" }),

            // Arithmetic
            ["Add"] = ("add", Binary),
            ["Subtract"] = ("subtract", Binary),
            ["Multiply"] = ("multiply", Binary),
            ["Divide"] = ("divide", Binary),
            ["DivideDouble"] = ("divide_double", Binary),
            ["Modulo"] = ("modulo", Binary),
            ["Negate"] = ("negate", Unary),

            // Comparison
            ["Equals"] = ("equals", Binary),
            ["NotEquals"] = ("not_equals", Binary),
            ["LessThan"] = ("less_than", Binary),
            ["GreaterThan"] = ("greater_than", Binary),
            ["Lte"] = ("lte", Binary),
            ["Gte"] = ("gte", Binary),
            ["CompareTo"] = ("compare_to", Binary),

            // Logic / bitwise
            ["Not"] = ("not", Unary),
            ["BitwiseAnd"] = ("bitwise_and", Binary),
            ["BitwiseOr"] = ("bitwise_or", Binary),
            ["BitwiseXor"] = ("bitwise_xor", Binary),
            ["BitwiseNot"] = ("bitwise_not", Unary),
            ["LeftShift"] = ("left_shift", Binary),
            ["RightShift"] = ("right_shift", Binary),
            ["UnsignedRightShift"] = ("unsigned_right_shift", Binary),

            // Strings & conversion
            ["ToStringValue"] = ("to_string", Unary),
            ["Length"] = ("length", Unary),
            ["StringToInt"] = ("string_to_int", Unary),
            ["StringToDouble"] = ("string_to_double", Unary),
            ["ToDouble"] = ("to_double", Unary),
            ["ToInt"] = ("to_int", Unary),
            ["NullCheck"] = ("null_check", Unary),
            ["StringIsEmpty"] = ("string_is_empty", Unary),
            ["StringIsNotEmpty"] = ("string_is_not_empty", Unary),
            ["StringContains"] = ("string_contains", Binary),
            ["StringStartsWith"] = ("string_starts_with", Binary),
            ["StringEndsWith"] = ("string_ends_with", Binary),
            ["StringIndexOf"] = ("string_index_of", Binary),
            ["StringLastIndexOf"] = ("string_last_index_of", Binary),
            ["StringSplit"] = ("string_split", Binary),
            ["StringToUpper"] = ("string_to_upper", Unary),
            ["StringToLower"] = ("string_to_lower", Unary),
            ["StringTrim"] = ("string_trim", Unary),
            ["StringTrimStart"] = ("string_trim_start", Unary),
            ["StringTrimEnd"] = ("string_trim_end", Unary),
            ["StringFromCharCode"] = ("string_from_char_code", Unary),
            ["StringReplace"] = ("string_replace", new[] { "value", "from", "to" }),
            ["StringReplaceAll"] = ("string_replace_all", new[] { "value", "from", "to" }),
            ["StringPadLeft"] = ("string_pad_left", new[] { "value", "width", "padding" }),
            ["StringPadRight"] = ("string_pad_right", new[] { "value", "width", "padding" }),
            ["StringCharCodeAt"] = ("string_char_code_at", new[] { "value", "index" }),
            ["StringRepeat"] = ("string_repeat", new[] { "value", "count" }),

            // Misc value ops
            ["TypeOf"] = ("type_of", Unary),
            ["IndexGet"] = ("index", new[] { "target", "index" }),
            ["NullCoalesce"] = ("null_coalesce", Binary),
        };

    /// <summary>
    /// True when <paramref name="expression"/> is a bare reference to the named class — the
    /// shape a static receiver takes in the compiler's own emission
    /// (<c>BallRuntime.Print(…)</c>, <c>BallValue.Null</c>).
    /// </summary>
    internal static bool IsClassReference(ExpressionSyntax expression, string className) =>
        expression is IdentifierNameSyntax id && id.Identifier.Text == className;

    /// <summary>
    /// The compile-time text of a plain C# string literal operand, or <c>null</c> when
    /// <paramref name="expression"/> is anything else.
    ///
    /// <para>A Ball <c>field_access</c> node's <c>field</c> is a NAME, not an expression, so the
    /// node-shaped arms can only invert a helper whose key operand is literally spelled at the
    /// call site — which is exactly what <c>Naming.StringLiteral</c> emits. A computed key
    /// (<c>FieldGet(o, k)</c>) has no Ball counterpart and must fail loud rather than be guessed
    /// at; an interpolated string is deliberately excluded too, since it is a
    /// <c>InterpolatedStringExpressionSyntax</c>, not a literal.</para>
    /// </summary>
    internal static string? StringLiteralText(ExpressionSyntax expression) =>
        expression is LiteralExpressionSyntax literal &&
        literal.Kind() == Microsoft.CodeAnalysis.CSharp.SyntaxKind.StringLiteralExpression
            ? literal.Token.ValueText
            : null;

    /// <summary>
    /// The Ball literal a <c>BallValue</c> static factory call produces
    /// (<c>Str("x")</c>, <c>Int(1)</c>, <c>Bool(true)</c>, <c>Double(1.5)</c>), or null when the
    /// name is not one of them.
    ///
    /// <para>The compiler emits these unqualified, under
    /// <c>using static Ball.Shared.BallValue;</c>, so they arrive as BARE calls. Each is a pure
    /// constructor over one literal operand: encoding it as the operand itself is the exact
    /// inverse, and it is a no-op for any other <c>Str</c>/<c>Int</c> in scope only because the
    /// operand is re-encoded normally either way.</para>
    /// </summary>
    internal static string? ValueFactoryFunction(string name) => name switch
    {
        "Str" or "Int" or "Double" or "Bool" or "Bytes" => name,
        _ => null,
    };
}
