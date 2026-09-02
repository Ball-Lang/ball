// Bucket (f): a target-typed `new()` — a documented encoder gap. The
// object-creation expression carries no type name of its own, so there is
// nothing syntax-only encoding can map onto a `message_creation` type.
public class Box
{
    public int Value;
}

public class Program
{
    public static void Main()
    {
        Box box = new();
        System.Console.WriteLine(box.Value);
    }
}
