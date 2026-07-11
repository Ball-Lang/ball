using System.Globalization;
using System.Text;

namespace Ball.Compiler;

/// <summary>
/// Pure helpers for turning Ball names/values into valid C# source text:
/// identifier sanitization, type/member-name parsing, and literal emission.
/// The C# analog of the free functions at the bottom of
/// <c>rust/compiler/src/lib.rs</c> (<c>sanitize_ident</c>,
/// <c>format_double_literal</c>) and <c>type_emit.rs</c>'s name parsers.
/// </summary>
internal static class Naming
{
    // C# reserved keywords that a Ball identifier could collide with. A
    // collision gets an <c>@</c> verbatim prefix (C#'s escape for using a
    // keyword as an identifier) rather than mangling the name, so the emitted
    // code still reads like the original.
    private static readonly HashSet<string> Reserved = new(StringComparer.Ordinal)
    {
        "abstract", "as", "base", "bool", "break", "byte", "case", "catch", "char", "checked",
        "class", "const", "continue", "decimal", "default", "delegate", "do", "double", "else",
        "enum", "event", "explicit", "extern", "false", "finally", "fixed", "float", "for",
        "foreach", "goto", "if", "implicit", "in", "int", "interface", "internal", "is", "lock",
        "long", "namespace", "new", "null", "object", "operator", "out", "override", "params",
        "private", "protected", "public", "readonly", "ref", "return", "sbyte", "sealed", "short",
        "sizeof", "stackalloc", "static", "string", "struct", "switch", "this", "throw", "true",
        "try", "typeof", "uint", "ulong", "unchecked", "unsafe", "ushort", "using", "virtual",
        "void", "volatile", "while",
    };

    /// <summary>
    /// Sanitize a Ball identifier into a valid C# identifier: non-
    /// <c>[A-Za-z0-9_]</c> characters become <c>_</c>, a leading digit gets an
    /// <c>_</c> prefix, an empty name becomes <c>_unnamed</c>, and a C#
    /// reserved keyword is escaped with a leading <c>@</c>. Ball identifiers
    /// from every existing encoder are already valid source identifiers in
    /// their origin language, so this is a defensive fallback, not the common
    /// case.
    /// </summary>
    public static string Sanitize(string name)
    {
        if (name.Length == 0)
        {
            return "_unnamed";
        }

        var builder = new StringBuilder(name.Length);
        foreach (var c in name)
        {
            builder.Append(char.IsLetterOrDigit(c) || c == '_' ? c : '_');
        }

        var result = builder.ToString();
        if (char.IsDigit(result[0]))
        {
            result = "_" + result;
        }

        return Reserved.Contains(result) ? "@" + result : result;
    }

    /// <summary>
    /// Strip a Ball type's module-qualifying prefix (<c>"main:Color"</c> →
    /// <c>"Color"</c>) — the short form user code references.
    /// </summary>
    public static string TypeShortName(string fullName)
    {
        var idx = fullName.LastIndexOf(':');
        return idx >= 0 ? fullName[(idx + 1)..] : fullName;
    }

    /// <summary>
    /// Split a class-member function name (<c>"main:Point.describe"</c>) into
    /// its owner type name (<c>"main:Point"</c>) and short member name
    /// (<c>"describe"</c>). Mirrors <c>rust/compiler/src/type_emit.rs</c>'s
    /// <c>split_member_name</c> (colon-then-dot) exactly, including the
    /// colon-less fallback (<c>"Point.new"</c> → <c>("Point", "new")</c>).
    /// Returns <c>null</c> when there is no dot to split on — i.e. an ordinary
    /// standalone function.
    /// </summary>
    public static (string Owner, string Member)? SplitMemberName(string name)
    {
        var colon = name.LastIndexOf(':');
        if (colon >= 0)
        {
            var afterColon = name[(colon + 1)..];
            var dot = afterColon.IndexOf('.');
            if (dot < 0)
            {
                return null;
            }

            return (name[..(colon + 1 + dot)], afterColon[(dot + 1)..]);
        }

        var plainDot = name.IndexOf('.');
        return plainDot < 0 ? null : (name[..plainDot], name[(plainDot + 1)..]);
    }

    /// <summary>Does <paramref name="name"/> match the encoder's positional-argument convention (<c>arg0</c>, <c>arg1</c>, …)?</summary>
    public static bool IsPositionalArg(string name) =>
        name.StartsWith("arg", StringComparison.Ordinal)
        && name.Length > 3
        && name[3..].All(char.IsDigit);

    // ════════════════════════════════════════════════════════════
    // Literal emission
    // ════════════════════════════════════════════════════════════

    /// <summary>A 64-bit integer literal as a C# <c>long</c> (always suffixed <c>L</c>).</summary>
    public static string IntLiteral(long value) => value.ToString(CultureInfo.InvariantCulture) + "L";

    /// <summary>
    /// A <c>double</c> literal as a syntactically valid C# <c>double</c>
    /// expression. C# has no literal for NaN/Infinity, so those lower to the
    /// <c>double.NaN</c>/<c>double.PositiveInfinity</c>/… constants; a finite
    /// value uses the round-trip (<c>"R"</c>) form and is forced to carry a
    /// decimal point so it parses back as a <c>double</c>, never an <c>int</c>.
    /// </summary>
    public static string DoubleLiteral(double value)
    {
        if (double.IsNaN(value))
        {
            return "double.NaN";
        }

        if (double.IsPositiveInfinity(value))
        {
            return "double.PositiveInfinity";
        }

        if (double.IsNegativeInfinity(value))
        {
            return "double.NegativeInfinity";
        }

        var text = value.ToString("R", CultureInfo.InvariantCulture);
        if (!text.Contains('.') && !text.Contains('E') && !text.Contains('e'))
        {
            text += ".0";
        }

        return text;
    }

    /// <summary>A C# string literal (a verbatim-safe double-quoted literal with escapes).</summary>
    public static string StringLiteral(string value)
    {
        var builder = new StringBuilder(value.Length + 2);
        builder.Append('"');
        foreach (var c in value)
        {
            switch (c)
            {
                case '\\':
                    builder.Append("\\\\");
                    break;
                case '"':
                    builder.Append("\\\"");
                    break;
                case '\n':
                    builder.Append("\\n");
                    break;
                case '\r':
                    builder.Append("\\r");
                    break;
                case '\t':
                    builder.Append("\\t");
                    break;
                case '\0':
                    builder.Append("\\0");
                    break;
                default:
                    if (char.IsControl(c))
                    {
                        builder.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    }
                    else
                    {
                        builder.Append(c);
                    }

                    break;
            }
        }

        builder.Append('"');
        return builder.ToString();
    }
}
