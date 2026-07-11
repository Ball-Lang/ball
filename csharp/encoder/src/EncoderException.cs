using System;

namespace Ball.Encoder;

/// <summary>
/// Thrown for any C# construct outside this encoder's documented scope, or a parse
/// failure. "Fail loud" (CLAUDE.md): the encoder never silently drops semantic content —
/// an unsupported shape is a loud exception, never a null/placeholder/empty result.
/// </summary>
public sealed class EncoderException : Exception
{
    public EncoderException(string message) : base(message)
    {
    }
}
