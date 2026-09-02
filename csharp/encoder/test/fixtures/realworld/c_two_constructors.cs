// Bucket (c): a class declaring two constructors (19/200 in issue #492's
// study). Construction encodes as field mapping only, so the encoder tracks at
// most one constructor per class and fails loud on the second.
public class Point
{
    private int _x;
    private int _y;

    public Point(int x)
    {
        _x = x;
        _y = 0;
    }

    public Point(int x, int y)
    {
        _x = x;
        _y = y;
    }

    public int Sum()
    {
        return _x + _y;
    }

    public static void Main()
    {
        System.Console.WriteLine(new Point(1, 2).Sum());
    }
}
