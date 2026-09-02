// Bucket (e): a lambda/PredefinedType-heavy expression — the everyday shape of
// real library code: an explicitly typed lambda parameter list, a generic
// collection initializer, LINQ over a lambda, and a static call on a predefined
// type (`int.Parse`).
using System;
using System.Collections.Generic;
using System.Linq;

public class Program
{
    public static void Main()
    {
        Func<int, int> twice = (int n) => n * 2;
        List<int> values = new List<int> { 1, 2, 3 };
        IEnumerable<int> doubled = values.Where(v => v > 1).Select(twice);
        int parsed = int.Parse("41");
        Console.WriteLine(doubled.Count() + parsed);
    }
}
