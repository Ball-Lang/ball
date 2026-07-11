namespace Ball.Cli;

/// <summary>
/// Converting a <c>Ball.Compiler</c>/<c>Ball.Encoder</c> exception into a <see cref="CliError"/>
/// (issue #385).
///
/// <para>Both libraries deliberately throw (an <see cref="InvalidOperationException"/> from the
/// compiler's dispatch tables, an <c>Ball.Encoder.EncoderException</c> from the encoder, ...) on
/// a program/source shape they don't support, rather than silently degrading — "fail loud, never
/// swallow" (see <c>CLAUDE.md</c>'s core invariants and each package's own module doc comment).
/// <see cref="Guard{T}"/> is the C# analog of <c>rust/cli/src/panic_guard.rs</c>'s
/// <c>catch_panic_message</c> (Rust panics across an FFI-free boundary; C# throws — the same
/// "unsupported shape" signal, just the idiomatic .NET mechanism), converting it into a
/// <see cref="CliParseError"/> (exit <c>2</c>) — "the input could not be turned into a
/// valid/compilable program" is exactly what that bucket means.</para>
/// </summary>
public static class ExceptionGuard
{
    /// <summary>
    /// Run <paramref name="f"/>, converting any exception it throws (other than an existing
    /// <see cref="CliError"/>, which passes through unchanged) into a
    /// <see cref="CliParseError"/> carrying its message.
    /// </summary>
    public static T Guard<T>(Func<T> f)
    {
        try
        {
            return f();
        }
        catch (CliError)
        {
            throw;
        }
        catch (Exception e)
        {
            throw new CliParseError(e.Message);
        }
    }
}
