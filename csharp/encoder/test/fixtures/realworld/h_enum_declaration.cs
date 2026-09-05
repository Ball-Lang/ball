// Bucket (h): an `enum` declaration plus a real use site. This bucket did not
// exist in #492's original 7-row taxonomy — it became the single largest live
// encode-error bucket only AFTER slices A/B/2 closed buckets a, b, c and g, and
// nothing tracked the shift because the taxonomy table cannot grow on its own.
// In the Tier A funnel (tools/coverage-study/packages/csharp.json) it was 66 of
// 398 encode errors, 100% of them enums: an enum ANYWHERE in a file killed the
// whole file at CSharpEncoder.cs's "unsupported type declaration kind" throw.
//
// The fixture must USE the enum, not merely declare it — the declaration and the
// `Color.Green` member reference travel two different code paths
// (CSharpEncoder.EncodeMainModule vs. Methods.EncodeMemberAccess), and a fixture
// that only declared one would keep passing if member references regressed.
// The explicit `Green = 5` is here for the same reason: C# continues numbering
// from the last explicit member, so a positional-index encoding would be wrong.
public enum Color
{
    Red,
    Green = 5,
    Blue,
}

public class Palette
{
    public static string Describe(Color color)
    {
        if (color == Color.Green)
        {
            return "green";
        }

        if (color == Color.Blue)
        {
            return "blue";
        }

        return "red";
    }

    public static void Main()
    {
        System.Console.WriteLine(Describe(Color.Green));
        System.Console.WriteLine(Describe(Color.Blue));
    }
}
