namespace Drill.Core.Update;

/// <summary>
/// A semantic version like 1.4.2, as written in release tags ("v1.4.2") and
/// in the app's assembly version. Missing parts count as zero.
/// </summary>
public readonly record struct AppVersion(int Major, int Minor = 0, int Patch = 0) : IComparable<AppVersion>
{
    public static AppVersion? Parse(string? text)
    {
        if (text is null) return null;
        var t = text.Trim();
        if (t.StartsWith('v')) t = t[1..];
        // "1.2.3+sha" from informational versions: the build metadata goes.
        var plus = t.IndexOf('+');
        if (plus >= 0) t = t[..plus];
        var parts = t.Split('.');
        if (parts.Length is < 1 or > 3) return null;
        var n = new int[3];
        for (var i = 0; i < parts.Length; i++)
        {
            if (!int.TryParse(parts[i], System.Globalization.NumberStyles.None, null, out n[i])) return null;
        }
        return new AppVersion(n[0], n[1], n[2]);
    }

    public int CompareTo(AppVersion other) =>
        (Major, Minor, Patch).CompareTo((other.Major, other.Minor, other.Patch));

    public static bool operator <(AppVersion a, AppVersion b) => a.CompareTo(b) < 0;
    public static bool operator >(AppVersion a, AppVersion b) => a.CompareTo(b) > 0;
    public static bool operator <=(AppVersion a, AppVersion b) => a.CompareTo(b) <= 0;
    public static bool operator >=(AppVersion a, AppVersion b) => a.CompareTo(b) >= 0;

    public override string ToString() => $"{Major}.{Minor}.{Patch}";
}
