// Bucket (g): an abstract method with no body. Ball's Core Invariant #3 (a base
// function has no body, its implementation is supplied per-platform) is the
// natural encoding, but the encoder does not emit it yet and fails loud instead.
public abstract class Shape
{
    public abstract double Area();
}

public class Program
{
    public static void Main()
    {
        System.Console.WriteLine("area");
    }
}
